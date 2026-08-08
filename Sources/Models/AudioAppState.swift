//
//  AudioAppState.swift
//  AudioMixer
//

import Foundation
import AppKit
import CoreAudio

/// То, что видит UI. Идентифицируется по bundle ID, а не по PID:
/// PID меняется при перезапуске приложения, а настройки должны переживать перезапуск.
struct AudioAppState: Identifiable, Equatable {
    let bundleID: String
    var pid: pid_t
    var objectID: AudioObjectID
    var name: String
    var icon: NSImage?
    var volume: Float
    var isMuted: Bool
    var isPlaying: Bool

    var id: String { bundleID }

    var percentText: String { "\(Int((volume * 100).rounded()))%" }

    var speakerSymbol: String {
        if isMuted { return "speaker.slash.fill" }
        switch volume {
        case ..<0.001: return "speaker.fill"
        case ..<0.34:  return "speaker.wave.1.fill"
        case ..<0.67:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    static func == (lhs: AudioAppState, rhs: AudioAppState) -> Bool {
        lhs.bundleID == rhs.bundleID &&
        lhs.pid == rhs.pid &&
        lhs.volume == rhs.volume &&
        lhs.isMuted == rhs.isMuted &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.name == rhs.name
    }
}

/// Сохраняемые настройки одного приложения.
struct StoredAppSettings: Codable, Equatable {
    var volume: Float
    var isMuted: Bool
    var rememberVolume: Bool
    var displayName: String
    var lastSeen: Date

    init(volume: Float = 1.0,
         isMuted: Bool = false,
         rememberVolume: Bool = true,
         displayName: String = "",
         lastSeen: Date = .now) {
        self.volume = volume
        self.isMuted = isMuted
        self.rememberVolume = rememberVolume
        self.displayName = displayName
        self.lastSeen = lastSeen
    }
}
