//
//  AppRowView.swift
//  AudioMixer
//

import SwiftUI

struct AppRowView: View {

    let app: AudioAppState
    let showIcon: Bool
    let showPercentage: Bool
    let sliderStyle: SliderStyleOption
    let compact: Bool

    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void

    @State private var isHovering = false

    private var iconSize: CGFloat { compact ? 26 : 34 }

    var body: some View {
        HStack(spacing: 12) {
            if showIcon {
                iconView
                    .frame(width: iconSize, height: iconSize)
            }

            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: compact ? 12 : 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(app.isMuted ? .secondary : .primary)

                    Spacer(minLength: 4)

                    if showPercentage {
                        Text(app.isMuted ? "Выкл." : app.percentText)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }

                VolumeSlider(
                    value: Binding(
                        get: { app.isMuted ? 0 : app.volume },
                        set: { onVolumeChange($0) }
                    ),
                    style: sliderStyle == .thin ? .compact : .prominent,
                    isEnabled: !app.isMuted,
                    accentTint: .accentColor
                )
            }

            Button(action: onToggleMute) {
                Image(systemName: app.speakerSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .foregroundStyle(app.isMuted ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))
            .help(app.isMuted ? "Включить звук" : "Заглушить")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isHovering ? 0.06 : 0))
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: app.isMuted)
        .contextMenu {
            Button("Сбросить на 100%") { onVolumeChange(1.0) }
            Button(app.isMuted ? "Включить звук" : "Заглушить", action: onToggleMute)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .saturation(app.isMuted ? 0.2 : 1)
                .opacity(app.isMuted ? 0.65 : 1)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                )
        }
    }
}
