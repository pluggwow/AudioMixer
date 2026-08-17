//
//  EqualizerPanelController.swift
//  AudioMixer
//
//  Окно эквалайзера, привязанное к панели микшера: открывается слева от неё,
//  как и настройки.
//
//  Устройство то же самое и по той же причине — `NonKeyPanel`, окно, которое
//  не становится ключевым никогда. Иначе панель микшера, потеряв фокус,
//  закрылась бы прямо во время кручения полос. Подробности в самом
//  `NonKeyPanel` и в `SettingsPanelController`.
//
//  Окно одно на все приложения: у эквалайзера всегда есть хозяин, и держать
//  по окну на строку — верный способ засорить экран.
//

import AppKit
import SwiftUI

@MainActor
final class EqualizerPanelController: NSObject, ObservableObject {

    static let shared = EqualizerPanelController()

    /// Чьи полосы сейчас показаны. Строка подсвечивается по этому же значению.
    @Published private(set) var bundleID: String?

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    /// Зазор до панели микшера — как у настроек.
    private let gap: CGFloat = 8

    static let contentSize = CGSize(width: 420, height: 320)

    private override init() { super.init() }

    var isVisible: Bool { bundleID != nil }

    /// Нужно панели микшера: клик по этому окну не должен считаться кликом
    /// мимо панели, иначе она закроется вместе с ним.
    var window: NSWindow? { panel }

    func toggle(for bundleID: String, nextTo owner: NSWindow?) {
        if self.bundleID == bundleID {
            close()
        } else {
            show(for: bundleID, nextTo: owner)
        }
    }

    func show(for bundleID: String, nextTo owner: NSWindow?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.bundleID = bundleID

        hosting?.rootView = content(for: bundleID)
        panel.title = title(for: bundleID)
        position(panel, nextTo: owner)
        // Не makeKeyAndOrderFront: ключевым это окно быть не должно.
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        bundleID = nil
    }

    /// Приложение пропало из списка — окно про него больше не имеет смысла.
    func closeIfShowing(bundleID: String) {
        guard self.bundleID == bundleID else { return }
        close()
    }

    // MARK: - Окно

    private func makePanel() -> NSPanel {
        let panel = NonKeyPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        self.hosting = hosting
        panel.contentView = hosting
        panel.delegate = self

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Без анимации: панель микшера появляется мгновенно, и выплывающее
        // рядом окно выглядит чужеродно.
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        return panel
    }

    private func title(for bundleID: String) -> String {
        let name = AppContainer.shared.mixerViewModel.apps
            .first { $0.bundleID == bundleID }?.name
        return name.map { "Эквалайзер — \($0)" } ?? "Эквалайзер"
    }

    private func content(for bundleID: String) -> AnyView {
        AnyView(
            EqualizerView(bundleID: bundleID)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .environmentObject(AppContainer.shared.mixerViewModel)
                .environmentObject(AppContainer.shared.settings)
        )
    }

    /// Слева от панели микшера, по верхнему краю. Если места слева нет —
    /// справа. Панель не нашлась — по центру экрана.
    private func position(_ panel: NSPanel, nextTo owner: NSWindow?) {
        guard let owner else {
            panel.center()
            return
        }

        let ownerFrame = owner.frame
        let size = panel.frame.size
        var origin = NSPoint(x: ownerFrame.minX - size.width - gap,
                             y: ownerFrame.maxY - size.height)

        if let visible = (owner.screen ?? NSScreen.main)?.visibleFrame {
            if origin.x < visible.minX {
                origin.x = min(ownerFrame.maxX + gap, visible.maxX - size.width)
            }
            origin.y = max(origin.y, visible.minY + gap)
        }

        panel.setFrameOrigin(origin)
    }
}

extension EqualizerPanelController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        bundleID = nil
    }
}
