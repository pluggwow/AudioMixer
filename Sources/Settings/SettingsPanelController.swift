//
//  SettingsPanelController.swift
//  AudioMixer
//
//  Окно настроек, привязанное к панели микшера: открывается слева от неё.
//
//  Сцена Settings не годится: обычное окно забирает фокус, а панель менюбара
//  система закрывает, как только фокус уходит. Настраивать приходилось
//  вслепую. Поэтому окно здесь своё — NSPanel, который принципиально не
//  становится ключевым:
//
//    .nonactivatingPanel      — клик по нему не активирует приложение;
//    becomesKeyOnlyIfNeeded   — фокус берётся только если он нужен контролу,
//                               а у нас их таких нет: тумблеры, слайдеры и
//                               меню работают и без фокуса.
//
//  Поэтому панель микшера фокус не теряет и остаётся на экране.
//
//  Вкладки собраны на NSToolbar со стилем .preference. Привычный вид настроек
//  со значками давала именно сцена Settings — она превращала SwiftUI-шный
//  TabView в панель инструментов. В своём окне TabView рисуется обычным
//  сегментированным переключателем без значков, поэтому панель инструментов
//  здесь настоящая, как и была.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsPanelController: NSObject, ObservableObject {

    static let shared = SettingsPanelController()

    @Published private(set) var isVisible = false

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var selectedTab: SettingsTab = .general

    /// Зазор между окном настроек и панелью микшера.
    private let gap: CGFloat = 8

    private override init() { super.init() }

    func toggle(nextTo owner: NSWindow?) {
        if isVisible { close() } else { show(nextTo: owner) }
    }

    func show(nextTo owner: NSWindow?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        position(panel, nextTo: owner)
        // orderFrontRegardless, а не makeKeyAndOrderFront: ключевым это окно
        // становиться не должно — иначе панель микшера тут же закроется.
        panel.orderFrontRegardless()
        isVisible = true
    }

    func close() {
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Окно

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: SettingsTab.contentSize),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let hosting = NSHostingView(rootView: content(for: selectedTab))
        self.hosting = hosting
        panel.contentView = hosting
        panel.delegate = self

        let toolbar = NSToolbar(identifier: "AudioMixerSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(selectedTab.rawValue)
        panel.toolbar = toolbar
        // Тот самый вид настроек со значками в ряд.
        panel.toolbarStyle = .preference
        panel.title = selectedTab.title

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Без анимации появления: панель менюбара возникает мгновенно, и
        // выплывающее рядом окно выглядит чужеродно.
        panel.animationBehavior = .none
        // На уровне всплывающих панелей: ниже — и окно уедет под панель микшера.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        return panel
    }

    private func content(for tab: SettingsTab) -> AnyView {
        let container = AppContainer.shared

        let view: AnyView
        switch tab {
        case .general:    view = AnyView(GeneralSettingsView())
        case .audio:      view = AnyView(AudioSettingsView())
        case .appearance: view = AnyView(AppearanceSettingsView())
        case .apps:       view = AnyView(ApplicationsSettingsView())
        }

        return AnyView(
            view
                .frame(width: SettingsTab.contentSize.width,
                       height: SettingsTab.contentSize.height)
                .environmentObject(container.mixerViewModel)
                .environmentObject(container.settings)
        )
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        selectedTab = tab
        hosting?.rootView = content(for: tab)
        panel?.title = tab.title
        panel?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    }

    /// Слева от панели микшера, по верхнему краю. Если панель не нашлась —
    /// по центру экрана: лучше не там, чем нигде.
    private func position(_ panel: NSPanel, nextTo owner: NSWindow?) {
        guard let owner else {
            panel.center()
            return
        }

        let ownerFrame = owner.frame
        let size = panel.frame.size
        var origin = NSPoint(
            x: ownerFrame.minX - size.width - gap,
            y: ownerFrame.maxY - size.height
        )

        if let visible = (owner.screen ?? NSScreen.main)?.visibleFrame {
            // За левый край экрана не уезжаем: если места слева нет,
            // показываем справа от панели.
            if origin.x < visible.minX {
                origin.x = min(ownerFrame.maxX + gap, visible.maxX - size.width)
            }
            origin.y = max(origin.y, visible.minY + gap)
        }

        panel.setFrameOrigin(origin)
    }
}

// MARK: - Вкладки

extension SettingsPanelController: NSToolbarDelegate {

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    /// Без этого пункты не подсвечиваются как выбранные.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }
}

extension SettingsPanelController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        // Крестик в заголовке — тот же путь, что и кнопка в подвале.
        isVisible = false
    }
}
