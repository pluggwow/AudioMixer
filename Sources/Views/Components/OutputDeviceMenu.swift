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

    /// UID выбранного устройства. nil — «как в системе».
    let selectedUID: String?
    let availableDevices: [AudioDeviceInfo]

    /// Заголовок пункта «как в системе». nil — пункта нет: у общего выбора
    /// устройства по умолчанию быть не может, там выбирают само умолчание.
    var systemDefaultTitle: String?

    /// nil означает возврат к системному устройству.
    let onSelect: (String?) -> Void
    var fixedSize: Bool = false
    @ViewBuilder let content: () -> Content

    /// Пустая строка вместо nil: тег пункта меню должен быть непустым типом,
    /// а Optional<String> в Picker ведёт себя капризно.
    private static var systemTag: String { "" }

    var body: some View {
        Menu {
            Picker("", selection: selection) {
                if let systemDefaultTitle {
                    Label(systemDefaultTitle, systemImage: "speaker.wave.2")
                        .tag(Self.systemTag)
                }
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
        // Крупнее пункты в выпадающем списке: на мелких значках устройств
        // сложно разобрать, где наушники, а где монитор.
        .controlSize(.large)
        .modifier(FixedSizeIfNeeded(enabled: fixedSize))
        .disabled(availableDevices.isEmpty)
    }

    private var selection: Binding<String> {
        Binding(
            get: { selectedUID ?? Self.systemTag },
            set: { tag in
                let uid = tag == Self.systemTag ? nil : tag
                guard uid != selectedUID else { return }
                onSelect(uid)
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
