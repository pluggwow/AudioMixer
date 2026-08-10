//
//  VolumeSlider.swift
//  AudioMixer
//
//  Слайдер как в Control Center: тонкий капсульный трек, белая залитая часть
//  и круглая ручка. Системный Slider не подходит — у него другая метрика и
//  обязательный «прыжок» ручки к курсору.
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
    /// Цвет залитой части. nil — «как система»: белая на тёмной теме и тёмная
    /// на светлой. Чистая белая на светлой теме сливается с треком, и понять,
    /// где кончается заполнение, можно только по ручке.
    var accentTint: Color?
    /// Что показать в подсказке над курсором. nil — подсказки нет.
    var hoverLabel: String?
    var onEditingChanged: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    @State private var isDragging = false
    @State private var isHovering = false
    /// Где именно курсор внутри слайдера — подсказка встаёт над этой точкой.
    @State private var hoverX: CGFloat?

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
                    // Обводка нужна на светлой теме: белая заливка на светлом
                    // треке иначе сливается с ним.
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                    )
                    .frame(width: center, height: style.trackHeight)

                knob
                    .offset(x: center - style.knobSize / 2)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            // Подсказку рисует не слайдер, а панель: изнутри списка она
            // упиралась бы в край прокручиваемой области и обрезалась —
            // ровно это и происходило у самой верхней строки.
            .anchorPreference(key: HoverTipKey.self,
                              value: .point(CGPoint(x: center, y: 0))) { anchor in
                guard let hoverLabel, isEnabled, showsTip(knobCenter: center) else { return nil }
                return HoverTip(text: hoverLabel, anchor: anchor)
            }
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
            // Обычный onHover даёт только «внутри/снаружи», а подсказке нужна
            // точка: она встаёт над курсором, а не над серединой слайдера.
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
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
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .frame(width: style.knobSize, height: style.knobSize)
            .scaleEffect(isDragging ? 1.12 : (isHovering ? 1.05 : 1))
    }

    /// Подсказка нужна, только когда курсор на самой ручке, а не где-то по
    /// треку. Во время перетаскивания — всегда: курсор к тому моменту может
    /// уехать за пределы слайдера, а число должно оставаться видимым.
    private func showsTip(knobCenter: CGFloat) -> Bool {
        if isDragging { return true }
        guard let hoverX else { return false }
        // Небольшой допуск: целиться пиксель в пиксель по 13-точечному
        // кружку — занятие на любителя.
        return abs(hoverX - knobCenter) <= style.knobSize / 2 + 3
    }

    private var clamped: Float { max(0, min(value, 1)) }

    private var fillStyle: AnyShapeStyle {
        isEnabled
            ? AnyShapeStyle(resolvedTint)
            : AnyShapeStyle(Color.secondary.opacity(0.4))
    }

    private var resolvedTint: Color {
        if let accentTint { return accentTint }
        return colorScheme == .dark ? .white : Color.primary.opacity(0.75)
    }

    private func update(location: CGFloat, travel: CGFloat) {
        // Курсор задаёт положение центра ручки, а не левого края заливки.
        let newValue = Float(max(0, min((location - style.knobSize / 2) / travel, 1)))
        guard abs(newValue - value) > 0.0005 else { return }
        value = newValue
    }
}


// MARK: - Всплывающая подсказка

/// Что и где показать всплывающей подсказкой: проценты над ручкой слайдера
/// или полное название приложения, которое не поместилось в строку.
///
/// Через preference, а не через оверлей на месте: подсказка должна рисоваться
/// поверх всей панели. Внутри списка её обрезает ScrollView, а внутри строки —
/// не хватает высоты.
struct HoverTip: Equatable {
    let text: String
    let anchor: Anchor<CGPoint>
}

struct HoverTipKey: PreferenceKey {
    static let defaultValue: HoverTip? = nil
    static func reduce(value: inout HoverTip?, nextValue: () -> HoverTip?) {
        value = nextValue() ?? value
    }
}

struct HoverTipBubble: View {
    let text: String

    static let fontSize: CGFloat = 10
    private static let horizontalPadding: CGFloat = 5

    /// Ширина окошка, посчитанная по тексту.
    ///
    /// Нужна, чтобы прижать подсказку к краю панели по-настоящему: ограничить
    /// один только центр мало — у длинного названия половина окошка всё равно
    /// уезжала за край и обрезалась.
    static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let text = (text as NSString).size(withAttributes: [.font: font]).width
        return text.rounded(.up) + horizontalPadding * 2
    }

    var body: some View {
        Text(text)
            .font(.system(size: Self.fontSize, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.thickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}
