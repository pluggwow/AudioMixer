//
//  AudioMixerApp.swift
//  AudioMixer
//

import SwiftUI

@main
struct AudioMixerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer.shared

    var body: some Scene {
        MenuBarExtra {
            MixerRootView()
                .environmentObject(container.mixerViewModel)
                .environmentObject(container.settings)
        } label: {
            Image(systemName: "slider.horizontal.2.square")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(container.mixerViewModel)
                .environmentObject(container.settings)
        }
    }
}
