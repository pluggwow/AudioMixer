//
//  OutputDeviceMenu.swift
//  AudioMixer
//
//  Меню выбора устройства вывода: и общего, и для отдельного приложения.
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
