//
//  AppRowView.swift
//  AudioMixer
//
//  Строка приложения в одну линию: иконка, название, слайдер, проценты, mute.
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

    /// Высота строки задаётся, а не выводится из содержимого: по ней панель
    /// считает свой размер, а перетаскивание — шаг сетки.
    static func height(compact: Bool) -> CGFloat { compact ? 28 : 36 }

    private var iconSize: CGFloat { compact ? 18 : 22 }
    /// Фиксирован слайдер, а не название: тогда слайдеры соседних строк стоят
    /// по одной вертикали (всё, что правее названия, одной ширины), а имени
    /// достаётся вся оставшаяся строка — длинные названия не режутся зря.
    private var sliderWidth: CGFloat { compact ? 104 : 112 }
    private var percentWidth: CGFloat { compact ? 30 : 32 }
    private var muteSize: CGFloat { compact ? 16 : 18 }
    private var spacing: CGFloat { compact ? 6 : 7 }

    var body: some View {
        HStack(spacing: spacing) {
            if showIcon {
                iconView
                    .frame(width: iconSize, height: iconSize)
            }

            HStack(spacing: 3) {
                Text(app.name)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(app.isSilent ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if app.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VolumeSlider(
                value: Binding(
                    get: { app.isMuted ? 0 : app.volume },
                    set: { onVolumeChange($0) }
                ),
                style: sliderStyle == .thin ? .systemSmall : .system,
                // Выключаем слайдер только на mute. На нуле он обязан
                // остаться живым — иначе громкость неоткуда поднять.
                isEnabled: !app.isMuted,
                // Серый и на нуле, и у закрытого закреплённого приложения.
                // Цвет задаётся явно, а не оставляется на .saturation строки:
                // фильтр насыщенности до заливки слайдера доходит не всегда,
                // и цветная полоска выбивалась из приглушённой строки.
                accentTint: (app.isSilent || !app.isRunning) ? .secondary : .accentColor
            )
            .frame(width: sliderWidth)

            if showPercentage {
                Text(app.isMuted ? "Выкл." : app.percentText)
                    .font(.system(size: compact ? 10 : 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .frame(width: percentWidth, alignment: .trailing)
            }

            Button(action: onToggleMute) {
                Image(systemName: app.speakerSymbol)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(app.isSilent ? Color.secondary : Color.primary)
                    .frame(width: muteSize, height: muteSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))
            .help(app.isMuted ? "Включить звук" : "Заглушить")
        }
        // Закреплённое, но закрытое приложение — бесцветная строка.
        // Обесцвечивается всё разом, вместе с заливкой слайдера: так сразу
        // видно, что звука за этой строкой сейчас нет, но громкость выставить
        // можно.
        .saturation(app.isRunning ? 1 : 0)
        .opacity(app.isRunning ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.2), value: app.isRunning)
        .padding(.horizontal, 6)
        .frame(height: Self.height(compact: compact))
        // Без contentShape кликом ловятся только сами иконка, текст и слайдер,
        // а промежутки между ними — нет, и строка отзывается через раз.
        .contentShape(Rectangle())
        // Двойной клик по строке — быстрое «заглушить». Одиночный намеренно
        // ничего не делает: он принадлежит слайдеру и кнопке внутри строки.
        .onTapGesture(count: 2, perform: onToggleMute)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(backgroundOpacity))
                .shadow(color: .black.opacity(isDragged ? 0.22 : 0), radius: 8, y: 3)
        )
        // Приподнятая строка: видно, что именно её сейчас переставляют.
        .scaleEffect(isDragged ? 1.02 : 1, anchor: .center)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: app.isSilent)
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
                .saturation(app.isSilent ? 0.2 : 1)
                .opacity(app.isSilent ? 0.65 : 1)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                )
        }
    }
}
