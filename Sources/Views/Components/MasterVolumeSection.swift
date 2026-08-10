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

    /// Ultra-compact режим (вариант A): выбор устройства уезжает сюда же,
    /// в строку со слайдером, и отдельная секция «Выход» не показывается.
    let compact: Bool
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
                    isEnabled: systemVolume.isControllable && !systemVolume.isMuted
                )

                muteButton

                if compact {
                    OutputDeviceMenu(
                        device: device,
                        availableDevices: availableDevices,
                        onSelect: onSelectDevice
                    ) {
                        Image(systemName: "airplayaudio")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help("Устройство вывода")
                }
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
