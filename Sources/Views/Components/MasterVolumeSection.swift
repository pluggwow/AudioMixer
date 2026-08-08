//
//  MasterVolumeSection.swift
//  AudioMixer
//

import SwiftUI

struct MasterVolumeSection: View {

    @ObservedObject var systemVolume: SystemVolumeController
    let device: AudioDeviceInfo?
    let availableDevices: [AudioDeviceInfo]
    let showPercentage: Bool
    let onSelectDevice: (AudioDeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Громкость")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                if showPercentage {
                    Text(systemVolume.isMuted ? "Выкл." : "\(Int((systemVolume.volume * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }

            HStack(spacing: 10) {
                VolumeSlider(
                    value: Binding(
                        get: { systemVolume.isMuted ? 0 : systemVolume.volume },
                        set: { newValue in
                            if systemVolume.isMuted && newValue > 0 { systemVolume.isMuted = false }
                            systemVolume.volume = newValue
                        }
                    ),
                    style: .prominent,
                    symbolName: "speaker.fill",
                    isEnabled: systemVolume.isControllable && !systemVolume.isMuted,
                    accentTint: .white
                )

                Button {
                    systemVolume.toggleMute()
                } label: {
                    Image(systemName: systemVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentTransition(.symbolEffect(.replace))
                .help(systemVolume.isMuted ? "Включить звук" : "Заглушить")
            }

            if !systemVolume.isControllable {
                Label("Устройство не поддерживает программную регулировку", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            deviceMenu
        }
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(availableDevices) { candidate in
                Button {
                    onSelectDevice(candidate)
                } label: {
                    HStack {
                        Image(systemName: candidate.symbolName)
                        Text(candidate.name)
                        if candidate.uid == device?.uid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: device?.symbolName ?? "speaker.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(device?.name ?? "Нет устройства вывода")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
