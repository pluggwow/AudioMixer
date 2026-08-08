//
//  VolumeSlider.swift
//  AudioMixer
//
//  Слайдер в стиле Control Center. Системный Slider не подходит:
//  нужен капсульный трек с иконкой внутри и клик-в-точку без «прыжка» ручки.
//

import SwiftUI

struct VolumeSlider: View {

    enum Style {
        case prominent   // толстый, с иконкой внутри — для Master
        case compact     // тонкий — для строк приложений

        var height: CGFloat {
            switch self {
            case .prominent: return 28
            case .compact:   return 20
            }
        }
    }

    @Binding var value: Float
    var style: Style = .compact
    var symbolName: String?
    var isEnabled: Bool = true
    var accentTint: Color = .primary
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = style.height
            let fill = max(height, CGFloat(clamped) * width)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                    )

                Capsule(style: .continuous)
                    .fill(fillStyle)
                    .frame(width: fill)
                    .shadow(color: .black.opacity(isDragging ? 0.18 : 0.10), radius: 3, y: 1)

                if let symbolName, style == .prominent {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.55))
                        .blendMode(.plusDarker)
                        .frame(width: height, height: height)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .scaleEffect(y: isDragging ? 1.12 : (isHovering ? 1.05 : 1.0), anchor: .center)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isDragging)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gestureValue in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        update(location: gestureValue.location.x, width: width)
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
        .frame(height: style.height)
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

    private var clamped: Float { max(0, min(value, 1)) }

    private var fillStyle: AnyShapeStyle {
        isEnabled
            ? AnyShapeStyle(accentTint.opacity(0.92))
            : AnyShapeStyle(Color.secondary.opacity(0.4))
    }

    private func update(location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let newValue = Float(max(0, min(location / width, 1)))
        guard abs(newValue - value) > 0.0005 else { return }
        value = newValue
    }
}
