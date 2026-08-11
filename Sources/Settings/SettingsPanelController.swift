//
//  SettingsPanelController.swift
//  AudioMixer
//
//  Окно настроек, привязанное к панели микшера: открывается слева от неё.
//
//  Обычное окно (сцена Settings) не годится: оно забирает фокус, а панель
//  менюбара система закрывает, как только фокус уходит. Настраивать
//  приходилось вслепую. Поэтому окно здесь своё — NSPanel, который
//  принципиально не становится ключевым:
//
//    .nonactivatingPanel      — клик по нему не активирует приложение;
//    becomesKeyOnlyIfNeeded   — фокус берётся только если он нужен контролу,
//                               а у нас их таких нет: тумблеры, слайдеры и
//                               меню работают и без фокуса.
//
//  Поэтому панель микшера фокус не теряет и остаётся на экране.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsPanelController: NSObject, ObservableObject {

    static let shared = SettingsPanelController()

    @Published private(set) var isVisible = false

    private var panel: NSPanel?

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
        let container = AppContainer.shared
        let root = SettingsView()
            .environmentObject(container.mixerViewModel)
            .environmentObject(container.settings)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: SettingsView.height),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Настройки"
        panel.contentView = NSHostingView(rootView: root)
        panel.delegate = self

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Без анимации появления: панель менюбара возникает мгновенно, и
        // выплывающее рядом окно рядом с ней выглядит чужеродно.
        panel.animationBehavior = .none
        // На уровне всплывающих панелей: ниже — и окно уедет под панель микшера.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        return panel
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

extension SettingsPanelController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        // Крестик в заголовке — тот же путь, что и кнопка в подвале.
        isVisible = false
    }
}
