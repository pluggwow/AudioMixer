//
//  AudioMixerApp.swift
//  AudioMixer
//

import SwiftUI

@main
struct AudioMixerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Сцена-пустышка. Значок в менюбаре и панель делает MixerPanelController
        // на AppKit — окно MenuBarExtra приносило собственную подложку, которая
        // затягивала в панель отражения строки меню (подробности там же).
        //
        // Сама сцена всё равно нужна: без неё App нечего вернуть из body, а
        // именно на App висит @NSApplicationDelegateAdaptor. isInserted: false
        // означает, что своего значка эта сцена не добавляет.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            EmptyView()
        }
        // Сцены Settings нет намеренно: настройки открываются своим окном
        // рядом с панелью. Отдельное окно забирало фокус, панель от этого
        // закрывалась, и результат правок было не видно.
    }
}
