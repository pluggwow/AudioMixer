//
//  AppContainer.swift
//  AudioMixer
//
//  Простейший composition root. Никакого DI-фреймворка — граф зависимостей
//  маленький и полностью статичный, лишняя абстракция только мешала бы.
//

import SwiftUI

@MainActor
final class AppContainer: ObservableObject {

    static let shared = AppContainer()

    let settings: SettingsStore
    let volumeStore: VolumeStore
    let orderStore: AppOrderStore
    let mixerViewModel: MixerViewModel
    let updateChecker = UpdateChecker()

    private init() {
        let settings = SettingsStore()
        let volumeStore = VolumeStore()
        let orderStore = AppOrderStore()

        self.settings = settings
        self.volumeStore = volumeStore
        self.orderStore = orderStore
        self.mixerViewModel = MixerViewModel(
            settings: settings,
            volumeStore: volumeStore,
            orderStore: orderStore
        )
    }

    func start() {
        settings.applyActivationPolicy()
        settings.applyAppearance()
        settings.syncLoginItem()
        mixerViewModel.start()

        // Не чаще раза в сутки и только если разрешено. Проверка не должна
        // задерживать запуск, поэтому отдельной задачей.
        if settings.checkUpdatesAutomatically {
            Task { await updateChecker.check(force: false) }
        }
    }

    func shutdown() {
        mixerViewModel.shutdown()
    }
}
