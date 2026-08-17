//
//  EqualizerView.swift
//  AudioMixer
//
//  Десять вертикальных полос, выключатель и пресеты.
//
//  Раскладка повторяет системные эквалайзеры не из подражания: вертикальные
//  полосы в ряд читаются как кривая — видно форму, а не десять чисел. Поэтому
//  же под ползунками стоят подписи частот, а не номера полос.
//

import SwiftUI

struct EqualizerView: View {

    let bundleID: String

    @EnvironmentObject private var viewModel: MixerViewModel

    private var settings: EqualizerSettings { viewModel.equalizer(for: bundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            bands
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Выключенный эквалайзер видно, но крутить его бессмысленно:
                // до звука полосы всё равно не дойдут.
                .opacity(settings.isEnabled ? 1 : 0.45)
                .disabled(!settings.isEnabled)

            Spacer(minLength: 0)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { settings.isEnabled },
                set: { update { $0.isEnabled = $1 } (settings, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            Text("Эквалайзер")
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Picker("", selection: presetBinding) {
                Text("Свой").tag(nil as EqualizerPreset?)
                Divider()
                ForEach(EqualizerPreset.allCases) { preset in
                    Text(preset.title).tag(preset as EqualizerPreset?)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .disabled(!settings.isEnabled)
        }
    }

    /// Пресет показывается выбранным, только если полосы точно ему равны.
    /// Стоит подвинуть одну — в списке становится «Свой», и это честно.
    private var presetBinding: Binding<EqualizerPreset?> {
        Binding(
            get: { EqualizerPreset.matching(settings) },
            set: { preset in
                guard let preset else { return }
                var next = settings
                next.gainsDB = preset.gainsDB
                next.isEnabled = true
                viewModel.setEqualizer(next, for: bundleID)
            }
        )
    }

    // MARK: - Полосы

    private var bands: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(EqualizerSettings.frequencies.enumerated()), id: \.offset) { index, freq in
                VStack(spacing: 6) {
                    Text(gainText(index))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)

                    EqualizerBandSlider(
                        value: Binding(
                            get: { settings.gainsDB[index] },
                            set: { newValue in
                                var next = settings
                                next.gainsDB[index] = newValue
                                viewModel.setEqualizer(next, for: bundleID)
                            }
                        )
                    )

                    Text(label(for: freq))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func gainText(_ index: Int) -> String {
        let value = settings.gainsDB[index]
        if abs(value) < 0.05 { return "0" }
        return String(format: "%+.0f", value)
    }

    /// 16000 → «16к»: под ползунком шириной в три десятка точек полное число
    /// не помещается, а порядок величины и так понятен.
    private func label(for freq: Double) -> String {
        freq >= 1000
            ? "\(Int(freq / 1000))к"
            : "\(Int(freq))"
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack {
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Сбросить") {
                var next = settings
                next.gainsDB = EqualizerPreset.flat.gainsDB
                viewModel.setEqualizer(next, for: bundleID)
            }
            .controlSize(.small)
            .disabled(settings.isFlat)
        }
    }

    /// Про перехват сказано прямо: с включённым эквалайзером приложение
    /// таппится всегда, и индикатор приватности будет гореть, пока оно звучит.
    /// Узнать это из поведения нельзя, поэтому написано здесь.
    private var hint: String {
        settings.isActive
            ? "Пока эквалайзер работает, звук приложения идёт через AudioMixer"
            : "Полосы применяются к звуку только этого приложения"
    }

    private func update(_ change: @escaping (inout EqualizerSettings, Bool) -> Void)
        -> (EqualizerSettings, Bool) -> Void {
        { current, flag in
            var next = current
            change(&next, flag)
            viewModel.setEqualizer(next, for: bundleID)
        }
    }
}

/// Вертикальный ползунок одной полосы.
///
/// Своим он сделан не от хорошей жизни: системный `Slider` в вертикальном виде
/// приходится разворачивать поворотом, и вместе с ним разворачиваются
/// подсказки и попадание курсора.
private struct EqualizerBandSlider: View {

    @Binding var value: Double

    private let trackWidth: CGFloat = 4
    private let knobSize: CGFloat = 13

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let travel = height - knobSize
            let limit = EqualizerSettings.limitDB
            let fraction = (limit - value) / (limit * 2)     // 0 сверху, 1 снизу
            let knobY = knobSize / 2 + travel * fraction

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .frame(width: trackWidth)
                    .frame(maxWidth: .infinity)

                // Заполнение от середины: видно не только «где ползунок», но и
                // в какую сторону от нуля уведена полоса.
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: trackWidth,
                           height: abs(knobY - height / 2))
                    .position(x: proxy.size.width / 2,
                              y: (knobY + height / 2) / 2)

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .position(x: proxy.size.width / 2, y: knobY)
                    .animation(isDragging ? nil : .easeOut(duration: 0.12), value: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let clamped = min(max(drag.location.y - knobSize / 2, 0), travel)
                        let newFraction = travel > 0 ? clamped / travel : 0.5
                        value = limit - newFraction * limit * 2
                    }
                    .onEnded { _ in isDragging = false }
            )
            // Двойной клик возвращает полосу в ноль — то же, что и везде:
            // самый быстрый способ отменить одно неудачное движение.
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(width: 28, height: 150)
    }
}
