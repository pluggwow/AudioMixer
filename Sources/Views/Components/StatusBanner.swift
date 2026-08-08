//
//  StatusBanner.swift
//  AudioMixer
//
//  Все нештатные состояния UI в одном месте: нет разрешения, движок упал,
//  нет приложений, старая macOS.
//

import SwiftUI

struct PermissionBanner: View {

    let status: PermissionManager.Status
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .unsupported = status {
                EmptyView()
            } else {
                HStack(spacing: 8) {
                    Button("Открыть Системные настройки", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Проверить снова", action: onRecheck)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var symbol: String {
        if case .unsupported = status { return "exclamationmark.octagon" }
        return "waveform.badge.exclamationmark"
    }

    private var title: String {
        if case .unsupported = status { return "Система не поддерживается" }
        return "Нужен доступ к звуку"
    }

    private var message: String {
        switch status {
        case .unsupported(let reason):
            return reason + ". Управление громкостью отдельных приложений использует Core Audio Process Tap, доступный только начиная с этой версии."
        default:
            return "Чтобы регулировать громкость отдельных приложений, macOS должна разрешить AudioMixer захват аудио. Без этого разрешения работает только общая громкость."
        }
    }
}

struct EmptyAppsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.bubble")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            Text("Нет приложений со звуком")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Запустите что-нибудь, что воспроизводит аудио")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

struct EngineErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Аудиодвижок недоступен")
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
    }
}
