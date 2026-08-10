//
//  SettingsView.swift
//  AudioMixer
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MixerViewModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Основные", systemImage: "gearshape") }

            AudioSettingsView()
                .tabItem { Label("Звук", systemImage: "speaker.wave.2") }

            AppearanceSettingsView()
                .tabItem { Label("Оформление", systemImage: "paintbrush") }

            ApplicationsSettingsView()
                .tabItem { Label("Приложения", systemImage: "square.grid.2x2") }
        }
        .frame(width: 480, height: 360)
        .preferredColorScheme(settings.appearanceMode.colorScheme)
    }
}

// MARK: - Основные

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { settings.launchAtLoginPreference },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Toggle("Показывать иконку в Dock", isOn: $settings.showDockIcon)
                Toggle("Показывать проценты громкости", isOn: $settings.showVolumePercentage)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.syncLoginItem() }
    }
}

// MARK: - Звук

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MixerViewModel

    var body: some View {
        Form {
            Section("Устройство вывода") {
                Picker("Устройство", selection: Binding(
                    get: { viewModel.outputDevice?.uid ?? "" },
                    set: { uid in
                        if let device = viewModel.availableDevices.first(where: { $0.uid == uid }) {
                            viewModel.selectOutputDevice(device)
                        }
                    }
                )) {
                    ForEach(viewModel.availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section("Громкость") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Громкость по умолчанию для новых приложений")
                        Spacer()
                        Text("\(Int(settings.defaultVolume * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.defaultVolume, in: 0...1)
                }
                Toggle("Запоминать громкость приложений", isOn: $settings.rememberAppVolumes)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Оформление

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MixerViewModel

    var body: some View {
        Form {
            Section {
                Picker("Тема", selection: Binding(
                    get: { settings.appearanceMode },
                    set: { settings.appearanceMode = $0 }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Компактный режим", isOn: $settings.compactMode)
                Toggle("Показывать иконки приложений", isOn: $settings.showAppIcons)
                Picker("Стиль слайдера", selection: Binding(
                    get: { settings.sliderStyle },
                    set: { settings.sliderStyle = $0 }
                )) {
                    ForEach(SliderStyleOption.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }

            Section {
                HStack {
                    Text("Порядок приложений")
                    Spacer()
                    Text(viewModel.hasCustomOrder ? "Вручную" : "Автоматический")
                        .foregroundStyle(.secondary)
                    Button("Сбросить") { viewModel.resetOrder() }
                        .disabled(!viewModel.hasCustomOrder)
                }
            } footer: {
                Text("Строки в панели переставляются перетаскиванием. Автоматически сверху идут те, что играют прямо сейчас.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Приложения

struct ApplicationsSettingsView: View {
    @EnvironmentObject private var viewModel: MixerViewModel

    private var entries: [(bundleID: String, settings: StoredAppSettings)] {
        viewModel.volumeStore.storage
            .map { ($0.key, $0.value) }
            .sorted { $0.1.lastSeen > $1.1.lastSeen }
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Нет сохранённых приложений",
                    systemImage: "square.grid.2x2",
                    description: Text("Измените громкость любого приложения — оно появится здесь")
                )
            } else {
                List {
                    ForEach(entries, id: \.bundleID) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.settings.displayName.isEmpty ? entry.bundleID : entry.settings.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Text("Громкость: \(Int(entry.settings.volume * 100))%" + (entry.settings.isMuted ? " · заглушено" : ""))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("Запоминать", isOn: Binding(
                                get: { entry.settings.rememberVolume },
                                set: { viewModel.volumeStore.setRememberVolume($0, for: entry.bundleID) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()

                            Button {
                                viewModel.volumeStore.forget(bundleID: entry.bundleID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                    }
                }

                HStack {
                    Spacer()
                    Button("Очистить всё", role: .destructive) {
                        viewModel.volumeStore.forgetAll()
                    }
                }
                .padding(10)
            }
        }
    }
}
