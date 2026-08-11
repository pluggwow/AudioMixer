//
//  AppRowView.swift
//  AudioMixer
//
//  Строка приложения в одну линию: иконка, название, слайдер, mute, выход.
//  Проценты живут в подсказке над курсором, в самой строке их нет.
//

import SwiftUI

struct AppRowView: View {

    let app: AudioAppState
    let showIcon: Bool
    let showPercentage: Bool
    let sliderStyle: SliderStyleOption
    /// Для выбора устройства прямо в строке.
    var availableDevices: [AudioDeviceInfo] = []
    /// Размеры под текущие настройки.
    var metrics: RowMetrics
    /// Строку сейчас тащат мышью.
    var isDragged: Bool = false

    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    var onTogglePin: () -> Void = {}
    /// nil — вернуть приложение на системное устройство.
    var onSelectOutput: (String?) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isNameHovering = false

    private var iconSize: CGFloat { metrics.icon }
    private var muteSize: CGFloat { metrics.button }
    private var outputSize: CGFloat { metrics.button }
    private var spacing: CGFloat { metrics.spacing }

    /// Имя не поместилось в отведённую колонку и обрезано многоточием.
    private var isNameTruncated: Bool {
        RowMetrics.width(of: app, includingPin: app.isPinned) > metrics.nameWidth
    }

    /// Устройство, в которое уведено приложение. nil — звучит как все.
    private var routedDevice: AudioDeviceInfo? {
        guard let uid = app.outputDeviceUID else { return nil }
        return availableDevices.first { $0.uid == uid }
    }

    private var isRouted: Bool { app.outputDeviceUID != nil }

    var body: some View {
        HStack(spacing: spacing) {
            if showIcon {
                iconView
                    .frame(width: iconSize, height: iconSize)
            }

            HStack(spacing: 3) {
                Text(app.name)
                    .font(RowMetrics.swiftUIFont)
                    .foregroundStyle(app.isSilent ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if app.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .frame(width: metrics.nameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                isNameHovering = hovering
            }
            // Имя, которому не хватило колонки, показывается целиком
            // подсказкой — той же, что и проценты у ручки слайдера.
            .anchorPreference(key: HoverTipKey.self, value: .top) { anchor in
                guard isNameHovering, isNameTruncated else { return nil }
                return HoverTip(text: app.name, anchor: anchor)
            }

            VolumeSlider(
                value: Binding(
                    get: { app.isMuted ? 0 : app.volume },
                    set: { onVolumeChange($0) }
                ),
                style: sliderStyle == .thin ? .systemSmall : .system,
                // Слайдер живой всегда, в том числе на mute: взять его и
                // выставить громкость — самый естественный способ включить
                // звук обратно, и setVolume как раз снимает mute при движении
                // вверх. Выключенный слайдер вынуждал бы сначала жать динамик.
                isEnabled: true,
                // Серый и на нуле, и у закрытого закреплённого приложения.
                // Цвет задаётся явно, а не оставляется на .saturation строки:
                // фильтр насыщенности до заливки слайдера доходит не всегда,
                // и цветная полоска выбивалась из приглушённой строки.
                accentTint: (app.isSilent || !app.isRunning) ? .secondary : nil,
                hoverLabel: showPercentage ? (app.isMuted ? "Выкл." : app.percentText) : nil
            )
            .frame(width: metrics.sliderWidth)

            Button(action: onToggleMute) {
                Image(systemName: app.speakerSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(app.isSilent ? Color.secondary : Color.primary)
                    .frame(width: muteSize, height: muteSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))
            .help(app.isMuted ? "Включить звук" : "Заглушить")

            if metrics.showsOutputButton { outputButton }
        }
        // Закреплённое, но закрытое приложение — бесцветная строка.
        // Обесцвечивается всё разом, вместе с заливкой слайдера: так сразу
        // видно, что звука за этой строкой сейчас нет, но громкость выставить
        // можно.
        .saturation(app.isRunning ? 1 : 0)
        .opacity(app.isRunning ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.2), value: app.isRunning)
        .padding(.horizontal, 6)
        .frame(height: metrics.rowHeight)
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
        }
    }

    /// Кнопка выбора устройства. Видна всегда — иначе о ней надо знать
    /// заранее. У приложения, уведённого в другое устройство, значок ещё и
    /// горит акцентным цветом: о таком маршруте легко забыть и потом долго
    /// искать, почему звук идёт не туда.
    private var outputButton: some View {
        OutputDeviceMenu(
            selectedUID: app.outputDeviceUID,
            availableDevices: availableDevices,
            systemDefaultTitle: "Как в системе",
            onSelect: onSelectOutput,
            fixedSize: true
        ) {
            // Значок устройства, если оно известно; если приложение уведено на
            // устройство, которого сейчас нет в системе, — общий значок вывода.
            Image(systemName: routedDevice?.symbolName ?? "airplayaudio")
                .font(.system(size: 11))
                .foregroundStyle(isRouted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: outputSize, height: outputSize)
                .contentShape(Rectangle())
        }
        .help(routedDevice.map { "Выход: \($0.name)" } ?? "Выбрать устройство вывода")
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


// MARK: - Размеры строки

/// Размеры строки в одном месте: по ним же панель считает свою ширину, а
/// строка — помещается ли название. Считаются от настроек, а не заданы
/// константами: ширина панели, высота строки и наличие кнопки вывода
/// настраиваются.
struct RowMetrics {

    let panelWidth: CGFloat
    let rowHeight: CGFloat
    let showsOutputButton: Bool

    let panelPadding: CGFloat = 14
    let rowPadding: CGFloat = 6
    let icon: CGFloat = 22
    let button: CGFloat = 18
    let spacing: CGFloat = 7

    /// Желаемая длина слайдера. Фиксированная, чтобы он не прыгал вбок при
    /// смене состава списка, но на узкой панели уступает место названию —
    /// иначе имени осталось бы 29 pt, то есть ничего.
    private let preferredSliderWidth: CGFloat = 165
    /// Меньше названию отдавать нельзя: короткие имена вроде Safari перестают
    /// помещаться целиком.
    private let minimumNameWidth: CGFloat = 69

    /// Сколько остаётся строке под название и слайдер вместе.
    private var available: CGFloat {
        let buttons = button * (showsOutputButton ? 2 : 1)
        let gaps = spacing * (showsOutputButton ? 4 : 3)
        return panelWidth - panelPadding * 2 - rowPadding * 2 - icon - buttons - gaps
    }

    var nameWidth: CGFloat {
        max(minimumNameWidth, available - preferredSliderWidth)
    }

    var sliderWidth: CGFloat {
        max(available - nameWidth, 80)
    }

    // MARK: Название

    static let fontSize: CGFloat = 12
    static var swiftUIFont: Font { .system(size: fontSize) }

    private static let pinAllowance: CGFloat = 12
    private static let font = NSFont.systemFont(ofSize: fontSize)

    /// Ширина названия на экране — с запасом под скрепку у закреплённых.
    static func width(of app: AudioAppState, includingPin pin: Bool) -> CGFloat {
        let text = (app.name as NSString).size(withAttributes: [.font: font]).width
        return text.rounded(.up) + (pin ? pinAllowance : 0)
    }
}
