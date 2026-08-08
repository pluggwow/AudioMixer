//
//  MixerRootView.swift
//  AudioMixer
//
//  Главная панель из Menu Bar. Стилистика — Control Center:
//  узкая колонка, крупные скругления, материал вместо плотной заливки.
//

import SwiftUI

struct MixerRootView: View {

    @EnvironmentObject private var viewModel: MixerViewModel
    @EnvironmentObject private var settings: SettingsStore

    @Environment(\.openSettings) private var openSettings

    private let panelWidth: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            MasterVolumeSection(
                systemVolume: viewModel.systemVolume,
                device: viewModel.outputDevice,
                availableDevices: viewModel.availableDevices,
                showPercentage: settings.showVolumePercentage,
                onSelectDevice: { viewModel.selectOutputDevice($0) }
            )

            if shouldShowPermissionBanner {
                PermissionBanner(
                    status: viewModel.permissionStatus,
                    onOpenSettings: { viewModel.openPermissionSettings() },
                    onRecheck: { viewModel.recheckPermissions() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if case .failed(let message) = viewModel.engineState {
                EngineErrorBanner(message: message)
                    .transition(.opacity)
            }

            Divider().opacity(0.5)

            appsSection

            Divider().opacity(0.5)

            footer
        }
        .padding(14)
        .frame(width: panelWidth)
        .background(.ultraThinMaterial)
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.apps)
        .animation(.easeInOut(duration: 0.2), value: viewModel.permissionStatus)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Приложения")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if case .active(let count) = viewModel.engineState, count > 0 {
                    Text("\(count) активн.")
                        .font(.system(size: 12))
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
                            .font(.system(size: 11, weight: .medium))
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
                            compact: settings.compactMode,
                            viewportHeight: scrollHeight,
                            scrollProxy: scrollProxy,
                            onVolumeChange: { bundleID, volume in
                                viewModel.setVolume(volume, for: bundleID)
                            },
                            onToggleMute: { viewModel.toggleMute(for: $0) },
                            onTogglePin: { viewModel.togglePin(for: $0) },
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
        let rowHeight = AppListView.estimatedRowHeight(compact: settings.compactMode)
        let count = CGFloat(viewModel.apps.count)
        // Потолок ~6 строк: дальше панель становится выше экрана.
        return min(count * rowHeight, rowHeight * 6)
    }

    // MARK: - Подвал

    /// Одного openSettings() мало. Приложение работает как menu bar extra
    /// (activationPolicy = .accessory), а такое приложение не выводит своё окно
    /// на передний план само: окно настроек открывается позади всех остальных,
    /// и со стороны это выглядит как «кнопка не работает».
    private func openSettingsWindow() {
        openSettings()
        NSApp.activate()

        // Окно создаётся асинхронно, поэтому поднимаем его на следующем витке
        // цикла событий. orderFrontRegardless нужен потому, что у .accessory
        // приложения makeKeyAndOrderFront срабатывает не всегда.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.frameAutosaveName == "com_apple_SwiftUI_Settings_window"
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: openSettingsWindow) {
                Label("Настройки", systemImage: "gearshape")
                    .font(.system(size: 13))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer()

            Button {
                viewModel.shutdown()
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Завершить AudioMixer")
        }
        .foregroundStyle(.secondary)
    }
}
