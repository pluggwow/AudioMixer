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

    let onVolumeChange: (String, Float) -> Void
    let onToggleMute: (String) -> Void
    let onMove: (Int, Int) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    /// Высота строки до того, как она измерена. Ею же панель считает свою
    /// высоту, поэтому константа живёт здесь одна на оба места.
    static func estimatedRowHeight(compact: Bool) -> CGFloat { compact ? 56 : 72 }

    private static let spacing: CGFloat = 2

    @State private var draggingID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var measuredRowHeight: CGFloat = 0

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

    /// Куда строка встанет, если отпустить прямо сейчас.
    private var targetIndex: Int? {
        guard let from = draggedIndex, step > 0 else { return nil }
        let shift = Int((dragTranslation / step).rounded())
        return min(max(from + shift, 0), apps.count - 1)
    }

    private func offset(at index: Int) -> CGFloat {
        guard let from = draggedIndex, let to = targetIndex else { return 0 }
        if index == from { return dragTranslation }
        // Строки между исходной и целевой позицией расступаются на шаг.
        if from < to, index > from, index <= to { return -step }
        if from > to, index >= to, index < from { return step }
        return 0
    }

    private func dragGesture(for bundleID: String) -> some Gesture {
        // minimumDistance > 0: иначе жест перехватывал бы обычные клики по строке.
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = bundleID
                    onDragBegan()
                }
                guard draggingID == bundleID else { return }
                dragTranslation = value.translation.height
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

        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            if let from, let to, from != to { onMove(from, to) }
            draggingID = nil
            dragTranslation = 0
        }
        onDragEnded()
    }

    private func move(from source: Int, to destination: Int) {
        guard apps.indices.contains(destination) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            onMove(source, destination)
        }
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
