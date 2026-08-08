//
//  LoginItemService.swift
//  AudioMixer
//
//  Launch at Login через SMAppService (современная замена устаревшему
//  SMLoginItemSetEnabled и манипуляциям с ~/Library/LaunchAgents).
//

import Foundation
import ServiceManagement

@MainActor
enum LoginItemService {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
