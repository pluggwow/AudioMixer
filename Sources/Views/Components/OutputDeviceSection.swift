//
//  OutputDeviceSection.swift
//  AudioMixer
//
//  Секция «Выход»: текущее устройство строкой, по клику — список остальных.
//
//  Устройства берутся и переключаются через MixerViewModel, который дальше
//  зовёт AudioDeviceManager. Своего доступа к Core Audio у этих вью нет.
//

import SwiftUI

/// Меню выбора устройства с произвольной подложкой.
///
/// Внутри намеренно `Picker` со стилем `.inline`, а не набор кнопок: так
/// список рисует сам AppKit — с галочкой у текущего пункта и системными
/// отступами. Собранное вручную меню отличается от системного мелочами,
/// которые сразу выдают стороннее приложение.
struct OutputDeviceMenu<Content: View>: View {

    let device: AudioDeviceInfo?
    let availableDevices: [AudioDeviceInfo]
    let onSelect: (AudioDeviceInfo) -> Void
    var fixedSize: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(availableDevices) { candidate in
                    Label(candidate.name, systemImage: candidate.symbolName)
                        .tag(candidate.uid)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            content()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .modifier(FixedSizeIfNeeded(enabled: fixedSize))
        .disabled(availableDevices.isEmpty)
    }

    private var selection: Binding<String> {
        Binding(
            get: { device?.uid ?? "" },
            set: { uid in
                guard let picked = availableDevices.first(where: { $0.uid == uid }),
                      picked.uid != device?.uid else { return }
                onSelect(picked)
            }
        )
    }
}

private struct FixedSizeIfNeeded: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.fixedSize() } else { content }
    }
}

/// Вариант B: отдельная секция под слайдером.
struct OutputDeviceSection: View {

    let device: AudioDeviceInfo?
    let availableDevices: [AudioDeviceInfo]
    let onSelect: (AudioDeviceInfo) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Выход")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            OutputDeviceMenu(device: device, availableDevices: availableDevices, onSelect: onSelect) {
                HStack(spacing: 8) {
                    deviceIcon

                    Text(device?.name ?? "Нет устройства вывода")
                        .font(.system(size: 13))
                        .foregroundStyle(device == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    // Индикатор всплывающего меню, а не «>»: в macOS стрелка
                    // вправо означает переход, а здесь открывается список.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(isHovering ? 0.07 : 0))
                )
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
    }

    /// Кружок с глифом — так текущее устройство показывает сама панель «Звук».
    private var deviceIcon: some View {
        ZStack {
            Circle().fill(device == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
            Image(systemName: device?.symbolName ?? "speaker.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(device == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
        }
        .frame(width: 22, height: 22)
    }
}
