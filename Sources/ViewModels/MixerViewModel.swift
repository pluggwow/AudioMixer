//
//  MixerViewModel.swift
//  AudioMixer
//
//  Единственный слой, который знает и про Core Audio, и про UI.
//  Views не трогают Core Audio вообще — только этот объект.
//

import SwiftUI
import Combine
import CoreAudio

@MainActor
final class MixerViewModel: ObservableObject {

    // MARK: - Публикуемое состояние

    @Published private(set) var apps: [AudioAppState] = []
    @Published private(set) var outputDevice: AudioDeviceInfo?
    @Published private(set) var availableDevices: [AudioDeviceInfo] = []
    @Published private(set) var engineState: EngineStatus = .idle
    @Published private(set) var permissionStatus: PermissionManager.Status = .unknown

    /// Порядок строк задан вручную, автоматический больше не применяется.
    @Published private(set) var hasCustomOrder: Bool = false

    enum EngineStatus: Equatable {
        case idle
        case active(Int)
        case failed(String)
    }

    // MARK: - Зависимости

    let systemVolume: SystemVolumeController
    let volumeStore: VolumeStore
    let orderStore: AppOrderStore
    private let processMonitor: AudioProcessMonitor
    private let deviceManager: AudioDeviceManager
    private let permissions: PermissionManager
    private let settings: SettingsStore

    private var engine: Any?   // AudioProcessTapEngine, спрятан за availability
    private var cancellables = Set<AnyCancellable>()

    /// Последний список от монитора. Нужен, чтобы пересобрать строки без нового
    /// события: после отпускания перетаскиваемой строки и при сбросе порядка.
    private var lastProcesses: [AudioProcessInfo] = []

    /// Пока строку тащат, список не перестраиваем: появившееся или пропавшее
    /// приложение сдвинуло бы индексы прямо под курсором.
    private var isReordering = false

    /// Зависимости — nil-по-умолчанию, а не `= .init()`: значения по умолчанию
    /// вычисляются вне изоляции актора, а все четыре типа @MainActor-изолированы.
    /// Реальные объекты создаются в теле init, которое уже на MainActor.
    init(settings: SettingsStore,
         volumeStore: VolumeStore,
         orderStore: AppOrderStore,
         processMonitor: AudioProcessMonitor? = nil,
         deviceManager: AudioDeviceManager? = nil,
         systemVolume: SystemVolumeController? = nil,
         permissions: PermissionManager? = nil) {

        self.settings = settings
        self.volumeStore = volumeStore
        self.orderStore = orderStore
        self.hasCustomOrder = orderStore.isCustom
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.deviceManager = deviceManager ?? AudioDeviceManager()
        self.systemVolume = systemVolume ?? SystemVolumeController()
        self.permissions = permissions ?? PermissionManager()

        if #available(macOS 14.4, *) {
            let engine = AudioProcessTapEngine()
            engine.onStateChange = { [weak self] state in
                Task { @MainActor in self?.handleEngineState(state) }
            }
            self.engine = engine
        }
    }

    // MARK: - Жизненный цикл

    func start() {
        permissions.check()
        permissionStatus = permissions.status
        AppLog.permissions.info(
            "Статус разрешения при старте: \(String(describing: self.permissionStatus), privacy: .public)"
        )

        deviceManager.onDeviceChange = { [weak self] device in
            Task { @MainActor in self?.handleDeviceChange(device) }
        }

        processMonitor.$processes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                guard let self else { return }
                self.lastProcesses = processes
                guard !self.isReordering else { return }
                self.rebuildApps(from: processes)
            }
            .store(in: &cancellables)

        deviceManager.$availableDevices
            .receive(on: DispatchQueue.main)
            .assign(to: &$availableDevices)

        deviceManager.start()
        processMonitor.start()

        // Мастер-громкость влияет на итоговый gain нашего рендера:
        // без этого приложение с tap-ом игнорировало бы системный регулятор.
        systemVolume.$volume
            .combineLatest(systemVolume.$isMuted)
            .sink { [weak self] volume, muted in
                self?.tapEngine?.setMasterGain(muted ? 0 : volume)
            }
            .store(in: &cancellables)
    }

    func shutdown() {
        processMonitor.stop()
        deviceManager.stop()
        volumeStore.flush()
        orderStore.flush()
        tapEngine?.shutdown()
    }

    func recheckPermissions() {
        permissions.check()
        permissionStatus = permissions.status
        if case .granted = permissionStatus { pushLevelsToEngine() }
    }

    func openPermissionSettings() { permissions.openSystemSettings() }

    @available(macOS 14.4, *)
    private var typedEngine: AudioProcessTapEngine? { engine as? AudioProcessTapEngine }

    private var tapEngine: AudioProcessTapEngine? {
        guard #available(macOS 14.4, *) else { return nil }
        return typedEngine
    }

    // MARK: - Управление громкостью приложений

    func setVolume(_ volume: Float, for bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let clamped = max(0, min(volume, 1))
        guard apps[index].volume != clamped else { return }

        apps[index].volume = clamped
        // Движение слайдера вверх из mute естественно снимает mute.
        if clamped > 0 && apps[index].isMuted { apps[index].isMuted = false }

        persist(apps[index])
        pushLevelsToEngine()
    }

    func toggleMute(for bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        apps[index].isMuted.toggle()
        persist(apps[index])
        pushLevelsToEngine()
    }

    func resetVolume(for bundleID: String) {
        setVolume(1.0, for: bundleID)
    }

    private func persist(_ app: AudioAppState) {
        guard settings.rememberAppVolumes else { return }
        volumeStore.update(
            bundleID: app.bundleID,
            displayName: app.name,
            volume: app.volume,
            isMuted: app.isMuted
        )
    }

    // MARK: - Порядок строк

    /// Строку взяли мышью. На время перетаскивания список замораживается.
    func beginReordering() {
        isReordering = true
    }

    /// Строку отпустили — применяем то, что монитор успел прислать за это время.
    func endReordering() {
        guard isReordering else { return }
        isReordering = false
        rebuildApps(from: lastProcesses)
    }

    /// Переставить строку. Индексы — в текущем `apps`.
    func moveApp(from source: Int, to destination: Int) {
        guard source != destination,
              apps.indices.contains(source),
              apps.indices.contains(destination) else { return }

        var reordered = apps
        reordered.insert(reordered.remove(at: source), at: destination)
        apps = reordered

        orderStore.apply(visibleOrder: reordered.map(\.bundleID))
        hasCustomOrder = orderStore.isCustom

        // Движку порядок безразличен: applyUnsafe сравнивает МНОЖЕСТВА pid,
        // так что перестановка строк не пересобирает агрегат и не даёт щелчка.
        // Поэтому pushLevelsToEngine() здесь намеренно не вызывается.
    }

    /// Сдвинуть строку на позицию вверх (-1) или вниз (+1). Для контекстного меню.
    func moveApp(bundleID: String, by delta: Int) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        moveApp(from: index, to: min(max(index + delta, 0), apps.count - 1))
    }

    /// Забыть ручной порядок и вернуться к автоматическому.
    func resetOrder() {
        orderStore.reset()
        hasCustomOrder = false
        rebuildApps(from: lastProcesses)
    }

    /// Ручной порядок важнее автоматического. Приложения, которых в нём нет,
    /// встают в конец в автоматическом порядке: новое приложение не должно
    /// само влезать в середину выстроенного пользователем списка.
    private func ordered(_ list: [AudioAppState]) -> [AudioAppState] {
        let order = orderStore.order
        guard !order.isEmpty else { return list }

        var rank: [String: Int] = [:]
        rank.reserveCapacity(order.count)
        for (position, bundleID) in order.enumerated() { rank[bundleID] = position }

        var known: [(position: Int, app: AudioAppState)] = []
        var unknown: [AudioAppState] = []
        for app in list {
            if let position = rank[app.bundleID] {
                known.append((position, app))
            } else {
                unknown.append(app)
            }
        }
        known.sort { $0.position < $1.position }
        return known.map(\.app) + unknown
    }

    // MARK: - Синхронизация со списком процессов

    private func rebuildApps(from processes: [AudioProcessInfo]) {
        var result: [AudioAppState] = []
        result.reserveCapacity(processes.count)

        // Одно приложение = одна строка. У Safari, Claude и подобных несколько
        // процессов с общим bundleID, а id строки — именно bundleID: дубликаты
        // в ForEach ломают отрисовку всего списка. Процессы приходят
        // отсортированными «играющие первыми», поэтому остаётся нужный.
        var seenBundleIDs = Set<String>()

        for process in processes {
            guard seenBundleIDs.insert(process.bundleID).inserted else { continue }

            // Уже известное приложение — сохраняем текущее состояние UI,
            // обновляя только PID (мог смениться) и признак воспроизведения.
            if let existing = apps.first(where: { $0.bundleID == process.bundleID }) {
                var updated = existing
                updated.pid = process.pid
                updated.objectID = process.objectID
                updated.isPlaying = process.isRunningOutput
                updated.name = process.name
                result.append(updated)
                continue
            }

            // Новое приложение — поднимаем сохранённый уровень.
            let (volume, muted) = volumeStore.resolvedVolume(
                for: process.bundleID,
                defaultVolume: Float(settings.defaultVolume),
                rememberEnabled: settings.rememberAppVolumes
            )

            result.append(
                AudioAppState(
                    bundleID: process.bundleID,
                    pid: process.pid,
                    objectID: process.objectID,
                    name: process.name,
                    icon: AppIconProvider.shared.icon(bundleID: process.bundleID, pid: process.ownerPID),
                    volume: volume,
                    isMuted: muted,
                    isPlaying: process.isRunningOutput
                )
            )
        }

        result = ordered(result)

        guard result != apps else { return }
        let playing = result.filter(\.isPlaying).count
        AppLog.processes.info(
            "Список приложений: \(result.count, privacy: .public) (со звуком: \(playing, privacy: .public))"
        )
        apps = result
        pushLevelsToEngine()
    }

    private func pushLevelsToEngine() {
        guard #available(macOS 14.4, *), let engine = tapEngine else { return }
        guard permissionStatus == .granted else {
            // Без этой строки отказ в разрешении выглядит как «приложение просто
            // ничего не делает»: движок молча не получает уровни.
            AppLog.engine.error(
                "Уровни не отправлены — нет разрешения: \(String(describing: self.permissionStatus), privacy: .public)"
            )
            return
        }

        let levels = apps.map {
            AudioProcessTapEngine.Level(pid: $0.pid, volume: $0.volume, isMuted: $0.isMuted)
        }
        engine.apply(levels: levels)
    }

    // MARK: - Устройства

    private func handleDeviceChange(_ device: AudioDeviceInfo?) {
        outputDevice = device
        systemVolume.bind(to: device?.deviceID)
        // Наушники отключились / устройство сменилось -> агрегат пересобирается
        // под новое устройство. Иначе IOProc продолжил бы писать в исчезнувший выход.
        tapEngine?.setOutputDevice(uid: device?.uid)
        tapEngine?.setMasterGain(systemVolume.isMuted ? 0 : systemVolume.volume)
    }

    func selectOutputDevice(_ device: AudioDeviceInfo) {
        deviceManager.selectDevice(device)
    }

    private func handleEngineState(_ state: Any) {
        guard #available(macOS 14.4, *),
              let state = state as? AudioProcessTapEngine.State else { return }
        switch state {
        case .idle:
            engineState = .idle
        case .running(let count):
            engineState = .active(count)
        case .failed(let message):
            engineState = .failed(message)
        }
    }
}
