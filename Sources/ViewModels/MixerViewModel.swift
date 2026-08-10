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

        // Мастер-громкость движку не передаём: наш рендер идёт мимо
        // регулятора устройства, и применять громкость приходится самим —
        // но у каждого маршрута она своя, поэтому движок читает её сам,
        // у того устройства, в которое этот маршрут звучит.
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

    // MARK: - Закрепление

    /// Закрепить/открепить строку. Закреплённое приложение остаётся в списке
    /// после закрытия — бесцветной строкой, которой можно заранее выставить
    /// громкость.
    func togglePin(for bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        if apps[index].isPinned {
            unpin(at: index)
        } else {
            pin(at: index)
        }
    }

    private func pin(at index: Int) {
        // Куда вернуть при откреплении — сосед сверху, каким его видит
        // пользователь прямо сейчас.
        let anchor: PinAnchor = index > 0 ? .after(apps[index - 1].bundleID) : .top

        apps[index].isPinned = true
        volumeStore.setPinned(true, for: apps[index].bundleID, displayName: apps[index].name, anchor: anchor)

        // Закреплённое поднимается наверх и там фиксируется. Порядок
        // сохраняется даже если строка уже первая: иначе автоматический
        // порядок («играющие первыми») увёл бы её вниз, стоит зазвучать
        // соседу — а закрепляют как раз чтобы этого не было.
        var reordered = apps
        reordered.insert(reordered.remove(at: index), at: 0)
        commitOrder(reordered)
    }

    private func unpin(at index: Int) {
        let bundleID = apps[index].bundleID
        let anchor = volumeStore.settings(for: bundleID)?.anchorBeforePin
        let wasRunning = apps[index].isRunning

        apps[index].isPinned = false
        volumeStore.setPinned(false, for: bundleID, displayName: apps[index].name, anchor: nil)

        // Строка возвращается на место, с которого её подняло закрепление.
        // Место ищется в сохранённом порядке, а не в видимом списке: сосед,
        // за которым она стояла, мог с тех пор закрыться.
        let restored = anchor.map { orderStore.place(bundleID, at: $0) } ?? false

        if !wasRunning {
            // Закрытое приложение без закрепления держать в списке нечем.
            apps.remove(at: index)
        }

        if restored {
            hasCustomOrder = orderStore.isCustom
            rebuildApps(from: lastProcesses)
        }
    }

    // MARK: - Устройство вывода приложения

    /// Увести приложение в другое устройство. `nil` — вернуть к системному.
    ///
    /// Маршрутизация без перехвата невозможна, поэтому приложение с чужим
    /// устройством таппится даже на 100% громкости — движок это учитывает сам.
    func setOutputDevice(_ uid: String?, for bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        guard apps[index].outputDeviceUID != uid else { return }

        apps[index].outputDeviceUID = uid
        volumeStore.setOutputDevice(uid, for: bundleID, displayName: apps[index].name)
        pushLevelsToEngine()
    }

    /// Устройство приложения как объект — для галочки в меню и значка в строке.
    func outputDevice(for app: AudioAppState) -> AudioDeviceInfo? {
        guard let uid = app.outputDeviceUID else { return nil }
        return availableDevices.first { $0.uid == uid }
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

        // Из группы в группу строки не переезжают: закреплённые остаются
        // наверху, остальные под ними. Интерфейс такого перетаскивания и не
        // предлагает, но проверка здесь — чтобы порядок нельзя было сломать
        // мимо него, а список не дёргался при следующей пересборке.
        guard apps[source].isPinned == apps[destination].isPinned else { return }

        // Пользователь передвинул строку сам — прежнее место, запомненное при
        // закреплении, устарело: открепление не должно отменять его выбор.
        volumeStore.clearPinAnchor(for: apps[source].bundleID)

        var reordered = apps
        reordered.insert(reordered.remove(at: source), at: destination)
        commitOrder(reordered)
    }

    /// Принять новый порядок строк и запомнить его.
    ///
    /// Движку порядок безразличен: `applyUnsafe` сравнивает МНОЖЕСТВА pid,
    /// так что перестановка не пересобирает агрегат и не даёт щелчка в звуке.
    /// Поэтому `pushLevelsToEngine()` отсюда намеренно не вызывается.
    private func commitOrder(_ reordered: [AudioAppState]) {
        apps = reordered
        orderStore.apply(visibleOrder: reordered.map(\.bundleID))
        hasCustomOrder = orderStore.isCustom
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

    /// Итоговый порядок строк: сначала закреплённые, потом остальные.
    ///
    /// Закреплённые держатся вверху одной группой, и строки между группами не
    /// смешиваются. Иначе «закрепить» означало бы всего лишь «один раз поднять
    /// наверх»: любой сосед, начав играть или переехав перетаскиванием, тут же
    /// оттеснил бы закреплённое вниз.
    private func ordered(_ list: [AudioAppState]) -> [AudioAppState] {
        let arranged = manuallyOrdered(list)
        // filter сохраняет взаимный порядок, поэтому внутри каждой группы
        // остаётся ровно то, что выстроил пользователь.
        return arranged.filter(\.isPinned) + arranged.filter { !$0.isPinned }
    }

    /// Ручной порядок важнее автоматического. Приложения, которых в нём нет,
    /// встают в конец в автоматическом порядке: новое приложение не должно
    /// само влезать в середину выстроенного пользователем списка.
    private func manuallyOrdered(_ list: [AudioAppState]) -> [AudioAppState] {
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
                // Приложение могло только что запуститься — строка была бесцветной.
                updated.isRunning = true
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
                    isPlaying: process.isRunningOutput,
                    isPinned: volumeStore.settings(for: process.bundleID)?.isPinned ?? false,
                    isRunning: true,
                    outputDeviceUID: volumeStore.settings(for: process.bundleID)?.outputDeviceUID
                )
            )
        }

        result.append(contentsOf: offlinePinnedApps(excluding: seenBundleIDs))
        result = ordered(result)

        guard result != apps else { return }
        let playing = result.filter(\.isPlaying).count
        AppLog.processes.info(
            "Список приложений: \(result.count, privacy: .public) (со звуком: \(playing, privacy: .public))"
        )
        apps = result
        pushLevelsToEngine()
    }

    /// Строки для закреплённых приложений, которых сейчас нет среди аудиопроцессов.
    /// Имя и иконка берутся из сохранённых настроек и из бандла на диске —
    /// запущенный процесс для этого не нужен.
    private func offlinePinnedApps(excluding running: Set<String>) -> [AudioAppState] {
        volumeStore.pinned
            .filter { !running.contains($0.bundleID) }
            .map { entry in
                AudioAppState(
                    bundleID: entry.bundleID,
                    pid: 0,
                    objectID: .unknown,
                    name: entry.settings.displayName.isEmpty ? entry.bundleID : entry.settings.displayName,
                    icon: AppIconProvider.shared.icon(bundleID: entry.bundleID, pid: 0),
                    volume: entry.settings.volume,
                    isMuted: entry.settings.isMuted,
                    isPlaying: false,
                    isPinned: true,
                    isRunning: false,
                    outputDeviceUID: entry.settings.outputDeviceUID
                )
            }
            // Порядок словаря не определён, а список не должен прыгать между
            // перестроениями. Ручной порядок, если он задан, всё равно главнее.
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

        // Только запущенные: у закреплённой строки закрытого приложения pid
        // невалидный, и движок безуспешно пытался бы навесить на него tap.
        let levels = apps.filter(\.isRunning).map {
            AudioProcessTapEngine.Level(
                pid: $0.pid,
                volume: $0.volume,
                isMuted: $0.isMuted,
                outputUID: $0.outputDeviceUID
            )
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
