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
    /// Закреплено пользователем: строка остаётся в списке и после закрытия приложения.
    var isPinned: Bool = false
    /// Приложение сейчас запущено. `false` — это закреплённая строка закрытого
    /// приложения: громкость ей выставить можно, а таппить нечего.
    var isRunning: Bool = true

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
        lhs.isPinned == rhs.isPinned &&
        lhs.isRunning == rhs.isRunning &&
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
    var isPinned: Bool

    init(volume: Float = 1.0,
         isMuted: Bool = false,
         rememberVolume: Bool = true,
         displayName: String = "",
         lastSeen: Date = .now,
         isPinned: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
        self.rememberVolume = rememberVolume
        self.displayName = displayName
        self.lastSeen = lastSeen
        self.isPinned = isPinned
    }

    /// Декодер написан руками из-за одной особенности Swift: синтезированный
    /// `init(from:)` НЕ подставляет значения по умолчанию для отсутствующих
    /// ключей — он бросает `keyNotFound`. Для нового поля это означало бы, что
    /// у всех, кто уже пользовался приложением, настройки не прочитаются, а
    /// VolumeStore в ответ заблокирует запись — со стороны «пропали все
    /// сохранённые громкости». Поэтому новые поля добавлять только через
    /// `decodeIfPresent`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decode(Float.self, forKey: .volume)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        rememberVolume = try container.decode(Bool.self, forKey: .rememberVolume)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}
