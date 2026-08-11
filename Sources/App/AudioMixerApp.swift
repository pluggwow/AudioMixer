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
            MenuBarIcon(systemVolume: container.mixerViewModel.systemVolume)
        }
        .menuBarExtraStyle(.window)
        // Сцены Settings нет намеренно: настройки открываются второй колонкой
        // той же панели. Отдельное окно забирало фокус, панель от этого
        // закрывалась, и результат правок было не видно.
    }
}

/// Значок в строке меню — такой же динамик, как у системного регулятора
/// громкости, и так же отзывается на её уровень.
///
/// Отдельный View, а не Image прямо в label: @StateObject на контейнере
/// следит только за самим контейнером, а уровень громкости живёт во вложенном
/// объекте — без своего @ObservedObject значок замер бы на состоянии,
/// в котором приложение запустилось.
private struct MenuBarIcon: View {

    @ObservedObject var systemVolume: SystemVolumeController

    var body: some View {
        Image(systemName: systemVolume.symbolName)
            .contentTransition(.symbolEffect(.replace))
    }
}
