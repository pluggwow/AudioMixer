//
//  SystemVolumeController.swift
//  AudioMixer
//
//  Мастер-громкость = штатная громкость текущего устройства вывода.
//  Мы её не эмулируем и не подменяем — двигаем ровно ту же ручку, что и системный
//  регулятор, поэтому значения всегда совпадают с тем, что показывает macOS.
//

import Foundation
import CoreAudio
import Combine

@MainActor
final class SystemVolumeController: ObservableObject {

    @Published var volume: Float = 0.5 {
        didSet {
            guard !isSyncing, abs(volume - oldValue) > 0.0001 else { return }
            writeVolume(volume)
        }
    }

    @Published var isMuted: Bool = false {
        didSet {
            guard !isSyncing, isMuted != oldValue else { return }
            writeMute(isMuted)
        }
    }

    /// Не все устройства поддерживают программное управление громкостью
    /// (типично для цифровых выходов: HDMI, оптика, часть внешних DAC).
    @Published private(set) var isControllable: Bool = true

    /// Отдельный признак: громкость может регулироваться, а mute — нет.
    @Published private(set) var isMuteSupported: Bool = true

    private var deviceID: AudioObjectID = .unknown
    private var observers: [AudioPropertyObserver] = []
    private var isSyncing = false

    /// Свойства, в которых у устройства реально живут громкость и mute.
    ///
    /// Спрашивать только мастер-элемент выходной области нельзя: у многих
    /// устройств — прежде всего Bluetooth-гарнитур — мастера нет вовсе, а
    /// громкость есть отдельно на каждом канале; у части устройств она лежит
    /// в глобальной области. Проверка по одному мастеру объявляла такие
    /// устройства нерегулируемыми, хотя macOS управляет ими прекрасно.
    private var volumeWriteProperties: [AudioProperty] = []
    private var volumeReadProperties: [AudioProperty] = []
    private var muteWriteProperties: [AudioProperty] = []
    private var muteReadProperties: [AudioProperty] = []

    func bind(to deviceID: AudioObjectID?) {
        observers = []

        guard let deviceID, deviceID.isValid else {
            self.deviceID = .unknown
            volumeWriteProperties = []
            volumeReadProperties = []
            muteWriteProperties = []
            muteReadProperties = []
            isControllable = false
            isMuteSupported = false
            return
        }

        self.deviceID = deviceID

        volumeWriteProperties = deviceID.outputVolumeProperties(settableOnly: true)
        muteWriteProperties = deviceID.outputMuteProperties(settableOnly: true)

        // Показать уровень можно и у того, чем управлять нельзя, — цифра
        // всё равно полезна.
        volumeReadProperties = volumeWriteProperties.isEmpty
            ? deviceID.outputVolumeProperties(settableOnly: false)
            : volumeWriteProperties
        muteReadProperties = muteWriteProperties.isEmpty
            ? deviceID.outputMuteProperties(settableOnly: false)
            : muteWriteProperties

        isControllable = !volumeWriteProperties.isEmpty
        isMuteSupported = !muteWriteProperties.isEmpty

        // Лог нужен именно здесь: если устройство опять окажется
        // «нерегулируемым», по нему сразу видно, что и где приложение искало.
        AppLog.devices.info("""
            Регулировка \(self.describe(deviceID), privacy: .public): \
            громкость — запись \(self.describe(self.volumeWriteProperties), privacy: .public), \
            чтение \(self.describe(self.volumeReadProperties), privacy: .public); \
            mute — запись \(self.describe(self.muteWriteProperties), privacy: .public)
            """)

        for property in Set(volumeReadProperties).union(muteReadProperties) {
            guard let observer = AudioPropertyObserver(objectID: deviceID, property: property, handler: { [weak self] in
                Task { @MainActor in self?.syncFromDevice() }
            }) else { continue }
            observers.append(observer)
        }

        syncFromDevice()
    }

    private func describe(_ deviceID: AudioObjectID) -> String {
        deviceID.readStringIfPresent(AudioProperty(kAudioObjectPropertyName)) ?? "устройство \(deviceID)"
    }

    private func describe(_ properties: [AudioProperty]) -> String {
        guard !properties.isEmpty else { return "нечего" }
        return properties
            .map { "\($0.scope.fourCCDescription)/элемент \($0.element)" }
            .joined(separator: ", ")
    }

    func syncFromDevice() {
        guard deviceID.isValid else { return }
        isSyncing = true
        defer { isSyncing = false }

        if let value = readVolume() { volume = max(0, min(value, 1)) }
        if let muted = readMute() { isMuted = muted }
    }

    /// Среднее по каналам: обычно они равны, но если в системе разведён
    /// баланс, одна цифра всё равно должна что-то означать.
    private func readVolume() -> Float? {
        let values = volumeReadProperties.compactMap { property -> Float? in
            try? deviceID.read(property, defaultValue: Float32(0))
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    private func readMute() -> Bool? {
        let values = muteReadProperties.compactMap { property -> UInt32? in
            try? deviceID.read(property, defaultValue: UInt32(0))
        }
        guard !values.isEmpty else { return nil }
        return values.contains { $0 != 0 }
    }

    func toggleMute() { isMuted.toggle() }

    /// Значок громкости как у системного регулятора: число волн растёт с
    /// уровнем, на нуле и на mute — перечёркнутый динамик.
    var symbolName: String {
        if isMuted || volume < 0.001 { return "speaker.slash.fill" }
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default:      return "speaker.wave.3.fill"
        }
    }

    private func writeVolume(_ value: Float) {
        guard deviceID.isValid else { return }
        let clamped = Float32(max(0, min(value, 1)))
        for property in volumeWriteProperties {
            try? deviceID.write(clamped, to: property)
        }
    }

    private func writeMute(_ muted: Bool) {
        guard deviceID.isValid else { return }
        for property in muteWriteProperties {
            try? deviceID.write(UInt32(muted ? 1 : 0), to: property)
        }
    }
}
