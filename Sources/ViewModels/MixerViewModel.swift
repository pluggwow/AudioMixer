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

    enum EngineStatus: Equatable {
        case idle
        case active(Int)
        case failed(String)
    }

    // MARK: - Зависимости

    let systemVolume: SystemVolumeController
    let volumeStore: VolumeStore
    private let processMonitor: AudioProcessMonitor
    private let deviceManager: AudioDeviceManager
    private let permissions: PermissionManager
    private let settings: SettingsStore

    private var engine: Any?   // AudioProcessTapEngine, спрятан за availability
    private var cancellables = Set<AnyCancellable>()

    /// Зависимости — nil-по-умолчанию, а не `= .init()`: значения по умолчанию
    /// вычисляются вне изоляции актора, а все четыре типа @MainActor-изолированы.
    /// Реальные объекты создаются в теле init, которое уже на MainActor.
    init(settings: SettingsStore,
         volumeStore: VolumeStore,
         processMonitor: AudioProcessMonitor? = nil,
         deviceManager: AudioDeviceManager? = nil,
         systemVolume: SystemVolumeController? = nil,
         permissions: PermissionManager? = nil) {

        self.settings = settings
        self.volumeStore = volumeStore
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
                self?.rebuildApps(from: processes)
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
