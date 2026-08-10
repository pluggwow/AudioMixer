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
                Toggle("Показывать проценты при наведении", isOn: $settings.showVolumePercentage)
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
                LabeledContent("Оформление") {
                    HStack(spacing: 14) {
                        ForEach(AppearanceMode.allCases) { mode in
                            ThemeOption(
                                mode: mode,
                                isSelected: settings.appearanceMode == mode
                            ) {
                                settings.appearanceMode = mode
                            }
                        }
                    }
                }
            }

            Section {
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

// MARK: - Выбор темы

/// Тема выбирается картинкой, а не строкой в списке: так это сделано в
/// системных настройках, и по миниатюре сразу видно, что получится.
struct ThemeOption: View {

    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private let size = CGSize(width: 68, height: 44)
    private let corner: CGFloat = 6

    var body: some View {
        VStack(spacing: 5) {
            preview
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.black.opacity(0.15), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner + 2.5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                )
                .scaleEffect(isHovering && !isSelected ? 1.03 : 1)

            Text(mode.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .light: miniature(dark: false)
        case .dark:  miniature(dark: true)
        case .system:
            // Половина светлая, половина тёмная — как рисует систему сама macOS.
            ZStack {
                miniature(dark: true)
                miniature(dark: false)
                    .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
            }
        }
    }

    /// Миниатюра нашей же панели: заголовок и три строки со слайдерами.
    /// Цвета заданы числами, а не системными: миниатюра должна показывать
    /// свою тему, а не ту, что сейчас в приложении.
    private func miniature(dark: Bool) -> some View {
        let background = dark ? Color(white: 0.14) : Color(white: 0.97)
        let chrome = dark ? Color(white: 0.32) : Color(white: 0.78)
        let track = dark ? Color(white: 0.30) : Color(white: 0.85)
        let fill = dark ? Color.white : Color(white: 0.35)

        return ZStack {
            background
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(chrome).frame(width: 3.5, height: 3.5)
                    }
                }
                .padding(.bottom, 1)

                ForEach(Array([0.62, 0.34, 0.82].enumerated()), id: \.offset) { _, level in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(chrome)
                            .frame(width: 6, height: 6)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(track)
                                Capsule().fill(fill)
                                    .frame(width: proxy.size.width * level)
                            }
                        }
                        .frame(height: 2.5)
                    }
                }
            }
            .padding(6)
        }
    }
}
