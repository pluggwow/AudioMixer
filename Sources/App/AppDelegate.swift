//
//  AppDelegate.swift
//  AudioMixer
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppContainer.shared.start()
            // Значок в менюбаре ставится после старта контейнера: он
            // подписывается на громкость, которой до старта ещё нет.
            MixerPanelController.shared.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Освобождаем таппы и агрегаты сами, не полагаясь на систему.
        //
        // Раньше здесь было написано, что без этого они остаются в coreaudiod,
        // а тапнутые приложения — заглушёнными. Проверено опытом: это не так.
        // Микшер с живым таппом убит через kill -9 — заглушённое приложение
        // вернулось к полной громкости, то есть систему объекты пережить не
        // могут: и процессные таппы, и приватные агрегаты привязаны к клиенту.
        // (Обычный, не приватный агрегат — переживает; наши приватные.)
        //
        // Явный teardown всё равно нужен: он снимает заглушение сразу и
        // предсказуемо, а не когда система соберётся прибрать за упавшим
        // процессом.
        MainActor.assumeIsolated {
            AppContainer.shared.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
