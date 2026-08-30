//
//  MixerPanelController.swift
//  AudioMixer
//
//  Значок в строке меню и окно панели — свои, а не от MenuBarExtra(.window).
//
//  Причина конкретная. Окно MenuBarExtra приносит собственную системную
//  подложку, и она затягивает в себя содержимое из-за верхней кромки. Прямо
//  над кромкой лежит менюбар, поэтому в верхней части панели проступали
//  призраки его значков — смещённая вправо-вниз копия строки меню. Своим
//  слоем это не лечится: мы рисуем ПОВЕРХ подложки, и всё, что можно было
//  сделать, — замазать призраков плотной полосой. Проверено, выглядит хуже
//  самих призраков.
//
//  В своём окне подложка одна и наша: NSVisualEffectView с .behindWindow.
//  Замер показал, что призраков у него нет ни при каком материале.
//
//  Побочно уходит вторая давняя странность: раньше наше стекло ложилось
//  вторым слоем на системное, и «прозрачность» приходилось выкручивать
//  через .opacity поверх материала.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MixerPanelController: NSObject, ObservableObject {

    static let shared = MixerPanelController()

    @Published private(set) var isVisible = false

    /// Окно панели. Нужно наружу: настройки открываются слева от него.
    private(set) var window: NSPanel?

    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    /// Зазор между менюбаром и панелью — как у системных панелей.
    private let gap: CGFloat = 8

    private override init() { super.init() }

    // MARK: - Значок в строке меню

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        updateIcon()

        // Значок повторяет уровень громкости, а он живёт во вложенном объекте:
        // подписки на сам контейнер для этого мало.
        AppContainer.shared.mixerViewModel.systemVolume.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let symbol = AppContainer.shared.mixerViewModel.systemVolume.symbolName
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudioMixer")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func statusItemClicked() {
        toggle()
    }

    // MARK: - Показ и скрытие

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        let panel = window ?? makePanel()
        window = panel

        reposition()
        // orderFrontRegardless, а не makeKeyAndOrderFront: ключевым это окно
        // не становится принципиально, см. NonKeyPanel.
        // makeKeyAndOrderFront, а не orderFrontRegardless: безрамочное окно
        // по умолчанию ключевым стать не может, и тогда КАЖДЫЙ клик по нему
        // AppKit считает «первым» — тем, что окно только активирует. Такой
        // клик до содержимого не доходит: слайдеры и кнопки не отзываются.
        // Приложение при этом на передний план не выходит: .nonactivatingPanel.
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        startMonitoring()
    }

    func close() {
        window?.orderOut(nil)
        isVisible = false
        stopMonitoring()
    }

    // MARK: - Окно

    private func makePanel() -> NSPanel {
        let panel = MixerPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 300, height: 200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Выше обычных окон, вровень с окном настроек.
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Панель менюбара появляется мгновенно; выплывающая выглядит чужеродно.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Размер окна ведёт содержимое: .preferredContentSize заставляет
        // хостинг-контроллер сообщать свой естественный размер, а AppKit —
        // подгонять под него окно. Ручной замер через GeometryReader сюда не
        // дошёл: у прижатого к окну хостинга SwiftUI меряет само окно, и
        // размер получался круговой ссылкой на себя же.
        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting

        // Окно меняет высоту, когда в списке прибавляется строка. Держим его
        // прижатым к менюбару: иначе оно росло бы вниз от нижнего края.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResize),
            name: NSWindow.didResizeNotification,
            object: panel
        )

        return panel
    }

    @objc private func panelDidResize() { reposition() }

    private func content() -> AnyView {
        let container = AppContainer.shared
        return AnyView(
            MixerRootView()
                .environmentObject(container.mixerViewModel)
                .environmentObject(container.settings)
        )
    }

    /// Под значком в менюбаре, по его центру, не выходя за края экрана.
    private func reposition() {
        guard let window,
              let button = statusItem?.button,
              let buttonWindow = button.window
        else { return }

        let size = window.frame.size
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonFrame.midX - size.width / 2,
                             y: buttonFrame.minY - gap - size.height)

        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }

        // setFrameOrigin, а не setFrame: размер здесь чужой, его ведёт
        // содержимое, и трогать его отсюда — гонка с ним же.
        window.setFrameOrigin(origin)
    }

    // MARK: - Закрытие по клику мимо

    /// Системная панель закрывается сама, когда теряет фокус. Наша фокус не
    /// берёт вовсе, поэтому за кликами мимо следим руками: чужое приложение —
    /// глобальный монитор, свои окна — локальный.
    private func startMonitoring() {
        guard monitors.isEmpty else { return }

        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        ) {
            monitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                guard let self else { return event }
                if !self.isOurWindow(event.window) { self.close() }
                return event
            }
        ) {
            monitors.append(local)
        }
    }

    private func stopMonitoring() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// Клики по самой панели, по значку в менюбаре и по окнам-спутникам панель
    /// не закрывают — иначе ни настройки, ни эквалайзер было бы не потрогать:
    /// они открыты рядом, но окна отдельные, и без этой проверки первый же
    /// клик по ним закрывает панель, а вместе с ней и их самих.
    private func isOurWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        if candidate === window { return true }
        if candidate === statusItem?.button?.window { return true }
        if candidate === SettingsPanelController.shared.window { return true }
        if candidate === EqualizerPanelController.shared.window { return true }
        return false
    }
}

/// Окно панели.
///
/// Ключевым быть обязано — иначе клики по содержимому съедаются как «первые»
/// (см. show()). Окно настроек, наоборот, ключевым не становится никогда: так
/// панель не закрывается, пока в настройках что-то нажимают.
private final class MixerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
