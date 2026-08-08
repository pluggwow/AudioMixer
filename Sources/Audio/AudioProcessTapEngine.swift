//
//  AudioProcessTapEngine.swift
//  AudioMixer
//
//  Сердце проекта. Реализует per-app volume через официальный Core Audio API:
//
//    1. На каждое приложение, чья громкость != 100% (или замьючено), создаётся
//       CATapDescription с muteBehavior = .mutedWhenTapped. Система при этом
//       ГЛУШИТ оригинальный выход процесса — двойного звука не возникает.
//    2. Все таппы подключаются как входы к одному приватному агрегатному устройству,
//       main sub-device которого — реальное устройство вывода пользователя.
//    3. Один IOProc читает входы, умножает на gain и пишет в выход.
//       Общий clock domain => нет ресемплинга, нет дрейфа, латентность = 1 буфер.
//
//  Приложения на 100% без mute НЕ таппятся вообще — они играют мимо нас нативно.
//  Если таких приложений, которым нужен tap, нет — движок полностью выключается
//  (агрегат уничтожается), и потребление CPU падает до нуля.
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

        /// Итоговый gain. 1.0 означает «tap не нужен».
        var effectiveGain: Float { isMuted ? 0 : max(0, min(volume, 1)) }
        var requiresTap: Bool { isMuted || volume < 0.999 }
    }

    private struct TapSlot {
        let pid: pid_t
        let tapID: AudioObjectID
        let uid: String
        let channelCount: Int
        var gain: Float
    }

    // MARK: - Состояние

    private let queue = DispatchQueue(label: "com.example.AudioMixer.engine", qos: .userInitiated)
    private let renderState = RenderState()

    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    private var slots: [TapSlot] = []
    private var outputDeviceUID: String?
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

    /// Задать/сменить устройство вывода. Полная пересборка агрегата.
    func setOutputDevice(uid: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.outputDeviceUID != uid else { return }
            AppLog.engine.info("Output device changed to \(uid ?? "nil", privacy: .public)")
            self.outputDeviceUID = uid
            let current = self.slots
            self.teardownUnsafe()
            self.slots = []
            self.applyUnsafe(levels: current.map {
                Level(pid: $0.pid, volume: $0.gain, isMuted: $0.gain == 0)
            })
        }
    }

    /// Применить набор уровней. Дебаунсится, чтобы движение слайдера
    /// не пересобирало tap-list десятки раз в секунду.
    func apply(levels: [Level]) {
        pendingWorkItem?.cancel()

        // Быстрый путь: если набор нужных таппов не изменился, меняем только gain.
        // Это не требует пересборки агрегата и происходит мгновенно.
        let work = DispatchWorkItem { [weak self] in
            self?.applyUnsafe(levels: levels)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)

        // Гейны обновляем немедленно, без дебаунса — слайдер должен реагировать сразу.
        queue.async { [weak self] in
            self?.updateGainsOnlyUnsafe(levels: levels)
        }
    }

    func setMasterGain(_ gain: Float) {
        renderState.setMasterGain(gain)
    }

    func shutdown() {
        pendingWorkItem?.cancel()
        queue.sync { [weak self] in
            self?.teardownUnsafe()
        }
    }

    // MARK: - Реализация (всегда на self.queue)

    private func updateGainsOnlyUnsafe(levels: [Level]) {
        var changed = false
        for index in slots.indices {
            let pid = slots[index].pid
            guard let level = levels.first(where: { $0.pid == pid }) else { continue }
            if slots[index].gain != level.effectiveGain {
                slots[index].gain = level.effectiveGain
                changed = true
            }
        }
        if changed { pushGainMapUnsafe() }
    }

    private func applyUnsafe(levels: [Level]) {
        let required = levels.filter { $0.requiresTap }
        let requiredPIDs = Set(required.map(\.pid))
        let currentPIDs = Set(slots.map(\.pid))

        guard requiredPIDs != currentPIDs || (required.isEmpty && isRunning) else {
            updateGainsOnlyUnsafe(levels: levels)
            return
        }

        // Ничего таппить не нужно — гасим движок целиком.
        guard !required.isEmpty else {
            AppLog.engine.info("No taps required, shutting engine down")
            teardownUnsafe()
            state = .idle
            return
        }

        do {
            // Удаляем лишние таппы.
            for slot in slots where !requiredPIDs.contains(slot.pid) {
                AudioHardwareDestroyProcessTap(slot.tapID)
            }
            slots.removeAll { !requiredPIDs.contains($0.pid) }

            // Создаём недостающие.
            for level in required where !currentPIDs.contains(level.pid) {
                do {
                    let slot = try makeTap(for: level)
                    slots.append(slot)
                } catch {
                    // Один упавший процесс не должен ронять весь микшер.
                    AppLog.engine.error("Tap for pid \(level.pid) failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            guard !slots.isEmpty else {
                teardownUnsafe()
                state = .idle
                return
            }

            // Актуализируем гейны.
            for index in slots.indices {
                if let level = levels.first(where: { $0.pid == slots[index].pid }) {
                    slots[index].gain = level.effectiveGain
                }
            }

            try rebuildAggregateUnsafe()
            pushGainMapUnsafe()
            try startIfNeededUnsafe()

            state = .running(tapCount: slots.count)

        } catch {
            AppLog.engine.error("Engine apply failed: \(error.localizedDescription, privacy: .public)")
            teardownUnsafe()
            state = .failed(error.localizedDescription)
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

    /// Агрегат ВСЕГДА пересоздаётся под текущий набор таппов.
    ///
    /// Почему не обновлять tap-list на живом устройстве: запись свойства
    /// kAudioAggregateDevicePropertyTapList возвращает noErr, но фактически
    /// не применяется — устройство остаётся без входных потоков (0 каналов),
    /// и таппы никто не читает. На уже работающем агрегате такая запись
    /// вдобавок обнуляет вход, который до этого работал. Проверено стендом
    /// на macOS 26.5. Рабочий путь один: список таппов в словаре создания.
    private func rebuildAggregateUnsafe() throws {
        teardownDeviceUnsafe()

        guard !slots.isEmpty else { return }
        guard let outputUID = outputDeviceUID else {
            throw CAError.objectNotFound("output device UID")
        }

        let uid = "com.example.AudioMixer.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioMixer",
            kAudioAggregateDeviceUIDKey: uid,
            // Реальное устройство задаёт clock. Всё считается в его домене.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Приватное — не появляется в списке устройств пользователя.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: slots.map {
                [kAudioSubTapUIDKey: $0.uid] as [String: Any]
            }
        ]

        var deviceID = AudioObjectID.unknown
        try caCheck(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            "AudioHardwareCreateAggregateDevice"
        )
        guard deviceID.isValid else { throw CAError.objectNotFound("aggregate device") }

        aggregateID = deviceID
        AppLog.engine.info("Created private aggregate device \(deviceID) with \(self.slots.count) tap(s)")
    }

    /// Раскладывает пер-апповые гейны в плоский массив «на каждый входной канал».
    /// Порядок каналов = порядок таппов в tap-list.
    private func pushGainMapUnsafe() {
        var channelGains: [Float] = []
        channelGains.reserveCapacity(slots.count * 2)
        for slot in slots {
            for _ in 0..<max(slot.channelCount, 1) {
                channelGains.append(slot.gain)
            }
        }
        renderState.updateChannelGains(channelGains)
    }

    // MARK: - IOProc

    private func startIfNeededUnsafe() throws {
        guard aggregateID.isValid, !isRunning else { return }

        let renderState = self.renderState
        var procID: AudioDeviceIOProcID?

        // queue: nil => Core Audio вызывает блок на своём realtime-потоке.
        try caCheck(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, _, outputData, _ in
                renderState.render(input: inputData, output: outputData)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        guard let procID else { throw CAError.objectNotFound("IOProc") }

        ioProcID = procID
        try caCheck(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        isRunning = true
        AppLog.engine.info("IOProc started")
    }

    // MARK: - Teardown

    /// Только IOProc и агрегат. Таппы остаются жить — их переиспользует
    /// пересборка устройства при изменении набора приложений.
    private func teardownDeviceUnsafe() {
        if let ioProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        isRunning = false

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
    }

    private func teardownUnsafe() {
        teardownDeviceUnsafe()

        for slot in slots {
            AudioHardwareDestroyProcessTap(slot.tapID)
        }
        slots.removeAll()
        renderState.updateChannelGains([])
    }
}
