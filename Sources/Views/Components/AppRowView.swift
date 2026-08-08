//
//  AppRowView.swift
//  AudioMixer
//

import SwiftUI

struct AppRowView: View {

    let app: AudioAppState
    let showIcon: Bool
    let showPercentage: Bool
    let sliderStyle: SliderStyleOption
    let compact: Bool

    /// Строку сейчас тащат мышью.
    var isDragged: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    var onTogglePin: () -> Void = {}
    /// Сдвиг на позицию: -1 вверх, +1 вниз.
    var onMove: (Int) -> Void = { _ in }

    @State private var isHovering = false

    private var iconSize: CGFloat { compact ? 26 : 34 }

    var body: some View {
        HStack(spacing: 12) {
            if showIcon {
                iconView
                    .frame(width: iconSize, height: iconSize)
            }

            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: compact ? 12 : 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(app.isMuted ? .secondary : .primary)

                    if app.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Закреплено")
                    }

                    Spacer(minLength: 4)

                    if showPercentage {
                        Text(app.isMuted ? "Выкл." : app.percentText)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }

                VolumeSlider(
                    value: Binding(
                        get: { app.isMuted ? 0 : app.volume },
                        set: { onVolumeChange($0) }
                    ),
                    style: sliderStyle == .thin ? .compact : .prominent,
                    isEnabled: !app.isMuted,
                    accentTint: .accentColor
                )
            }

            Button(action: onToggleMute) {
                Image(systemName: app.speakerSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .foregroundStyle(app.isMuted ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))
            .help(app.isMuted ? "Включить звук" : "Заглушить")
        }
        // Закреплённое, но закрытое приложение — бесцветная строка. Обесцвечивается
        // всё разом, вместе с заливкой слайдера: так сразу видно, что звука за
        // этой строкой сейчас нет, но громкость ей выставить можно.
        .saturation(app.isRunning ? 1 : 0)
        .opacity(app.isRunning ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.2), value: app.isRunning)
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 6 : 8)
        // Без contentShape кликом ловятся только сами иконка, текст и слайдер,
        // а промежутки между ними — нет, и строка отзывается через раз.
        .contentShape(Rectangle())
        // Двойной клик по строке — быстрое «заглушить». Одиночный намеренно
        // ничего не делает: он принадлежит слайдеру и кнопке внутри строки.
        .onTapGesture(count: 2, perform: onToggleMute)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(backgroundOpacity))
                .shadow(color: .black.opacity(isDragged ? 0.22 : 0), radius: 8, y: 3)
        )
        // Приподнятая строка: видно, что именно её сейчас переставляют.
        .scaleEffect(isDragged ? 1.02 : 1, anchor: .center)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: app.isMuted)
        .contextMenu {
            Button("Сбросить на 100%") { onVolumeChange(1.0) }
            Button(app.isMuted ? "Включить звук" : "Заглушить", action: onToggleMute)

            Divider()

            Button(app.isPinned ? "Открепить" : "Закрепить", action: onTogglePin)

            Divider()

            Button("Переместить выше") { onMove(-1) }
                .disabled(!canMoveUp)
            Button("Переместить ниже") { onMove(1) }
                .disabled(!canMoveDown)
        }
    }

    private var backgroundOpacity: Double {
        if isDragged { return 0.12 }
        return isHovering ? 0.06 : 0
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .saturation(app.isMuted ? 0.2 : 1)
                .opacity(app.isMuted ? 0.65 : 1)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                )
        }
    }
}
