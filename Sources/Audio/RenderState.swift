//
//  RenderState.swift
//  AudioMixer
//
//  Всё, что исполняется на realtime-потоке Core Audio.
//
//  Правила этого файла (нарушение = дропы и щелчки):
//    - никаких аллокаций;
//    - никакого Swift runtime (ARC, словари, массивы с ростом);
//    - никаких блокирующих локов — только os_unfair_lock_trylock;
//    - никакого логирования.
//

import Foundation
import CoreAudio
import os

/// Разделяемое состояние между UI-потоком (пишет gain) и аудиопотоком (читает).
///
/// Модель данных намеренно примитивна: плоский массив gain-ов «на каждый входной
/// канал агрегатного устройства». Маппинг «приложение -> диапазон каналов»
/// вычисляется заранее на не-realtime стороне, здесь остаётся только умножение.
final class RenderState {

    /// Потолок каналов входа. 32 таппа по стерео = 64. С запасом.
    static let maxChannels = 128

    private let gains: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var activeChannels: Int = 0

    /// Мастер-гейн применяется поверх пер-аппового. Меняется атомарно отдельно от лока,
    /// чтобы движение мастер-слайдера не спорило за лок с пересборкой tap-list.
    private let masterGain: UnsafeMutablePointer<Float>

    init() {
        gains = .allocate(capacity: Self.maxChannels)
        gains.initialize(repeating: 0, count: Self.maxChannels)

        masterGain = .allocate(capacity: 1)
        masterGain.initialize(to: 1.0)

        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        gains.deinitialize(count: Self.maxChannels)
        gains.deallocate()
        masterGain.deinitialize(count: 1)
        masterGain.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Запись (не-realtime сторона)

    /// Полная замена карты гейнов. Вызывается при изменении набора таппов.
    func updateChannelGains(_ newGains: [Float]) {
        os_unfair_lock_lock(lock)
        let count = min(newGains.count, Self.maxChannels)
        for index in 0..<count {
            gains[index] = newGains[index]
        }
        for index in count..<Self.maxChannels {
            gains[index] = 0
        }
        activeChannels = count
        os_unfair_lock_unlock(lock)
    }

    /// Одиночное 32-битное выровненное сохранение — на arm64/x86_64 атомарно,
    /// рвать значение посередине нечем. Лок здесь не нужен и вреден.
    func setMasterGain(_ value: Float) {
        masterGain.pointee = max(0, min(value, 1))
    }

    // MARK: - Чтение (realtime сторона)

    /// Смешивает входные буферы (таппы) в выходной буфер устройства с применением gain.
    ///
    /// Формат: Core Audio отдаёт таппы в 32-bit float. Порядок входных каналов
    /// соответствует порядку таппов в tap-list агрегата — на этом строится маппинг.
    func render(input: UnsafePointer<AudioBufferList>,
                output: UnsafeMutablePointer<AudioBufferList>) {

        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        // Выход всегда обнуляем: если ниже что-то пойдёт не так, пользователь
        // услышит тишину, а не мусор из непроинициализированной памяти.
        for buffer in outputBuffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }

        // trylock: если UI прямо сейчас перестраивает карту — пропускаем цикл.
        // Один пропущенный буфер (~5 мс тишины) лучше, чем приоритетная инверсия.
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }

        guard activeChannels > 0,
              let outBuffer = outputBuffers.first,
              let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self)
        else { return }

        let outChannels = Int(outBuffer.mNumberChannels)
        guard outChannels > 0 else { return }

        let outFrames = Int(outBuffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
        guard outFrames > 0 else { return }

        let master = masterGain.pointee
        if master <= 0 { return }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )

        var channelCursor = 0

        for bufferIndex in 0..<inputBuffers.count {
            let buffer = inputBuffers[bufferIndex]
            let inChannels = Int(buffer.mNumberChannels)
            guard inChannels > 0 else { continue }

            guard let inData = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                channelCursor += inChannels
                continue
            }

            let inFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let frames = min(inFrames, outFrames)

            for channel in 0..<inChannels {
                let globalChannel = channelCursor + channel
                guard globalChannel < activeChannels else { break }

                let gain = gains[globalChannel] * master
                if gain <= 0 { continue }

                // Каналы входа кладём на одноимённые каналы выхода;
                // если выход уже (моно) — сворачиваем в последний доступный.
                let outChannel = min(channel, outChannels - 1)

                var frame = 0
                while frame < frames {
                    outData[frame * outChannels + outChannel] += inData[frame * inChannels + channel] * gain
                    frame += 1
                }
            }

            channelCursor += inChannels
        }

        // Мягкое ограничение. Сумма нескольких приложений на 100% может выйти за [-1, 1];
        // hard clip дал бы слышимые щелчки, tanh-подобная кривая — нет.
        var index = 0
        let total = outFrames * outChannels
        while index < total {
            let sample = outData[index]
            if sample > 1.0 || sample < -1.0 {
                outData[index] = sample > 0
                    ? 1.0 - (1.0 / (1.0 + sample))
                    : -1.0 + (1.0 / (1.0 - sample))
            }
            index += 1
        }
    }
}
