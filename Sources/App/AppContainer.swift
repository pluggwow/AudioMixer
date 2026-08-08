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
    let mixerViewModel: MixerViewModel

    private init() {
        let settings = SettingsStore()
        let volumeStore = VolumeStore()

        self.settings = settings
        self.volumeStore = volumeStore
        self.mixerViewModel = MixerViewModel(settings: settings, volumeStore: volumeStore)
    }

    func start() {
        settings.applyActivationPolicy()
        settings.syncLoginItem()
        mixerViewModel.start()
    }

    func shutdown() {
        mixerViewModel.shutdown()
    }
}
