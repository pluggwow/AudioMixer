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

    private var deviceID: AudioObjectID = .unknown
    private var volumeObserver: AudioPropertyObserver?
    private var muteObserver: AudioPropertyObserver?
    private var isSyncing = false

    private var volumeProperty: AudioProperty {
        AudioProperty(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
    }
    private var muteProperty: AudioProperty {
        AudioProperty(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    }

    func bind(to deviceID: AudioObjectID?) {
        volumeObserver = nil
        muteObserver = nil

        guard let deviceID, deviceID.isValid else {
            self.deviceID = .unknown
            isControllable = false
            return
        }

        self.deviceID = deviceID
        isControllable = deviceID.hasProperty(volumeProperty) && deviceID.isSettable(volumeProperty)

        volumeObserver = AudioPropertyObserver(objectID: deviceID, property: volumeProperty) { [weak self] in
            Task { @MainActor in self?.syncFromDevice() }
        }
        muteObserver = AudioPropertyObserver(objectID: deviceID, property: muteProperty) { [weak self] in
            Task { @MainActor in self?.syncFromDevice() }
        }

        syncFromDevice()
    }

    func syncFromDevice() {
        guard deviceID.isValid else { return }
        isSyncing = true
        defer { isSyncing = false }

        if let value: Float32 = try? deviceID.read(volumeProperty, defaultValue: Float32(0)) {
            volume = max(0, min(value, 1))
        }
        if deviceID.hasProperty(muteProperty),
           let value: UInt32 = try? deviceID.read(muteProperty, defaultValue: UInt32(0)) {
            isMuted = value != 0
        }
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
        guard deviceID.isValid, isControllable else { return }
        try? deviceID.write(Float32(max(0, min(value, 1))), to: volumeProperty)
    }

    private func writeMute(_ muted: Bool) {
        guard deviceID.isValid, deviceID.isSettable(muteProperty) else { return }
        try? deviceID.write(UInt32(muted ? 1 : 0), to: muteProperty)
    }
}
