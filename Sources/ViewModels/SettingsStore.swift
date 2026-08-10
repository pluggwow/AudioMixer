//
//  SettingsStore.swift
//  AudioMixer
//

import SwiftUI
import Combine

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системная"
        case .light:  return "Светлая"
        case .dark:   return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// То же самое для AppKit: SwiftUI-схемой окно не покрасить.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

enum SliderStyleOption: String, CaseIterable, Identifiable {
    case capsule, thin
    var id: String { rawValue }
    var title: String { self == .capsule ? "Объёмный" : "Тонкий" }
}

@MainActor
final class SettingsStore: ObservableObject {

    @AppStorage("showDockIcon") var showDockIcon: Bool = false {
        didSet { applyActivationPolicy() }
    }
    @AppStorage("showVolumePercentage") var showVolumePercentage: Bool = true
    @AppStorage("defaultVolume") var defaultVolume: Double = 1.0
    @AppStorage("rememberAppVolumes") var rememberAppVolumes: Bool = true
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue {
        didSet { applyAppearance() }
    }
    @AppStorage("showAppIcons") var showAppIcons: Bool = true
    @AppStorage("sliderStyle") var sliderStyleRaw: String = SliderStyleOption.capsule.rawValue
    @AppStorage("launchAtLogin") var launchAtLoginPreference: Bool = false

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    var sliderStyle: SliderStyleOption {
        get { SliderStyleOption(rawValue: sliderStyleRaw) ?? .capsule }
        set { sliderStyleRaw = newValue.rawValue }
    }

    /// Тема задаётся приложению целиком.
    ///
    /// Не через `preferredColorScheme` и не покраской окон из вью: и то и
    /// другое применялось не в момент переключения, а только при следующем
    /// внешнем событии — например, когда пользователь переключался между
    /// приложениями. `NSApp.appearance` вступает в силу сразу и покрывает
    /// заодно рамку окна настроек, до которой SwiftUI-схема не достаёт.
    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { NSApp.activate(ignoringOtherApps: false) }
    }

    func syncLoginItem() {
        launchAtLoginPreference = LoginItemService.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        switch LoginItemService.setEnabled(enabled) {
        case .success:
            launchAtLoginPreference = enabled
        case .failure(let error):
            AppLog.engine.error("Login item failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginPreference = LoginItemService.isEnabled
        }
    }
}
