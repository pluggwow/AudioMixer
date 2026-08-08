//
//  AppListView.swift
//  AudioMixer
//
//  Список приложений с перетаскиванием строк мышью.
//
//  Сделано обычным DragGesture, а не .draggable/.dropDestination: системный
//  drag'n'drop поднимает сессию перетаскивания через пастборд и завязан на
//  фокус окна, а панель MenuBarExtra — неактивирующееся окно, которое
//  закрывается, стоит ему фокус потерять. Внутренний жест за пределы окна
//  не выходит и от фокуса не зависит.
//

import SwiftUI

struct AppListView: View {

    let apps: [AudioAppState]
    let showIcons: Bool
    let showPercentage: Bool
    let sliderStyle: SliderStyleOption
    let compact: Bool

    /// Высота видимой области списка — по ней определяются краевые зоны автопрокрутки.
    let viewportHeight: CGFloat
    let scrollProxy: ScrollViewProxy

    let onVolumeChange: (String, Float) -> Void
    let onToggleMute: (String) -> Void
    let onTogglePin: (String) -> Void
    let onMove: (Int, Int) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    /// Высота строки до того, как она измерена. Ею же панель считает свою
    /// высоту, поэтому константа живёт здесь одна на оба места.
    static func estimatedRowHeight(compact: Bool) -> CGFloat { compact ? 56 : 72 }

    /// Система координат видимой области. Задаётся снаружи, на ScrollView:
    /// позиция курсора нужна относительно окна списка, а не относительно
    /// содержимого, которое во время автопрокрутки едет само.
    static let viewportSpace = "mixerAppListViewport"

    private static let spacing: CGFloat = 2
    /// Ширина краевой полосы, в которой начинается автопрокрутка.
    private static let autoScrollEdge: CGFloat = 26
    private static let autoScrollTick: Duration = .milliseconds(130)

    @State private var draggingID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var measuredRowHeight: CGFloat = 0

    /// На сколько строк список уехал автопрокруткой за текущее перетаскивание.
    @State private var autoScrollShift: Int = 0
    @State private var autoScrollDirection: Int = 0
    @State private var autoScrollTask: Task<Void, Never>?

    var body: some View {
        LazyVStack(spacing: Self.spacing) {
            ForEach(Array(apps.enumerated()), id: \.element.bundleID) { index, app in
                row(app, at: index)
            }
        }
        .onPreferenceChange(RowHeightKey.self) { height in
            guard height > 0 else { return }
            measuredRowHeight = height
        }
        .onDisappear { stopAutoScroll() }
    }

    @ViewBuilder
    private func row(_ app: AudioAppState, at index: Int) -> some View {
        let isDragged = app.bundleID == draggingID

        AppRowView(
            app: app,
            showIcon: showIcons,
            showPercentage: showPercentage,
            sliderStyle: sliderStyle,
            compact: compact,
            isDragged: isDragged,
            canMoveUp: index > 0,
            canMoveDown: index < apps.count - 1,
            onVolumeChange: { onVolumeChange(app.bundleID, $0) },
            onToggleMute: { onToggleMute(app.bundleID) },
            onTogglePin: { onTogglePin(app.bundleID) },
            onMove: { delta in move(from: index, to: index + delta) }
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
            }
        )
        .offset(y: offset(at: index))
        .zIndex(isDragged ? 1 : 0)
        // .subviews при одной строке: переставлять нечего, но слайдер внутри
        // должен продолжать работать — .none выключил бы и его.
        .gesture(dragGesture(for: app.bundleID), including: apps.count > 1 ? .all : .subviews)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        ))
    }

    // MARK: - Перетаскивание

    /// Шаг сетки: на столько сдвигается соседняя строка, уступая место.
    private var step: CGFloat {
        let height = measuredRowHeight > 0
            ? measuredRowHeight
            : Self.estimatedRowHeight(compact: compact)
        return height + Self.spacing
    }

    private var draggedIndex: Int? {
        guard let draggingID else { return nil }
        return apps.firstIndex { $0.bundleID == draggingID }
    }

    /// Смещение строки от её места в списке. Автопрокрутка входит сюда наравне
    /// с движением мыши: содержимое уехало на строку — значит, чтобы остаться
    /// под курсором, строка должна сместиться на столько же.
    private var draggedVisualOffset: CGFloat {
        dragTranslation + CGFloat(autoScrollShift) * step
    }

    /// Куда строка встанет, если отпустить прямо сейчас.
    private var targetIndex: Int? {
        guard let from = draggedIndex, step > 0 else { return nil }
        let shift = Int((draggedVisualOffset / step).rounded())
        return min(max(from + shift, 0), apps.count - 1)
    }

    private func offset(at index: Int) -> CGFloat {
        guard let from = draggedIndex, let to = targetIndex else { return 0 }
        if index == from { return draggedVisualOffset }
        // Строки между исходной и целевой позицией расступаются на шаг.
        if from < to, index > from, index <= to { return -step }
        if from > to, index >= to, index < from { return step }
        return 0
    }

    private func dragGesture(for bundleID: String) -> some Gesture {
        // minimumDistance > 0: иначе жест перехватывал бы обычные клики по строке.
        // Координаты видимой области, а не строки: по ним видно приближение к краю.
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.viewportSpace))
            .onChanged { value in
                if draggingID == nil {
                    draggingID = bundleID
                    autoScrollShift = 0
                    onDragBegan()
                }
                guard draggingID == bundleID else { return }
                dragTranslation = value.translation.height
                updateAutoScroll(pointerY: value.location.y)
            }
            .onEnded { _ in
                guard draggingID == bundleID else { return }
                commitDrag()
            }
    }

    private func commitDrag() {
        // Порядок важен: индексы считаются по старому списку, до перестановки.
        let from = draggedIndex
        let to = targetIndex
        stopAutoScroll()

        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            if let from, let to, from != to { onMove(from, to) }
            draggingID = nil
            dragTranslation = 0
            autoScrollShift = 0
        }
        onDragEnded()
    }

    private func move(from source: Int, to destination: Int) {
        guard apps.indices.contains(destination) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            onMove(source, destination)
        }
    }

    // MARK: - Автопрокрутка у краёв

    /// Список короче окна — прокручивать нечего.
    private var contentOverflows: Bool {
        CGFloat(apps.count) * step > viewportHeight + 1
    }

    private func updateAutoScroll(pointerY: CGFloat) {
        guard contentOverflows else { return }

        let direction: Int
        if pointerY < Self.autoScrollEdge {
            direction = -1
        } else if pointerY > viewportHeight - Self.autoScrollEdge {
            direction = 1
        } else {
            direction = 0
        }

        guard direction != autoScrollDirection else { return }
        autoScrollDirection = direction
        if direction == 0 {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in
            // Направление читается на каждом витке: курсор мог переехать
            // от верхнего края к нижнему, не отпуская кнопку.
            // Упёрлись в конец списка — не выходим, а ждём: пользователь может
            // потянуть обратно, не покидая краевую зону, и прокрутка снова
            // станет возможна. Выход — только по уходу курсора от края.
            while !Task.isCancelled, autoScrollDirection != 0 {
                _ = scrollOneRow(autoScrollDirection)
                try? await Task.sleep(for: Self.autoScrollTick)
            }
            autoScrollTask = nil
        }
    }

    /// Прокрутить на строку в заданную сторону. `false` — дальше некуда.
    private func scrollOneRow(_ direction: Int) -> Bool {
        guard let current = targetIndex else { return false }
        let next = current + direction
        guard apps.indices.contains(next) else { return false }

        autoScrollShift += direction
        withAnimation(.linear(duration: 0.12)) {
            scrollProxy.scrollTo(apps[next].bundleID, anchor: direction < 0 ? .top : .bottom)
        }
        return true
    }

    private func stopAutoScroll() {
        autoScrollDirection = 0
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }
}

/// Реальная высота строки: она зависит от компактного режима, иконок и
/// системного размера шрифта, а перетаскиванию нужен точный шаг сетки.
private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
