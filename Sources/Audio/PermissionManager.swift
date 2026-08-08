//
//  PermissionManager.swift
//  AudioMixer
//
//  Process tap требует у пользователя разрешения на захват аудио.
//  Публичного API «спросить статус, не создавая tap» нет, поэтому проверяем
//  единственным честным способом: пробуем создать пробный tap и сразу удаляем.
//  Первая такая попытка и вызывает системный запрос разрешения.
//

import Foundation
import CoreAudio
import AppKit
import Combine

@MainActor
final class PermissionManager: ObservableObject {

    enum Status: Equatable {
        case unknown
        case granted
        case denied
        case unsupported(String)   // например, macOS < 14.4
    }

    @Published private(set) var status: Status = .unknown

    private static let settingsURLs = [
        // На разных версиях macOS разрешение живёт в разных панелях,
        // поэтому открываем первую доступную.
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy"
    ]

    func check() {
        guard #available(macOS 14.4, *) else {
            status = .unsupported("Требуется macOS 14.4 или новее")
            return
        }

        // Пробуем создать tap на самих себя: безвредно, ничего не глушит,
        // но проходит через ту же проверку TCC, что и настоящие таппы.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        do {
            let processObject = try AudioProcessTapEngine.processObject(for: ownPID)
            let description = CATapDescription(
                stereoMixdownOfProcesses: [processObject]
            )
            description.name = "AudioMixer Permission Probe"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tapID = AudioObjectID.unknown
            let result = AudioHardwareCreateProcessTap(description, &tapID)

            if result == noErr, tapID.isValid {
                AudioHardwareDestroyProcessTap(tapID)
                status = .granted
            } else {
                AppLog.permissions.error("Probe tap failed: \(result.fourCCDescription, privacy: .public)")
                status = .denied
            }
        } catch {
            AppLog.permissions.error("Probe failed: \(error.localizedDescription, privacy: .public)")
            status = .denied
        }
    }

    func openSystemSettings() {
        for string in Self.settingsURLs {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
