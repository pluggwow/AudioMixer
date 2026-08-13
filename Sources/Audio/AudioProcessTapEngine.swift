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
//    2. Тапп подключается входом к приватному агрегатному устройству,
//       main sub-device которого — устройство вывода. Агрегат СВОЙ у каждого
//       приложения. Это и позволяет увести одно приложение в наушники, пока
//       остальные играют в динамики, и — главное — делает их независимыми:
//       список таппов задаётся только при создании агрегата, поэтому появление
//       или снятие таппа = пересборка агрегата, а в общем агрегате она рвала
//       звук ВСЕМ, кто в нём был. Дёрнешь громкость одного — лагает музыка
//       в другом.
//    3. В каждом агрегате свой IOProc: читает вход, умножает на gain, пишет
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
        /// Приложение прямо сейчас выводит звук.
        var isPlaying: Bool = false

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

    /// Маршрут одного приложения: его тапп, свой агрегат и свой IOProc.
    private final class Route {
        let pid: pid_t
        var outputUID: String
        var aggregateID: AudioObjectID = .unknown
        var ioProcID: AudioDeviceIOProcID?
        var isRunning = false
        let renderState = RenderState()
        var volumeObservers: [AudioPropertyObserver] = []

        init(pid: pid_t, outputUID: String) {
            self.pid = pid
            self.outputUID = outputUID
        }
    }

    // MARK: - Состояние

    private let queue = DispatchQueue(label: "com.example.AudioMixer.engine", qos: .userInitiated)

    /// Живые таппы по pid. Тапп переживает пересборку агрегатов и переезд
    /// приложения с одного устройства на другое — пересоздавать его незачем.
    private var taps: [pid_t: TapSlot] = [:]
    /// По процессу, а не по устройству: агрегат у каждого приложения свой.
    private var routes: [pid_t: Route] = [:]

    /// Процессы, на которых тапп создать не удалось. Нужны, чтобы немедленный
    /// путь не превращался в долбёжку: без этого списка каждое движение
    /// слайдера заново пыталось бы создать заведомо несоздаваемый тапп —
    /// шестьдесят неудачных вызовов Core Audio в секунду.
    private var tapFailures: Set<pid_t> = []

    private var outputDeviceUID: String?

    /// UID устройств, которые существуют прямо сейчас.
    ///
    /// Пустое множество означает «список ещё не приходил», а не «устройств
    /// нет»: пока он не пришёл, никого никуда не переселяем.
    private var liveDeviceUIDs: Set<String> = []

    /// Уровни в том виде, в каком их прислал UI, — с выбором пользователя.
    /// Подмена пропавшего устройства делается при применении и сюда не
    /// записывается: иначе выбор терялся бы навсегда, а он должен вернуться,
    /// когда устройство подключат обратно.
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

    /// Сообщить, какие устройства сейчас существуют.
    ///
    /// Нужно отдельно от `setOutputDevice`: устройство по умолчанию меняется не
    /// всегда. Если система играла в динамики, а приложение было уведено в
    /// наушники, то отключение наушников умолчание не трогает — и без этого
    /// вызова движок так и остался бы с маршрутом на исчезнувшее устройство.
    func setAvailableDevices(uids: Set<String>) {
        queue.async { [weak self] in
            guard let self, self.liveDeviceUIDs != uids else { return }
            self.liveDeviceUIDs = uids
            self.applyUnsafe(levels: self.lastLevels)
        }
    }

    /// Задержка перед снятием таппа.
    ///
    /// Полторы секунды, а не доли: слайдер у отметки 100% легко пересекает её
    /// туда-обратно много раз подряд, и с короткой задержкой каждое пересечение
    /// успевало снять тапп и создать заново — то есть пересобрать агрегат.
    /// Снятие таппа это уборка, отложить её не жалко: лишнюю секунду работает
    /// уже созданный тапп.
    private static let tapReleaseDelay: TimeInterval = 1.5

    /// Применить набор уровней.
    ///
    /// Гейны — всегда немедленно. Пересборка агрегата дебаунсится, но
    /// НЕСИММЕТРИЧНО: появление таппа применяется сразу, исчезновение — с
    /// задержкой. Ждать появления нельзя — пока таппа нет, приложение играет
    /// в полную громкость, и слайдер выглядит залипшим.
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
            self.queue.asyncAfter(deadline: .now() + Self.tapReleaseDelay, execute: work)
        }
    }

    /// Заменить выбор пользователя на умолчание там, где выбранного устройства
    /// больше нет.
    ///
    /// Наушники отключили, а приложение всё ещё смотрит на их UID. Агрегат на
    /// несуществующем субустройстве не собирается, но тапп к этому моменту уже
    /// создан — а тапп глушит приложение в источнике. В итоге приложение молчит
    /// вообще: ни в наушниках, которых нет, ни в динамиках.
    ///
    /// Сам выбор не стирается, он лежит в `lastLevels` и в настройках. Поэтому
    /// когда устройство подключат обратно, приложение вернётся на него само.
    private func liveLevelsUnsafe(_ levels: [Level]) -> [Level] {
        guard !liveDeviceUIDs.isEmpty else { return levels }

        return levels.map { level in
            guard let uid = level.outputUID, !liveDeviceUIDs.contains(uid) else { return level }
            AppLog.engine.info(
                "Устройство \(uid, privacy: .public) пропало, pid \(level.pid) — на умолчание"
            )
            var moved = level
            moved.outputUID = nil
            return moved
        }
    }

    /// Кому нужен тапп прямо сейчас.
    ///
    /// Кроме тех, кому он нужен по сути, сюда попадают те, у кого он УЖЕ есть
    /// и кто прямо сейчас звучит. Снятие таппа переключает приложение с нашего
    /// рендера обратно на родной выход, и этот переход слышен разрывом —
    /// именно он и рвал звук при возврате громкости на 100%. Поэтому тапп
    /// держится до тишины: в тишине переключение никто не услышит.
    private func requiredLevelsUnsafe(_ levels: [Level]) -> [Level] {
        let defaultUID = outputDeviceUID
        return levels.filter { level in
            level.requiresTap(default: defaultUID) || (taps[level.pid] != nil && level.isPlaying)
        }
    }

    /// Есть ли изменение, которое нельзя откладывать: новый тапп или переезд
    /// приложения на другое устройство. И то и другое — прямое действие
    /// пользователя, результат которого он ждёт сейчас, а не через 150 мс.
    private func needsImmediateApplyUnsafe(levels: [Level]) -> Bool {
        let defaultUID = outputDeviceUID
        // Те же приведённые уровни, что и в applyUnsafe: иначе приложение с
        // пропавшим устройством считалось бы «переехавшим» на каждом движении
        // слайдера и каждый раз тянуло бы за собой полную пересборку.
        let required = requiredLevelsUnsafe(liveLevelsUnsafe(levels))

        if required.contains(where: { taps[$0.pid] == nil && !tapFailures.contains($0.pid) }) {
            return true
        }

        // Приложение переехало на другое устройство — это тоже действие
        // пользователя, а не движение слайдера. Процессы, которым тапп создать
        // не удалось, из проверки исключены: иначе каждое движение слайдера
        // запускало бы полную пересборку заново.
        for level in required where !tapFailures.contains(level.pid) {
            guard let uid = level.resolvedOutput(default: defaultUID) else { continue }
            guard let route = routes[level.pid] else { return true }
            if route.outputUID != uid { return true }
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
        for level in levels {
            guard var slot = taps[level.pid], slot.gain != level.effectiveGain else { continue }
            slot.gain = level.effectiveGain
            taps[level.pid] = slot
            // Только своему маршруту: чужие про эту громкость ничего не знают.
            if let route = routes[level.pid] { pushGainMapUnsafe(route) }
        }
    }

    private func applyUnsafe(levels: [Level]) {
        // Запоминаем сырые уровни, работаем с приведёнными: см. liveLevelsUnsafe.
        lastLevels = levels
        let levels = liveLevelsUnsafe(levels)

        let defaultUID = outputDeviceUID
        let required = requiredLevelsUnsafe(levels)

        do {
            try syncTapsUnsafe(required: required)

            let alive = Set(required.map(\.pid)).filter { taps[$0] != nil }

            // Маршруты, которым больше нечего вести.
            for (pid, route) in routes where !alive.contains(pid) {
                teardownRouteUnsafe(route)
                routes.removeValue(forKey: pid)
            }

            for level in required {
                guard taps[level.pid] != nil,
                      let uid = level.resolvedOutput(default: defaultUID) else { continue }

                if let route = routes[level.pid] {
                    // Пересобираем только если маршрут переехал или не запущен.
                    // Смена громкости сюда не попадает — она идёт быстрым путём
                    // и агрегат не трогает.
                    guard route.outputUID != uid || !route.isRunning else { continue }
                    route.outputUID = uid
                    try rebuildRouteUnsafe(route)
                } else {
                    let route = Route(pid: level.pid, outputUID: uid)
                    routes[level.pid] = route
                    try rebuildRouteUnsafe(route)
                }
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
    private func syncTapsUnsafe(required: [Level]) throws {
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

        guard let slot = taps[route.pid] else { return }

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
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: slot.uid] as [String: Any]
            ]
        ]

        var deviceID = AudioObjectID.unknown
        try caCheck(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            "AudioHardwareCreateAggregateDevice"
        )
        guard deviceID.isValid else { throw CAError.objectNotFound("aggregate device") }

        route.aggregateID = deviceID
        AppLog.engine.info(
            "Маршрут pid \(route.pid) -> \(route.outputUID, privacy: .public): агрегат \(deviceID)"
        )

        bindDeviceVolumeUnsafe(route)
        pushGainMapUnsafe(route)
        try startIfNeededUnsafe(route)
    }

    /// В агрегате один тапп, поэтому карта — это его гейн на каждый канал.
    private func pushGainMapUnsafe(_ route: Route) {
        guard let slot = taps[route.pid] else { return }
        route.renderState.updateChannelGains(
            Array(repeating: slot.gain, count: max(slot.channelCount, 1))
        )
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
