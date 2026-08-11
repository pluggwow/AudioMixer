//
//  SettingsView.swift
//  AudioMixer
//
//  Настройки живут не в отдельном окне, а второй половиной той же панели.
//
//  Отдельное окно приходилось открывать поверх панели, и система тут же
//  закрывала панель — фокус уходил. Получалось, что настраиваешь вслепую:
//  чтобы увидеть результат, надо закрыть настройки и открыть панель заново.
//  Здесь закрываться нечему: это одно окно, и микшер виден рядом.
//

import SwiftUI

struct SettingsPaneView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MixerViewModel

    let onClose: () -> Void

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    generalSection
                    appearanceSection
                    audioSection
                    storedAppsSection
                }
                .padding(14)
            }
            // Форма рисует собственный фон списка, а панель под ней —
            // материал. Без этого настройки выглядели бы заплаткой.
            .scrollContentBackground(.hidden)
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack {
            Text("Настройки")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Закрыть настройки")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Секции

    private var generalSection: some View {
        SettingsSection("Основные") {
            SettingsToggle("Запускать при входе в систему", isOn: Binding(
                get: { settings.launchAtLoginPreference },
                set: { settings.setLaunchAtLogin($0) }
            ))
            SettingsToggle("Показывать иконку в Dock", isOn: $settings.showDockIcon)
            SettingsToggle("Показывать проценты при наведении", isOn: $settings.showVolumePercentage)
        }
        .onAppear { settings.syncLoginItem() }
    }

    private var appearanceSection: some View {
        SettingsSection("Оформление") {
            HStack(spacing: 14) {
                ForEach(AppearanceMode.allCases) { mode in
                    ThemeOption(mode: mode, isSelected: settings.appearanceMode == mode) {
                        settings.appearanceMode = mode
                    }
                }
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Liquid Glass")
                    .font(.system(size: 12, weight: .medium))
                Text("Насколько панель просвечивает то, что под ней")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    ForEach(PanelMaterial.allCases) { material in
                        MaterialOption(material: material,
                                       isSelected: settings.panelMaterial == material) {
                            settings.panelMaterial = material
                        }
                    }
                }
                .padding(.top, 2)
            }

            Divider().padding(.vertical, 2)

            SettingsToggle("Показывать иконки приложений", isOn: $settings.showAppIcons)

            Picker("Стиль слайдера", selection: Binding(
                get: { settings.sliderStyle },
                set: { settings.sliderStyle = $0 }
            )) {
                ForEach(SliderStyleOption.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            HStack {
                Text("Порядок приложений")
                Spacer()
                Text(viewModel.hasCustomOrder ? "Вручную" : "Автоматический")
                    .foregroundStyle(.secondary)
                Button("Сбросить") { viewModel.resetOrder() }
                    .disabled(!viewModel.hasCustomOrder)
                    .controlSize(.small)
            }
        }
    }

    private var audioSection: some View {
        SettingsSection("Звук") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Громкость новых приложений")
                    Spacer()
                    Text("\(Int(settings.defaultVolume * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.defaultVolume, in: 0...1)
            }
            SettingsToggle("Запоминать громкость приложений", isOn: $settings.rememberAppVolumes)
        }
    }

    private var storedAppsSection: some View {
        SettingsSection("Сохранённые приложения") {
            if storedEntries.isEmpty {
                Text("Измените громкость любого приложения — оно появится здесь")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(storedEntries, id: \.bundleID) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.settings.displayName.isEmpty ? entry.bundleID : entry.settings.displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text("\(Int(entry.settings.volume * 100))%"
                                 + (entry.settings.isMuted ? " · заглушено" : "")
                                 + (entry.settings.isPinned ? " · закреплено" : ""))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Button {
                            viewModel.volumeStore.forget(bundleID: entry.bundleID)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Забыть настройки этого приложения")
                    }
                }

                Button("Очистить всё", role: .destructive) {
                    viewModel.volumeStore.forgetAll()
                }
                .controlSize(.small)
            }
        }
    }

    private var storedEntries: [(bundleID: String, settings: StoredAppSettings)] {
        viewModel.volumeStore.storage
            .map { ($0.key, $0.value) }
            .sorted { $0.1.lastSeen > $1.1.lastSeen }
    }
}

/// Строка-переключатель: подпись слева, тумблер справа.
///
/// Обычный `Toggle` держит тумблер вплотную к подписи, и строки в колонке
/// выстраивались лесенкой по длине текста.
struct SettingsToggle: View {

    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Заголовок и рамка одной группы настроек.
///
/// Своя, а не `Form`: форма в узкой колонке уводит подписи в перенос и рисует
/// собственный фон поверх материала панели.
struct SettingsSection<Content: View>: View {

    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .font(.system(size: 12))
            // Тумблеры, а не галочки: панель рядом выглядит как системная,
            // и галочки в ней смотрелись бы формой из другого приложения.
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.05))
            )
        }
    }
}

// MARK: - Миниатюры-переключатели

/// Общий вид переключателя-картинки: рамка, подпись, синее выделение.
///
/// Один на оба переключателя намеренно: тема и Liquid Glass стоят рядом, и
/// разъехавшиеся на пару точек рамки были бы заметны сразу.
struct ThumbnailOption<Preview: View>: View {

    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    @State private var isHovering = false

    private let size = CGSize(width: 68, height: 44)
    private let corner: CGFloat = 6

    var body: some View {
        VStack(spacing: 5) {
            preview()
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

            Text(title)
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
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Тема выбирается картинкой, а не строкой в списке: так это сделано в
/// системных настройках, и по миниатюре сразу видно, что получится.
struct ThemeOption: View {

    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        ThumbnailOption(title: mode.title, isSelected: isSelected, action: action) {
            switch mode {
            case .light: PanelMiniature(dark: false)
            case .dark:  PanelMiniature(dark: true)
            case .system:
                // Половина светлая, половина тёмная — как рисует систему сама macOS.
                ZStack {
                    PanelMiniature(dark: true)
                    PanelMiniature(dark: false)
                        .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
                }
            }
        }
    }
}

/// Прозрачность панели. На миниатюре под панелью нарочно пёстрый фон:
/// на однотонном разницы между материалами не увидеть вовсе.
struct MaterialOption: View {

    let material: PanelMaterial
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        ThumbnailOption(title: material.title, isSelected: isSelected, action: action) {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.24, green: 0.28, blue: 0.72),
                             Color(red: 0.62, green: 0.30, blue: 0.78),
                             Color(red: 0.20, green: 0.42, blue: 0.80)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                PanelMiniature(dark: true, opacity: material == .translucent ? 0.45 : 0.96)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(6)
            }
        }
    }
}

/// Миниатюра нашей же панели: заголовок и три строки со слайдерами.
///
/// Цвета заданы числами, а не системными: миниатюра показывает свою тему,
/// а не ту, что сейчас стоит в приложении, — иначе картинка «Светлая»
/// темнела бы вместе с окном и перестала обещать то, что показывает.
struct PanelMiniature: View {

    let dark: Bool
    var opacity: Double = 1

    var body: some View {
        let background = dark ? Color(white: 0.14) : Color(white: 0.97)
        let chrome = dark ? Color(white: 0.32) : Color(white: 0.78)
        let track = dark ? Color(white: 0.30) : Color(white: 0.85)
        let fill = dark ? Color.white : Color(white: 0.35)

        ZStack {
            background.opacity(opacity)

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
