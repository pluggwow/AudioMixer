//
//  AppDelegate.swift
//  AudioMixer
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppContainer.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Критично: без явного teardown агрегатное устройство и таппы
        // остаются в coreaudiod, а тапнутые приложения — заглушёнными.
        MainActor.assumeIsolated {
            AppContainer.shared.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
