//
//  AudioDeviceManager.swift
//  AudioMixer
//
//  Текущее устройство вывода + список доступных. Тоже на нотификациях.
//  Отдельно ловим отключение Bluetooth-наушников: для нас это просто смена
//  default output device, движок обязан пересобрать агрегат под новое устройство.
//

import Foundation
import CoreAudio
import Combine

@MainActor
final class AudioDeviceManager: ObservableObject {

    @Published private(set) var currentDevice: AudioDeviceInfo?
    @Published private(set) var availableDevices: [AudioDeviceInfo] = []

    private var defaultDeviceObserver: AudioPropertyObserver?
    private var deviceListObserver: AudioPropertyObserver?

    var onDeviceChange: ((AudioDeviceInfo?) -> Void)?

    func start() {
        defaultDeviceObserver = AudioPropertyObserver(
            objectID: .system,
            property: AudioProperty(kAudioHardwarePropertyDefaultOutputDevice)
        ) { [weak self] in
            Task { @MainActor in self?.refreshCurrentDevice() }
        }

        deviceListObserver = AudioPropertyObserver(
            objectID: .system,
            property: AudioProperty(kAudioHardwarePropertyDevices)
        ) { [weak self] in
            Task { @MainActor in self?.refreshDeviceList() }
        }

        refreshDeviceList()
        refreshCurrentDevice()
    }

    func stop() {
        defaultDeviceObserver = nil
        deviceListObserver = nil
    }

    func refreshCurrentDevice() {
        guard let deviceID: AudioObjectID = try? AudioObjectID.system.read(
            AudioProperty(kAudioHardwarePropertyDefaultOutputDevice),
            defaultValue: AudioObjectID.unknown
        ), deviceID.isValid else {
            currentDevice = nil
            onDeviceChange?(nil)
            return
        }

        let device = AudioDeviceInfo(deviceID: deviceID)
        guard device != currentDevice else { return }
        currentDevice = device
        AppLog.devices.info("Default output: \(device?.name ?? "nil", privacy: .public)")
        onDeviceChange?(device)
    }

    func refreshDeviceList() {
        guard let ids: [AudioObjectID] = try? AudioObjectID.system.readArray(
            AudioProperty(kAudioHardwarePropertyDevices)
        ) else { return }

        availableDevices = ids
            .compactMap { AudioDeviceInfo(deviceID: $0) }
            .filter { $0.hasOutput && !$0.name.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Задел под быстрое переключение устройства из UI.
    func selectDevice(_ device: AudioDeviceInfo) {
        do {
            try AudioObjectID.system.write(
                device.deviceID,
                to: AudioProperty(kAudioHardwarePropertyDefaultOutputDevice)
            )
        } catch {
            AppLog.devices.error("Failed to set default device: \(error.localizedDescription, privacy: .public)")
        }
    }
}
