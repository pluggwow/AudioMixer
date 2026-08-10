//
//  AudioProcessTapEngine.swift
//  AudioMixer
//
//  Сердце проекта. Реализует per-app volume и per-app вывод через официальный
//  Core Audio API:
//
//    1. На приложение, которому нужен перехват, создаётся CATapDescription с
//       muteBehavior = .mutedWhenTapped. Система при этом ГЛУШИТ оригинальный
//       выход процесса — двойного звука не возникает.
//    2. Таппы подключаются входами к приватному агрегатному устройству,
//       main sub-device которого — устройство вывода. Агрегат СВОЙ на каждое
//       устройство: именно это и позволяет увести приложение в наушники, пока
//       остальные играют в динамики.
//    3. В каждом агрегате свой IOProc: читает входы, умножает на gain, пишет
//       в выход. Общий clock domain => нет ресемплинга и дрейфа, латентность
//       = 1 буфер.
//
//  Перехват нужен приложению, если у него меняется громкость (не 100% или
//  mute) ЛИБО если оно выведено не туда, куда система выводит по умолчанию:
//  маршрутизации без перехвата не существует. Остальные играют мимо нас
//  нативно, и если таких, кому нужен tap, нет — движок выключается целиком,
//  потребление CPU падает до нуля.
//
//  Громкость устройства движок читает сам, отдельно для каждого маршрута:
//  наш рендер идёт мимо регулятора устройства, поэтому иначе приложение,
//  уведённое в наушники, играло бы там на полной шкале.
//

import Foundation
import CoreAudio
import AudioToolbox

@available(macOS 14.4, *)
final class AudioProcessTapEngine {

    // MARK: - Типы

    enum State: Equatable {
        case idle                    // таппы не нужны, движок спит
        case running(tapCount: Int)
        case failed(String)

        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    /// Целевой уровень одного приложения.
    struct Level: Equatable {
        var pid: pid_t
        var volume: Float   // 0...1
        var isMuted: Bool
        /// UID устройства вывода. nil — то, что выбрано в системе.
        var outputUID: String?

        var effectiveGain: Float { isMuted ? 0 : max(0, min(volume, 1)) }

        /// Куда это приложение в итоге звучит.
        func resolvedOutput(default defaultOutput: String?) -> String? {
            outputUID ?? defaultOutput
        }

        /// Перехват нужен либо чтобы менять громкость, либо чтобы увести звук
        /// на другое устройство.
        func requiresTap(default defaultOutput: String?) -> Bool {
            if isMuted || volume < 0.999 { return true }
            guard let outputUID else { return false }
            return outputUID != defaultOutput
        }
    }

    private struct TapSlot {
        let pid: pid_t
        let tapID: AudioObjectID
        let uid: String
        let channelCount: Int
        var gain: Float
    }

    /// Один маршрут = одно устройство вывода со своим агрегатом и IOProc.
    private final class Route {
        let outputUID: String
        /// Порядок важен: он же задаёт порядок каналов в агрегате.
        var pids: [pid_t] = []
        var aggregateID: AudioObjectID = .unknown
        var ioProcID: AudioDeviceIOProcID?
        var isRunning = false
        let renderState = RenderState()
        var volumeObservers: [AudioPropertyObserver] = []

        init(outputUID: String) { self.outputUID = outputUID }
    }

    // MARK: - Состояние

    private let queue = DispatchQueue(label: "com.example.AudioMixer.engine", qos: .userInitiated)

    /// Живые таппы по pid. Тапп переживает пересборку агрегатов и переезд
    /// приложения с одного устройства на другое — пересоздавать его незачем.
    private var taps: [pid_t: TapSlot] = [:]
    private var routes: [String: Route] = [:]

    /// Процессы, на которых тапп создать не удалось. Нужны, чтобы немедленный
    /// путь не превращался в долбёжку: без этого списка каждое движение
    /// слайдера заново пыталось бы создать заведомо несоздаваемый тапп —
    /// шестьдесят неудачных вызовов Core Audio в секунду.
    private var tapFailures: Set<pid_t> = []

    private var outputDeviceUID: String?
    private var lastLevels: [Level] = []
    private var pendingWorkItem: DispatchWorkItem?

    /// Вызывается на main.
    var onStateChange: ((State) -> Void)?

    private var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            let newState = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(newState) }
        }
    }

    deinit {
        // deinit синхронно, движок к этому моменту должен быть остановлен вызовом shutdown().
        teardownUnsafe()
    }

    // MARK: - Публичный API

    /// Сменить устройство по умолчанию. Приложения без своего выбора переезжают
    /// вместе с ним, приложения с явным выбором остаются на своём устройстве.
    func setOutputDevice(uid: String?) {
        queue.async { [weak self] in
            guard let self, self.outputDeviceUID != uid else { return }
            AppLog.engine.info("Default output changed to \(uid ?? "nil", privacy: .public)")
            self.outputDeviceUID = uid
            self.applyUnsafe(levels: self.lastLevels)
        }
    }

    /// Применить набор уровней.
    ///
    /// Гейны — всегда немедленно. Пересборка агрегатов дебаунсится, но
    /// НЕСИММЕТРИЧНО: появление таппа применяется сразу, исчезновение — с
    /// задержкой. Ждать появления нельзя — пока таппа нет, приложение играет
    /// в полную громкость, и слайдер выглядит залипшим на те самые 150 мс.
    /// А вот исчезновение стоит придержать: на обратном ходу слайдер легко
    /// раз десять пересечёт отметку 100%, и каждое пересечение пересобирало
    /// бы агрегат.
    func apply(levels: [Level]) {
        queue.async { [weak self] in
            guard let self else { return }

            self.updateGainsOnlyUnsafe(levels: levels)

            self.pendingWorkItem?.cancel()
            self.pendingWorkItem = nil

            if self.needsImmediateApplyUnsafe(levels: levels) {
                self.applyUnsafe(levels: levels)
                return
            }

            self.lastLevels = levels
            let work = DispatchWorkItem { [weak self] in
                self?.applyUnsafe(levels: levels)
            }
            self.pendingWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    /// Есть ли изменение, которое нельзя откладывать: новый тапп или переезд
    /// приложения на другое устройство. И то и другое — прямое действие
    /// пользователя, результат которого он ждёт сейчас, а не через 150 мс.
    private func needsImmediateApplyUnsafe(levels: [Level]) -> Bool {
        let defaultUID = outputDeviceUID
        let required = levels.filter { $0.requiresTap(default: defaultUID) }

        if required.contains(where: { taps[$0.pid] == nil && !tapFailures.contains($0.pid) }) {
            return true
        }

        for level in required {
            guard let uid = level.resolvedOutput(default: defaultUID) else { continue }
            if routes[uid]?.pids.contains(level.pid) != true { return true }
        }
        return false
    }

    func shutdown() {
        // Всё, что касается pendingWorkItem, живёт на queue: трогать его
        // с чужого потока — гонка, пусть и незаметная.
        queue.sync { [weak self] in
            guard let self else { return }
            self.pendingWorkItem?.cancel()
            self.pendingWorkItem = nil
            self.teardownUnsafe()
        }
    }

    // MARK: - Реализация (всегда на self.queue)

    private func updateGainsOnlyUnsafe(levels: [Level]) {
        var changed = false
        for level in levels {
            guard var slot = taps[level.pid], slot.gain != level.effectiveGain else { continue }
            slot.gain = level.effectiveGain
            taps[level.pid] = slot
            changed = true
        }
        guard changed else { return }
        for route in routes.values { pushGainMapUnsafe(route) }
    }

    private func applyUnsafe(levels: [Level]) {
        lastLevels = levels

        let defaultUID = outputDeviceUID
        let required = levels.filter { $0.requiresTap(default: defaultUID) }

        // Кого куда вести. Порядок внутри маршрута — порядок уровней.
        var wanted: [String: [pid_t]] = [:]
        for level in required {
            guard let uid = level.resolvedOutput(default: defaultUID) else { continue }
            wanted[uid, default: []].append(level.pid)
        }

        do {
            try syncTapsUnsafe(required: required, wanted: &wanted)

            // Маршруты, которым больше некого вести.
            for (uid, route) in routes where wanted[uid] == nil {
                teardownRouteUnsafe(route)
                routes.removeValue(forKey: uid)
            }

            for (uid, pids) in wanted {
                let route = routes[uid] ?? Route(outputUID: uid)
                routes[uid] = route

                // Сравнение МНОЖЕСТВАМИ: перестановка приложений в списке не
                // меняет состав маршрута, и пересобирать агрегат из-за неё
                // (то есть рвать звук) незачем.
                guard Set(route.pids) != Set(pids) || !route.isRunning else { continue }
                route.pids = pids
                try rebuildRouteUnsafe(route)
            }

            updateGainsOnlyUnsafe(levels: levels)
            state = taps.isEmpty ? .idle : .running(tapCount: taps.count)

        } catch {
            AppLog.engine.error("Engine apply failed: \(error.localizedDescription, privacy: .public)")
            teardownUnsafe()
            state = .failed(error.localizedDescription)
        }
    }

    /// Привести набор таппов к нужному: лишние уничтожить, недостающие создать.
    /// Приложение, для которого тапп создать не удалось, из маршрута выпадает —
    /// один упавший процесс не должен ронять весь микшер.
    private func syncTapsUnsafe(required: [Level], wanted: inout [String: [pid_t]]) throws {
        let requiredPIDs = Set(required.map(\.pid))

        for (pid, slot) in taps where !requiredPIDs.contains(pid) {
            AudioHardwareDestroyProcessTap(slot.tapID)
            taps.removeValue(forKey: pid)
        }
        // Процесс, который больше не нужен, забываем и как неудачный: в
        // следующий раз попытка должна быть честной.
        tapFailures.formIntersection(requiredPIDs)

        for level in required where taps[level.pid] == nil {
            do {
                taps[level.pid] = try makeTap(for: level)
                tapFailures.remove(level.pid)
            } catch {
                tapFailures.insert(level.pid)
                AppLog.engine.error(
                    "Tap for pid \(level.pid) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        for (uid, pids) in wanted {
            let alive = pids.filter { taps[$0] != nil }
            if alive.isEmpty { wanted.removeValue(forKey: uid) } else { wanted[uid] = alive }
        }
    }

    // MARK: - Таппы

    private func makeTap(for level: Level) throws -> TapSlot {
        let processObject = try Self.processObject(for: level.pid)

        let description = CATapDescription(
            stereoMixdownOfProcesses: [processObject]
        )
        description.name = "AudioMixer Tap (pid \(level.pid))"
        description.uuid = UUID()
        description.isPrivate = true
        // Ключевой момент: система сама глушит оригинальный выход процесса,
        // пока tap активен. Именно это исключает двойное воспроизведение.
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID.unknown
        try caCheck(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
        guard tapID.isValid else { throw CAError.objectNotFound("process tap for pid \(level.pid)") }

        let channels = (try? tapChannelCount(tapID)) ?? 2

        AppLog.engine.info("Created tap \(tapID) for pid \(level.pid), \(channels) ch")

        return TapSlot(
            pid: level.pid,
            tapID: tapID,
            uid: description.uuid.uuidString,
            channelCount: channels,
            gain: level.effectiveGain
        )
    }

    private func tapChannelCount(_ tapID: AudioObjectID) throws -> Int {
        var asbd = AudioStreamBasicDescription()
        asbd = try tapID.read(AudioProperty(kAudioTapPropertyFormat), defaultValue: asbd)
        return Int(asbd.mChannelsPerFrame)
    }

    /// pid -> AudioObjectID процесса в Core Audio.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioProperty(kAudioHardwarePropertyTranslatePIDToProcessObject).address
        var pidValue = pid
        var objectID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        try caCheck(
            AudioObjectGetPropertyData(
                .system, &address,
                UInt32(MemoryLayout<pid_t>.size), &pidValue,
                &size, &objectID
            ),
            "TranslatePIDToProcessObject(\(pid))"
        )
        guard objectID.isValid else { throw CAError.objectNotFound("audio process for pid \(pid)") }
        return objectID
    }

    // MARK: - Агрегатное устройство

    /// Агрегат ВСЕГДА пересоздаётся под текущий набор таппов маршрута.
    ///
    /// Почему не обновлять tap-list на живом устройстве: запись свойства
    /// kAudioAggregateDevicePropertyTapList возвращает noErr, но фактически
    /// не применяется — устройство остаётся без входных потоков (0 каналов),
    /// и таппы никто не читает. На уже работающем агрегате такая запись
    /// вдобавок обнуляет вход, который до этого работал. Проверено стендом
    /// на macOS 26.5. Рабочий путь один: список таппов в словаре создания.
    private func rebuildRouteUnsafe(_ route: Route) throws {
        teardownDeviceUnsafe(route)

        let tapList = route.pids.compactMap { taps[$0] }
        guard !tapList.isEmpty else { return }

        // Префикс общий с фильтром в AudioDeviceManager: по нему наши агрегаты
        // отсеиваются из списка устройств вывода.
        let uid = AudioMixerDevice.aggregateUIDPrefix + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioMixer",
            kAudioAggregateDeviceUIDKey: uid,
            // Реальное устройство задаёт clock. Всё считается в его домене.
            kAudioAggregateDeviceMainSubDeviceKey: route.outputUID,
            // Приватное — не появляется в списке устройств пользователя.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: route.outputUID]
            ],
            kAudioAggregateDeviceTapListKey: tapList.map {
                [kAudioSubTapUIDKey: $0.uid] as [String: Any]
            }
        ]

        var deviceID = AudioObjectID.unknown
        try caCheck(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            "AudioHardwareCreateAggregateDevice"
        )
        guard deviceID.isValid else { throw CAError.objectNotFound("aggregate device") }

        route.aggregateID = deviceID
        AppLog.engine.info(
            "Route \(route.outputUID, privacy: .public): aggregate \(deviceID) with \(tapList.count) tap(s)"
        )

        bindDeviceVolumeUnsafe(route)
        pushGainMapUnsafe(route)
        try startIfNeededUnsafe(route)
    }

    /// Раскладывает пер-апповые гейны в плоский массив «на каждый входной канал».
    /// Порядок каналов = порядок таппов в tap-list.
    private func pushGainMapUnsafe(_ route: Route) {
        var channelGains: [Float] = []
        channelGains.reserveCapacity(route.pids.count * 2)
        for pid in route.pids {
            guard let slot = taps[pid] else { continue }
            for _ in 0..<max(slot.channelCount, 1) {
                channelGains.append(slot.gain)
            }
        }
        route.renderState.updateChannelGains(channelGains)
    }

    // MARK: - Громкость устройства маршрута

    /// Наш рендер идёт мимо регулятора громкости устройства, поэтому громкость
    /// приходится применять самим. У каждого маршрута она своя: приложение,
    /// уведённое в наушники, обязано слушаться регулятора наушников, а не
    /// того устройства, что выбрано в системе.
    private func bindDeviceVolumeUnsafe(_ route: Route) {
        route.volumeObservers = []

        guard let deviceID = AudioObjectID.device(uid: route.outputUID) else {
            route.renderState.setMasterGain(1)
            return
        }

        let properties = Set(
            deviceID.outputVolumeProperties(settableOnly: false)
                + deviceID.outputMuteProperties(settableOnly: false)
        )

        for property in properties {
            guard let observer = AudioPropertyObserver(
                objectID: deviceID,
                property: property,
                queue: queue,
                handler: { [weak self, weak route] in
                    guard let self, let route else { return }
                    self.refreshMasterGainUnsafe(route, deviceID: deviceID)
                }
            ) else { continue }
            route.volumeObservers.append(observer)
        }

        refreshMasterGainUnsafe(route, deviceID: deviceID)
    }

    private func refreshMasterGainUnsafe(_ route: Route, deviceID: AudioObjectID) {
        let muted = deviceID.readOutputMute() ?? false
        // Прочитать нечем — не приглушаем: выдуманный множитель хуже, чем его
        // отсутствие, а громкостью в этом случае всё равно рулит железо.
        let volume = deviceID.readOutputVolume() ?? 1
        route.renderState.setMasterGain(muted ? 0 : volume)
    }

    // MARK: - IOProc

    private func startIfNeededUnsafe(_ route: Route) throws {
        guard route.aggregateID.isValid, !route.isRunning else { return }

        let renderState = route.renderState
        var procID: AudioDeviceIOProcID?

        // queue: nil => Core Audio вызывает блок на своём realtime-потоке.
        try caCheck(
            AudioDeviceCreateIOProcIDWithBlock(&procID, route.aggregateID, nil) { _, inputData, _, outputData, _ in
                renderState.render(input: inputData, output: outputData)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        guard let procID else { throw CAError.objectNotFound("IOProc") }

        route.ioProcID = procID
        try caCheck(AudioDeviceStart(route.aggregateID, procID), "AudioDeviceStart")
        route.isRunning = true
        AppLog.engine.info("Route \(route.outputUID, privacy: .public): IOProc started")
    }

    // MARK: - Teardown

    /// Только IOProc и агрегат. Таппы остаются жить — их переиспользует
    /// пересборка устройства при изменении набора приложений.
    private func teardownDeviceUnsafe(_ route: Route) {
        if let ioProcID = route.ioProcID, route.aggregateID.isValid {
            AudioDeviceStop(route.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(route.aggregateID, ioProcID)
        }
        route.ioProcID = nil
        route.isRunning = false

        if route.aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(route.aggregateID)
            route.aggregateID = .unknown
        }
    }

    private func teardownRouteUnsafe(_ route: Route) {
        teardownDeviceUnsafe(route)
        route.volumeObservers = []
        route.renderState.updateChannelGains([])
    }

    private func teardownUnsafe() {
        for route in routes.values { teardownRouteUnsafe(route) }
        routes.removeAll()

        for slot in taps.values {
            AudioHardwareDestroyProcessTap(slot.tapID)
        }
        taps.removeAll()
        tapFailures.removeAll()
    }
}
