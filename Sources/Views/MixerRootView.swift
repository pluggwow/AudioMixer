//
//  MixerRootView.swift
//  AudioMixer
//
//  Главная панель из Menu Bar, собранная по образцу системной панели «Звук»
//  из Control Center: заголовок, один слайдер, список приложений. Материал
//  вместо плотной заливки, системная типографика, разделители между секциями.
//
//  Панель намеренно только компактная: устройство вывода — кнопкой в строке
//  слайдера, а не отдельной секцией. Секция «Выход» занимала полсотни точек
//  высоты ради одной строки, которую всё равно видно по значку.
//

import SwiftUI

struct MixerRootView: View {

    @EnvironmentObject private var viewModel: MixerViewModel
    @EnvironmentObject private var settings: SettingsStore

    /// Размеры считаются от настроек: ширина панели, высота строки и наличие
    /// кнопки вывода настраиваются, а название с слайдером делят остаток.
    private var metrics: RowMetrics { settings.rowMetrics }
    private var panelWidth: CGFloat { metrics.panelWidth }
    private var sidePadding: CGFloat { metrics.panelPadding }

    /// Окно настроек — отдельное, но привязанное к панели: открывается слева
    /// от неё и не забирает фокус, поэтому панель остаётся на экране.
    @ObservedObject private var settingsPanel = SettingsPanelController.shared

    var body: some View {
        mixer
        .background(settings.panelMaterial.shapeStyle)
        // Подсказка со значением рисуется здесь, поверх всего: внутри списка
        // её обрезал бы ScrollView, а внутри строки не хватает высоты.
        .overlayPreferenceValue(HoverTipKey.self) { tip in
            GeometryReader { proxy in
                if let tip {
                    let point = proxy[tip.anchor]
                    // Ширина окошка считается по тексту, и прижимаем мы именно
                    // его края: ограничивать один центр мало — у длинного
                    // названия половина окошка всё равно уезжала за край.
                    let inset: CGFloat = 8
                    let maxWidth = panelWidth - inset * 2
                    let width = min(HoverTipBubble.width(of: tip.text), maxWidth)
                    let x = min(max(point.x, width / 2 + inset),
                                panelWidth - width / 2 - inset)

                    HoverTipBubble(text: tip.text)
                        .frame(maxWidth: maxWidth)
                        .position(x: x, y: point.y - 12)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.apps)
        .animation(.easeInOut(duration: 0.2), value: viewModel.permissionStatus)
    }

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 0) {

            MasterVolumeSection(
                systemVolume: viewModel.systemVolume,
                device: viewModel.outputDevice,
                availableDevices: viewModel.availableDevices,
                onSelectDevice: { viewModel.selectOutputDevice($0) }
            )
            .padding(.horizontal, sidePadding)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if shouldShowPermissionBanner {
                PermissionBanner(
                    status: viewModel.permissionStatus,
                    onOpenSettings: { viewModel.openPermissionSettings() },
                    onRecheck: { viewModel.recheckPermissions() }
                )
                .padding(.horizontal, sidePadding)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if case .failed(let message) = viewModel.engineState {
                EngineErrorBanner(message: message)
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            separator

            appsSection
                .padding(.horizontal, sidePadding)
                .padding(.top, 8)
                .padding(.bottom, 6)

            separator

            footer
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 8)
        }
        .frame(width: panelWidth)
    }

    /// Разделитель с отступами от краёв — как между блоками Control Center.
    private var separator: some View {
        Divider()
            .padding(.horizontal, sidePadding)
    }

    private var shouldShowPermissionBanner: Bool {
        switch viewModel.permissionStatus {
        case .granted: return false
        case .unknown: return false
        default: return true
        }
    }

    // MARK: - Список приложений

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Приложения")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if case .active(let count) = viewModel.engineState, count > 0 {
                    Text("\(count) активн.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                // Кнопка появляется только когда порядок задан вручную —
                // иначе непонятно, что именно она сбрасывает.
                if viewModel.hasCustomOrder {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            viewModel.resetOrder()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .medium))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Вернуть автоматический порядок")
                    .transition(.opacity)
                }
            }

            if viewModel.apps.isEmpty {
                EmptyAppsView()
            } else {
                // ScrollViewReader снаружи ScrollView: изнутри прокси не достать,
                // а он нужен списку для автопрокрутки, когда строку тащат к краю.
                ScrollViewReader { scrollProxy in
                    // Индикатор включён намеренно: без него не видно, что под
                    // видимыми строками есть ещё приложения.
                    ScrollView(.vertical, showsIndicators: true) {
                        AppListView(
                            apps: viewModel.apps,
                            showIcons: settings.showAppIcons,
                            showPercentage: settings.showVolumePercentage,
                            sliderStyle: settings.sliderStyle,
                            availableDevices: viewModel.availableDevices,
                            metrics: metrics,
                            viewportHeight: scrollHeight,
                            scrollProxy: scrollProxy,
                            onVolumeChange: { bundleID, volume in
                                viewModel.setVolume(volume, for: bundleID)
                            },
                            onToggleMute: { viewModel.toggleMute(for: $0) },
                            onTogglePin: { viewModel.togglePin(for: $0) },
                            onSelectOutput: { bundleID, uid in
                                viewModel.setOutputDevice(uid, for: bundleID)
                            },
                            onMove: { source, destination in
                                viewModel.moveApp(from: source, to: destination)
                            },
                            onDragBegan: { viewModel.beginReordering() },
                            onDragEnded: { viewModel.endReordering() }
                        )
                    }
                    // Именно height, а не maxHeight: maxHeight задаёт лишь верхнюю
                    // границу, определённой высоты у ScrollView нет, и в окне,
                    // которое подгоняется под содержимое, он схлопывается в ноль —
                    // строки есть, но места им не отводится.
                    .frame(height: scrollHeight)
                    // Курсор во время перетаскивания меряется относительно этой
                    // области: содержимое при автопрокрутке едет само.
                    .coordinateSpace(name: AppListView.viewportSpace)
                }
            }
        }
    }

    private var scrollHeight: CGFloat {
        let step = metrics.rowHeight + AppListView.rowSpacing
        let visible = min(CGFloat(viewModel.apps.count), settings.visibleRows.count)
        guard visible > 0 else { return 0 }
        return visible * step - AppListView.rowSpacing
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Настройки", isActive: settingsPanel.isVisible) {
                // Ключевое окно в этот момент — сама панель микшера: по ней
                // и позиционируем настройки.
                settingsPanel.toggle(nextTo: NSApp.keyWindow)
            }

            Spacer()

            Button {
                viewModel.shutdown()
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Завершить AudioMixer")
        }
    }
}

/// Строка-ссылка внизу панели — как «Настройки звука…» в системной.
private struct FooterButton: View {

    let title: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.primary.opacity(isActive || isHovering ? 0.07 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
