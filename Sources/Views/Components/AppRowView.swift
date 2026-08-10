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
    /// Ширина колонки названия. Её считает список — одну на все строки, по
    /// самому длинному имени, чтобы слайдеры стояли по одной вертикали.
    var nameWidth: CGFloat = AppNameMetrics.maxColumnWidth

    /// Строку сейчас тащат мышью.
    var isDragged: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    var onTogglePin: () -> Void = {}
    /// nil — вернуть приложение на системное устройство.
    var onSelectOutput: (String?) -> Void = { _ in }
    /// Сдвиг на позицию: -1 вверх, +1 вниз.
    var onMove: (Int) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isNameHovering = false

    /// Высота строки задаётся, а не выводится из содержимого: по ней панель
    /// считает свой размер, а перетаскивание — шаг сетки.
    static let height: CGFloat = 38

    private let iconSize: CGFloat = 22
    private let muteSize: CGFloat = 18
    private let outputSize: CGFloat = 18
    private let spacing: CGFloat = 7

    /// Имя не поместилось в отведённую колонку и обрезано многоточием.
    private var isNameTruncated: Bool {
        AppNameMetrics.width(of: app, includingPin: app.isPinned) > nameWidth
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
                    .font(AppNameMetrics.swiftUIFont)
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
            .frame(width: nameWidth, alignment: .leading)
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
                // Выключаем слайдер только на mute. На нуле он обязан
                // остаться живым — иначе громкость неоткуда поднять.
                isEnabled: !app.isMuted,
                // Серый и на нуле, и у закрытого закреплённого приложения.
                // Цвет задаётся явно, а не оставляется на .saturation строки:
                // фильтр насыщенности до заливки слайдера доходит не всегда,
                // и цветная полоска выбивалась из приглушённой строки.
                accentTint: (app.isSilent || !app.isRunning) ? .secondary : nil,
                hoverLabel: showPercentage ? (app.isMuted ? "Выкл." : app.percentText) : nil
            )
            .frame(maxWidth: .infinity)

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

            outputButton
        }
        // Закреплённое, но закрытое приложение — бесцветная строка.
        // Обесцвечивается всё разом, вместе с заливкой слайдера: так сразу
        // видно, что звука за этой строкой сейчас нет, но громкость выставить
        // можно.
        .saturation(app.isRunning ? 1 : 0)
        .opacity(app.isRunning ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.2), value: app.isRunning)
        .padding(.horizontal, 6)
        .frame(height: Self.height)
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


// MARK: - Размеры колонки названий

/// Ширина колонки названий считается по тексту, а не берётся с потолка:
/// при коротких именах колонка ужимается и слайдер вырастает влево, а при
/// длинных упирается в потолок — иначе слайдеру не осталось бы места.
enum AppNameMetrics {

    static let fontSize: CGFloat = 12
    static var swiftUIFont: Font { .system(size: fontSize) }

    /// Меньше уже нельзя: в колонке должна помещаться хотя бы скрепка.
    static let minColumnWidth: CGFloat = 44
    /// Больше — незачем: остаток строки нужен слайдеру.
    static let maxColumnWidth: CGFloat = 104

    private static let pinAllowance: CGFloat = 12
    /// Небольшой запас справа: без него самое длинное имя упиралось бы
    /// в слайдер вплотную.
    private static let trailingGap: CGFloat = 6

    private static let font = NSFont.systemFont(ofSize: fontSize)

    static func width(of app: AudioAppState, includingPin pin: Bool) -> CGFloat {
        let text = (app.name as NSString).size(withAttributes: [.font: font]).width
        return text.rounded(.up) + (pin ? pinAllowance : 0)
    }

    /// Одна ширина на весь список — по самому длинному имени.
    static func columnWidth(for apps: [AudioAppState]) -> CGFloat {
        let widest = apps.map { width(of: $0, includingPin: $0.isPinned) }.max() ?? 0
        return min(max(widest + trailingGap, minColumnWidth), maxColumnWidth)
    }
}
