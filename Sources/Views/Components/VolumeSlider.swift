//
//  VolumeSlider.swift
//  AudioMixer
//
//  Слайдер как в Control Center: тонкий капсульный трек, залитая часть
//  акцентным цветом и круглая белая ручка. Системный Slider не подходит —
//  у него другая метрика и обязательный «прыжок» ручки к курсору.
//

import SwiftUI

struct VolumeSlider: View {

    enum Style {
        /// Мастер-громкость: крупная ручка, как в системной панели «Звук».
        case system
        /// Строка приложения: та же геометрия, но мельче.
        case systemSmall

        var trackHeight: CGFloat { self == .system ? 6 : 4 }
        var knobSize: CGFloat { self == .system ? 18 : 13 }
    }

    @Binding var value: Float
    var style: Style = .system
    var isEnabled: Bool = true
    var accentTint: Color = .accentColor
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false
    @State private var isHovering = false

    /// Высота всей области — по ручке: она крупнее трека и определяет габарит.
    private var height: CGFloat { max(style.knobSize, style.trackHeight) }

    var body: some View {
        GeometryReader { geometry in
            // Ручка не должна вылезать за края трека, поэтому ход её центра
            // короче ширины на диаметр — как у системного слайдера.
            let travel = max(geometry.size.width - style.knobSize, 1)
            let center = style.knobSize / 2 + CGFloat(clamped) * travel

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                    .frame(height: style.trackHeight)

                Capsule(style: .continuous)
                    .fill(fillStyle)
                    .frame(width: center, height: style.trackHeight)

                knob
                    .offset(x: center - style.knobSize / 2)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        update(location: gesture.location.x, travel: travel)
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
            .onHover { isHovering = $0 && isEnabled }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .frame(height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(clamped * 100)) процентов"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }

    private var knob: some View {
        Circle()
            .fill(.white)
            // Обводка нужна на светлой теме: белая ручка на светлом треке
            // иначе теряет край.
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .frame(width: style.knobSize, height: style.knobSize)
            .scaleEffect(isDragging ? 1.12 : (isHovering ? 1.05 : 1))
    }

    private var clamped: Float { max(0, min(value, 1)) }

    private var fillStyle: AnyShapeStyle {
        isEnabled
            ? AnyShapeStyle(accentTint)
            : AnyShapeStyle(Color.secondary.opacity(0.4))
    }

    private func update(location: CGFloat, travel: CGFloat) {
        // Курсор задаёт положение центра ручки, а не левого края заливки.
        let newValue = Float(max(0, min((location - style.knobSize / 2) / travel, 1)))
        guard abs(newValue - value) > 0.0005 else { return }
        value = newValue
    }
}
