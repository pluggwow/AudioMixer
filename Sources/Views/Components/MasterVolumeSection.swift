//
//  MasterVolumeSection.swift
//  AudioMixer
//
//  Верх панели: заголовок «Звук» и один слайдер между двумя динамиками —
//  ровно как в системной панели Control Center.
//

import SwiftUI

struct MasterVolumeSection: View {

    @ObservedObject var systemVolume: SystemVolumeController

    let device: AudioDeviceInfo?
    let availableDevices: [AudioDeviceInfo]
    let onSelectDevice: (AudioDeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Звук")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                // Слева тихий динамик, справа громкий — как в системной панели.
                // Отличие одно: правый ещё и выключает звук, иначе mute
                // пришлось бы вешать на лишний элемент.
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                VolumeSlider(
                    value: Binding(
                        get: { systemVolume.isMuted ? 0 : systemVolume.volume },
                        set: { newValue in
                            if systemVolume.isMuted && newValue > 0 { systemVolume.isMuted = false }
                            systemVolume.volume = newValue
                        }
                    ),
                    style: .system,
                    // На mute слайдер тоже живой: движение вверх снимает mute
                    // тут же, в сеттере привязки.
                    isEnabled: systemVolume.isControllable,
                    hoverLabel: systemVolume.isMuted
                        ? String(localized: "Выкл.")
                        : "\(Int((systemVolume.volume * 100).rounded()))%"
                )

                muteButton

                // Устройство вывода — кнопкой прямо здесь: отдельная секция
                // «Выход» съедала бы половину высоты компактной панели.
                OutputDeviceMenu(
                    selectedUID: device?.uid,
                    availableDevices: availableDevices,
                    onSelect: { uid in
                        guard let uid, let picked = availableDevices.first(where: { $0.uid == uid }) else { return }
                        onSelectDevice(picked)
                    },
                    fixedSize: true
                ) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .help(device.map { String(format: String(localized: "Выход: %@"), $0.name) }
                        ?? String(localized: "Устройство вывода"))
            }

            if !systemVolume.isControllable {
                Label("Устройство не поддерживает программную регулировку", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var muteButton: some View {
        Button {
            systemVolume.toggleMute()
        } label: {
            Image(systemName: systemVolume.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(systemVolume.isMuted ? Color.secondary : Color.primary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
        .disabled(!systemVolume.isMuteSupported)
        .opacity(systemVolume.isMuteSupported ? 1 : 0.4)
        .help(systemVolume.isMuteSupported
              ? (systemVolume.isMuted ? "Включить звук" : "Заглушить")
              : "Устройство не поддерживает программное отключение звука")
    }
}
