//
//  AudioDeviceInfo.swift
//  AudioMixer
//

import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable {
    let deviceID: AudioObjectID
    let uid: String
    let name: String
    let hasOutput: Bool
    let transportType: UInt32

    var id: String { uid }

    init?(deviceID: AudioObjectID) {
        guard deviceID.isValid else { return nil }
        self.deviceID = deviceID

        guard let uid = deviceID.readStringIfPresent(AudioProperty(kAudioDevicePropertyDeviceUID)) else {
            return nil
        }
        self.uid = uid
        self.name = deviceID.readStringIfPresent(AudioProperty(kAudioObjectPropertyName)) ?? uid
        self.transportType = (try? deviceID.read(
            AudioProperty(kAudioDevicePropertyTransportType), defaultValue: UInt32(0)
        )) ?? 0

        // Устройство считается выходным, если у него есть хотя бы один выходной канал.
        let streamsProperty = AudioProperty(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
        if let raw = try? deviceID.readRaw(streamsProperty) {
            defer { raw.deallocate() }
            let list = raw.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            self.hasOutput = buffers.contains { $0.mNumberChannels > 0 }
        } else {
            self.hasOutput = false
        }
    }

    /// SF Symbol, подходящий типу подключения — как в Control Center.
    ///
    /// У Bluetooth тип подключения не говорит, наушники это или колонка,
    /// поэтому для гарнитур Apple значок уточняется по имени: система
    /// показывает именно их силуэт, и обобщённый значок сразу выдал бы
    /// стороннее приложение.
    var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return bluetoothSymbolName
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        default:
            return "speaker.wave.2"
        }
    }

    private var bluetoothSymbolName: String {
        let lowercased = name.lowercased()
        if lowercased.contains("airpods max") { return "airpodsmax" }
        if lowercased.contains("airpods pro") { return "airpodspro" }
        if lowercased.contains("airpods") { return "airpods" }
        if lowercased.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
}
