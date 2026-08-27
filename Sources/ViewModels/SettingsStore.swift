//
//  SettingsStore.swift
//  AudioMixer
//

import SwiftUI
import Combine

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Системная")
        case .light:  return String(localized: "Светлая")
        case .dark:   return String(localized: "Тёмная")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// То же самое для AppKit: SwiftUI-схемой окно не покрасить.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Насколько панель просвечивает то, что под ней.
enum PanelMaterial: String, CaseIterable, Identifiable {
    case translucent, solid
    var id: String { rawValue }

    var title: String {
        self == .translucent ? String(localized: "Прозрачное") : String(localized: "Однотонное")
    }

    var shapeStyle: AnyShapeStyle {
        switch self {
        // Панель менюбара рисует под нами собственную подложку — уже
        // полупрозрачную. Наш слой ложится на неё вторым стеклом, поэтому чем
        // он слабее, тем ближе результат к системным панелям. Совсем убрать
        // нельзя: на светлых обоях текст по подложке читается плохо.
        //
        // NSVisualEffectView здесь не подошёл: .hudWindow оказался материалом
        // тёмных HUD-окон и в светлой теме рисовался почти сплошным, а
        // смешивание .behindWindow до рабочего стола не добралось — панель
        // стала плотнее, а не прозрачнее.
        case .translucent: return AnyShapeStyle(.ultraThinMaterial.opacity(0.25))
        case .solid:       return AnyShapeStyle(.thickMaterial)
        }
    }
}

/// Высота строки приложения.
enum RowDensity: String, CaseIterable, Identifiable {
    case compact, normal, large
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return String(localized: "Компактная")
        case .normal:  return String(localized: "Обычная")
        case .large:   return String(localized: "Крупная")
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 30
        case .normal:  return 38
        case .large:   return 46
        }
    }
}

/// Ширина панели. Лишнее место достаётся названию приложения: слайдер своей
/// ширины не меняет, пока она есть.
enum PanelWidthOption: String, CaseIterable, Identifiable {
    case narrow, normal, wide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: return String(localized: "Узкая")
        case .normal: return String(localized: "Обычная")
        case .wide:   return String(localized: "Широкая")
        }
    }

    var points: CGFloat {
        switch self {
        case .narrow: return 320
        case .normal: return 360
        case .wide:   return 420
        }
    }
}

/// Сколько строк видно до прокрутки.
enum VisibleRowsOption: String, CaseIterable, Identifiable {
    case three, fourAndHalf, six, eight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .three:       return "3"
        case .fourAndHalf: return "4,5"
        case .six:         return "6"
        case .eight:       return "8"
        }
    }

    /// Половина строки в 4,5 — не прихоть: она сразу говорит, что список
    /// продолжается, иначе о прокрутке можно и не догадаться.
    var count: CGFloat {
        switch self {
        case .three:       return 3
        case .fourAndHalf: return 4.5
        case .six:         return 6
        case .eight:       return 8
        }
    }
}

/// Язык интерфейса.
///
/// Своих строк у этого перечисления почти нет: названия языков пишутся на них
/// самих — так делает и система, и человек, ищущий свой язык в списке, найдёт
/// его, даже если сейчас включён чужой.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Системный")
        case .ru:     return "Русский"
        case .en:     return "English"
        }
    }

    /// Что положить в AppleLanguages. `nil` — убрать ключ и вернуться к системе.
    var languageCodes: [String]? {
        switch self {
        case .system: return nil
        case .ru:     return ["ru"]
        case .en:     return ["en"]
        }
    }
}

enum SliderStyleOption: String, CaseIterable, Identifiable {
    case capsule, thin
    var id: String { rawValue }
    var title: String {
        self == .capsule ? String(localized: "Объёмный") : String(localized: "Тонкий")
    }
}

@MainActor
final class SettingsStore: ObservableObject {

    @AppStorage("showDockIcon") var showDockIcon: Bool = false {
        didSet { applyActivationPolicy() }
    }
    @AppStorage("showVolumePercentage") var showVolumePercentage: Bool = true
    @AppStorage("defaultVolume") var defaultVolume: Double = 1.0
    @AppStorage("rememberAppVolumes") var rememberAppVolumes: Bool = true
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue {
        didSet { applyAppearance() }
    }
    @AppStorage("showAppIcons") var showAppIcons: Bool = true
    @AppStorage("panelMaterial") var panelMaterialRaw: String = PanelMaterial.translucent.rawValue
    @AppStorage("rowDensity") var rowDensityRaw: String = RowDensity.normal.rawValue
    @AppStorage("panelWidth") var panelWidthRaw: String = PanelWidthOption.normal.rawValue
    @AppStorage("visibleRows") var visibleRowsRaw: String = VisibleRowsOption.fourAndHalf.rawValue
    @AppStorage("showOutputButton") var showOutputButton: Bool = true
    @AppStorage("sliderStyle") var sliderStyleRaw: String = SliderStyleOption.capsule.rawValue
    @AppStorage("launchAtLogin") var launchAtLoginPreference: Bool = false
    @AppStorage("appLanguage") var appLanguageRaw: String = AppLanguage.system.rawValue
    /// Раз в сутки спрашивать у GitHub, не вышла ли новая версия.
    ///
    /// Это единственное, ради чего приложение вообще ходит в сеть, поэтому
    /// выключатель на виду: кто не хочет — выключает, кнопка проверки вручную
    /// при этом остаётся.
    @AppStorage("checkUpdatesAutomatically") var checkUpdatesAutomatically: Bool = true

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    var panelMaterial: PanelMaterial {
        get { PanelMaterial(rawValue: panelMaterialRaw) ?? .translucent }
        set { panelMaterialRaw = newValue.rawValue }
    }

    var rowDensity: RowDensity {
        get { RowDensity(rawValue: rowDensityRaw) ?? .normal }
        set { rowDensityRaw = newValue.rawValue }
    }

    var panelWidth: PanelWidthOption {
        get { PanelWidthOption(rawValue: panelWidthRaw) ?? .normal }
        set { panelWidthRaw = newValue.rawValue }
    }

    var visibleRows: VisibleRowsOption {
        get { VisibleRowsOption(rawValue: visibleRowsRaw) ?? .fourAndHalf }
        set { visibleRowsRaw = newValue.rawValue }
    }

    /// Размеры строки под текущие настройки.
    var rowMetrics: RowMetrics {
        RowMetrics(panelWidth: panelWidth.points,
                   rowHeight: rowDensity.rowHeight,
                   showsOutputButton: showOutputButton)
    }

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguageRaw) ?? .system }
        set { appLanguageRaw = newValue.rawValue }
    }

    var sliderStyle: SliderStyleOption {
        get { SliderStyleOption(rawValue: sliderStyleRaw) ?? .capsule }
        set { sliderStyleRaw = newValue.rawValue }
    }

    /// Тема задаётся приложению целиком.
    ///
    /// Не через `preferredColorScheme` и не покраской окон из вью: и то и
    /// другое применялось не в момент переключения, а только при следующем
    /// внешнем событии — например, когда пользователь переключался между
    /// приложениями. `NSApp.appearance` вступает в силу сразу и покрывает
    /// заодно рамку окна настроек, до которой SwiftUI-схема не достаёт.
    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    /// Сменить язык интерфейса.
    ///
    /// На лету это не делается: macOS выбирает локализацию один раз, при
    /// запуске, и уже загруженные строки заново не перечитываются. Живая смена
    /// потребовала бы гонять каждую строку через свой Bundle, то есть переписать
    /// все места разом — ради настройки, которую трогают один раз в жизни.
    /// Поэтому пишем AppleLanguages и перезапускаемся.
    func setLanguage(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language

        let defaults = UserDefaults.standard
        if let codes = language.languageCodes {
            defaults.set(codes, forKey: "AppleLanguages")
        } else {
            // Ключа нет — язык берётся системный.
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.synchronize()

        relaunch()
    }

    /// Перезапуск: сначала ставим отложенный запуск, потом выходим.
    ///
    /// Порядок именно такой. Запустить копию до выхода нельзя: два экземпляра
    /// одновременно полезут в Core Audio за таппами одних и тех же процессов.
    /// Оболочка переживает наш выход — её подхватывает launchd.
    ///
    /// Два правила, купленные опытом: teardown руками отсюда не звать — его
    /// сделает applicationWillTerminate, а второй вызов подряд вешал выход
    /// намертво; и `terminate` не звать прямо из обработчика пикера — вызов
    /// приходится на обновление вида SwiftUI и просто теряется. Обе ошибки
    /// выглядели одинаково: новый экземпляр поднимался, старый оставался жить.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"$0\"", path]
        try? task.run()

        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { NSApp.activate(ignoringOtherApps: false) }
    }

    func syncLoginItem() {
        launchAtLoginPreference = LoginItemService.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        switch LoginItemService.setEnabled(enabled) {
        case .success:
            launchAtLoginPreference = enabled
        case .failure(let error):
            AppLog.engine.error("Login item failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginPreference = LoginItemService.isEnabled
        }
    }
}
