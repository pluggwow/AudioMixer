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
import Accelerate
import os

/// Разделяемое состояние между UI-потоком (пишет gain) и аудиопотоком (читает).
///
/// Модель данных намеренно примитивна: плоский массив gain-ов «на каждый входной
/// канал агрегатного устройства». Маппинг «приложение -> диапазон каналов»
/// вычисляется заранее на не-realtime стороне, здесь остаётся только умножение.
final class RenderState {

    /// Потолок каналов входа. 32 таппа по стерео = 64. С запасом.
    static let maxChannels = 128

    /// Целевые гейны: куда громкость должна прийти.
    ///
    /// Хранятся образами Float в uint32: пишет их очередь движка, читает
    /// аудиопоток, и общего лока между ними нет — он на realtime-потоке
    /// запрещён. Обычное присваивание в такой паре было бы гонкой по правилам
    /// языка, поэтому доступ идёт через relaxed-атомарные операции. На arm64
    /// и x86_64 это те же инструкции, что и присваивание.
    private let gains: UnsafeMutablePointer<UInt32>

    /// Достигнутые гейны: откуда начинается разгон в следующем буфере.
    ///
    /// Принадлежат ИСКЛЮЧИТЕЛЬНО аудиопотоку — никто, кроме `render`, их не
    /// трогает, поэтому лок им не нужен. Из-за них смена громкости перестаёт
    /// быть ступенькой на границе буфера: множитель доезжает до цели за буфер,
    /// по сэмплу, и разрыва в волне не возникает.
    private let currentGains: UnsafeMutablePointer<Float>

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var activeChannels: Int = 0

    /// Мастер-гейн применяется поверх пер-аппового. Живёт отдельно от лока,
    /// чтобы движение мастер-слайдера не спорило за него с пересборкой
    /// tap-list. Хранение и доступ — как у `gains`.
    private let masterGain: UnsafeMutablePointer<UInt32>

    // MARK: - Эквалайзер

    /// Потолок каналов, к которым применяется эквалайзер.
    static let maxEQChannels = 8

    /// Полосы в децибелах и выключатель — так же атомарно, как гейны.
    ///
    /// Готовые коэффициенты через поток не передаются намеренно. Их набор надо
    /// отдавать целиком: половина старых с половиной новых — это уже другой
    /// фильтр, возможно неустойчивый, то есть громкий треск. Передавать целиком
    /// значит либо лок на RT-потоке, либо двойная буферизация с версиями.
    /// Полосы же независимы: смешались старая с новой — просто один буфер с
    /// чуть другой кривой. Поэтому через поток идут полосы, а коэффициенты
    /// считает сам аудиопоток, и только когда полосы поменялись.
    private let bandGains: UnsafeMutablePointer<UInt32>
    private let eqEnabled: UnsafeMutablePointer<UInt32>

    /// Настройка фильтра. Создаётся не-realtime стороной под локом: создание
    /// выделяет память, на RT-потоке это запрещено.
    private var eqSetup: vDSP_biquadm_Setup?
    private var eqChannels = 0
    private var eqSampleRate: Double = 0

    /// Буфер коэффициентов и массивы указателей для vDSP. Выделены заранее,
    /// в рендере только заполняются.
    private let coefficients: UnsafeMutablePointer<Double>
    private let eqInputs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let eqOutputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    /// Полосы, которые уже стоят в фильтре, и признак «фильтр сейчас считается».
    /// Принадлежат исключительно аудиопотоку.
    private let appliedBands: UnsafeMutablePointer<Float>
    private var eqRunning = false

    private static var coefficientCapacity: Int {
        EqualizerSettings.bandCount * maxEQChannels * BiquadCoefficients.perSection
    }

    init() {
        gains = .allocate(capacity: Self.maxChannels)
        gains.initialize(repeating: 0, count: Self.maxChannels)   // образ 0.0

        // С нуля: первый буфер после включения движка нарастает от тишины,
        // а не начинается со скачка.
        currentGains = .allocate(capacity: Self.maxChannels)
        currentGains.initialize(repeating: 0, count: Self.maxChannels)

        masterGain = .allocate(capacity: 1)
        masterGain.initialize(to: 0)
        AudioMixerStoreFloatRelaxed(masterGain, 1)

        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())

        let bands = EqualizerSettings.bandCount
        bandGains = .allocate(capacity: bands)
        bandGains.initialize(repeating: 0, count: bands)   // образ 0.0 дБ
        eqEnabled = .allocate(capacity: 1)
        eqEnabled.initialize(to: 0)

        coefficients = .allocate(capacity: Self.coefficientCapacity)
        coefficients.initialize(repeating: 0, count: Self.coefficientCapacity)
        appliedBands = .allocate(capacity: bands)
        appliedBands.initialize(repeating: 0, count: bands)

        eqInputs = .allocate(capacity: Self.maxEQChannels)
        eqInputs.initialize(repeating: nil, count: Self.maxEQChannels)
        eqOutputs = .allocate(capacity: Self.maxEQChannels)
        eqOutputs.initialize(repeating: nil, count: Self.maxEQChannels)
    }

    deinit {
        gains.deinitialize(count: Self.maxChannels)
        gains.deallocate()
        currentGains.deinitialize(count: Self.maxChannels)
        currentGains.deallocate()
        masterGain.deinitialize(count: 1)
        masterGain.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()

        if let eqSetup { vDSP_biquadm_DestroySetup(eqSetup) }
        let bands = EqualizerSettings.bandCount
        bandGains.deinitialize(count: bands); bandGains.deallocate()
        eqEnabled.deinitialize(count: 1); eqEnabled.deallocate()
        coefficients.deinitialize(count: Self.coefficientCapacity); coefficients.deallocate()
        appliedBands.deinitialize(count: bands); appliedBands.deallocate()
        eqInputs.deinitialize(count: Self.maxEQChannels); eqInputs.deallocate()
        eqOutputs.deinitialize(count: Self.maxEQChannels); eqOutputs.deallocate()
    }

    // MARK: - Запись (не-realtime сторона)

    /// Сколько каналов записала не-realtime сторона в прошлый раз.
    /// Трогает её только она, поэтому синхронизации не требует.
    private var writerChannelCount = 0

    /// Обновить гейны. Лок берётся, только если поменялась РАСКЛАДКА каналов.
    ///
    /// Движение слайдера меняет одни значения, и брать под них лок нельзя:
    /// realtime-поток заходит через `trylock` и на неудачу отдаёт буфер
    /// тишины. При шестидесяти обновлениях в секунду это давало слышимые
    /// провалы — «звук прерывается на миллисекунду». Значения пишутся
    /// атомарно, поэтому порвать их посередине нечем; худшее, что может
    /// случиться, — один буфер со смесью старых и новых гейнов, а его
    /// сгладит интерполяция.
    func updateChannelGains(_ newGains: [Float]) {
        let count = min(newGains.count, Self.maxChannels)

        if count == writerChannelCount {
            for index in 0..<count {
                AudioMixerStoreFloatRelaxed(gains + index, newGains[index])
            }
            return
        }

        os_unfair_lock_lock(lock)
        for index in 0..<count {
            AudioMixerStoreFloatRelaxed(gains + index, newGains[index])
        }
        for index in count..<Self.maxChannels {
            AudioMixerStoreFloatRelaxed(gains + index, 0)
        }
        activeChannels = count
        os_unfair_lock_unlock(lock)

        writerChannelCount = count
    }

    /// Задать полосы эквалайзера. Лока не требует — см. `bandGains`.
    func updateEqualizer(_ settings: EqualizerSettings) {
        let normalized = settings.normalized()
        for index in 0..<EqualizerSettings.bandCount {
            AudioMixerStoreFloatRelaxed(bandGains + index, Float(normalized.gainsDB[index]))
        }
        AudioMixerStoreFloatRelaxed(eqEnabled, normalized.isActive ? 1 : 0)
    }

    /// Подготовить фильтр под формат маршрута.
    ///
    /// Только с очереди движка: создание настройки выделяет память. Лок здесь
    /// нужен, потому что указатель на настройку читает аудиопоток; он заходит
    /// через `trylock`, так что худшее — один буфер тишины в момент пересборки
    /// маршрута, где разрыв и так есть.
    func prepareEqualizer(channels: Int, sampleRate: Double) {
        let channels = Swift.max(1, Swift.min(channels, Self.maxEQChannels))
        guard sampleRate > 0 else { return }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard channels != eqChannels || sampleRate != eqSampleRate || eqSetup == nil else { return }

        if let old = eqSetup { vDSP_biquadm_DestroySetup(old) }
        eqSetup = nil

        // Стартуем с прозрачного фильтра: реальные полосы аудиопоток подставит
        // сам, целями с плавным переходом, — и включение обойдётся без щелчка.
        let sections = EqualizerSettings.bandCount
        let count = sections * channels * BiquadCoefficients.perSection
        for index in 0..<count {
            coefficients[index] = (index % BiquadCoefficients.perSection == 0) ? 1 : 0
        }

        eqSetup = vDSP_biquadm_CreateSetup(coefficients,
                                           vDSP_Length(sections),
                                           vDSP_Length(channels))
        eqChannels = eqSetup == nil ? 0 : channels
        eqSampleRate = sampleRate

        // Полосы придётся поставить заново: настройка новая.
        for index in 0..<sections { appliedBands[index] = 0 }
        eqRunning = false
    }

    /// Одиночное атомарное сохранение. Лок здесь не нужен и вреден.
    func setMasterGain(_ value: Float) {
        AudioMixerStoreFloatRelaxed(masterGain, max(0, min(value, 1)))
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

        // Ранний выход по нулевому мастеру убран намеренно: он обрубал бы звук
        // ступенькой ровно в тот момент, когда пользователь уводит системную
        // громкость в ноль. Теперь ноль — такая же цель разгона, как любая
        // другая, а когда все каналы до неё доехали, цикл и так пропускает их.
        let master = AudioMixerLoadFloatRelaxed(masterGain)

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
            // Пустой буфер: делить на 0 кадров нельзя, шаг разгона стал бы NaN.
            guard frames > 0 else {
                channelCursor += inChannels
                continue
            }

            for channel in 0..<inChannels {
                let globalChannel = channelCursor + channel
                guard globalChannel < activeChannels else { break }

                let from = currentGains[globalChannel]
                let to = AudioMixerLoadFloatRelaxed(gains + globalChannel) * master

                // Канал молчал и молчит — складывать нечего.
                if from <= 0 && to <= 0 { continue }

                // Каналы входа кладём на одноимённые каналы выхода;
                // если выход уже (моно) — сворачиваем в последний доступный.
                let outChannel = min(channel, outChannels - 1)

                // Линейный разгон: за буфер (~5 мс) множитель доезжает от
                // достигнутого значения до целевого — это и заменяет щелчок
                // плавным переходом.
                //
                // vDSP_vrampmuladd делает ровно то, что раньше делал цикл:
                //   O[i*OS] += start * I[i*IS];  start += step
                // Каналы у нас чередуются, то есть шаг больше единицы — не
                // самый выгодный для векторизации случай, и всё же замер даёт
                // ускорение в 2–3 раза. Функция не аллоцирует и не блокируется,
                // так что правил этого файла не нарушает.
                var gain = from
                var step = (to - from) / Float(frames)

                vDSP_vrampmuladd(inData + channel, vDSP_Stride(inChannels),
                                 &gain, &step,
                                 outData + outChannel, vDSP_Stride(outChannels),
                                 vDSP_Length(frames))

                // Берём цель, а не то, что vDSP оставил в gain: там накопленная
                // ошибка округления — она полезна для продолжения того же
                // разгона, но у нас каждый буфер начинает новый.
                currentGains[globalChannel] = to
            }

            channelCursor += inChannels
        }

        applyEqualizerUnsafe(outData: outData, frames: outFrames, outChannels: outChannels)

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

    /// Фильтр поверх сведённого буфера.
    ///
    /// В маршруте ровно один тапп, то есть весь выходной буфер — это звук
    /// одного приложения. Поэтому эквалайзер применяется прямо к нему, а не
    /// к отдельным входным каналам: считать надо один раз, а не по разу на
    /// канал таппа.
    ///
    /// Вызывается из `render` под уже взятым локом.
    private func applyEqualizerUnsafe(outData: UnsafeMutablePointer<Float>,
                                      frames: Int,
                                      outChannels: Int) {

        guard AudioMixerLoadFloatRelaxed(eqEnabled) > 0.5,
              let setup = eqSetup,
              eqChannels > 0,
              // Настройка сделана под определённое число каналов, и vDSP ждёт
              // ровно столько указателей. Если устройство отдаёт меньше —
              // пропускаем: лучше без эквалайзера, чем мимо буфера.
              outChannels >= eqChannels
        else {
            eqRunning = false
            return
        }

        // Полосы поменялись — пересчитываем коэффициенты и отдаём их целями.
        // vDSP доводит фильтр до них плавно, поэтому крутить полосы можно на
        // ходу без щелчков.
        var changed = !eqRunning
        for index in 0..<EqualizerSettings.bandCount {
            let value = AudioMixerLoadFloatRelaxed(bandGains + index)
            if value != appliedBands[index] {
                appliedBands[index] = value
                changed = true
            }
        }

        if changed {
            BiquadCoefficients.fill(coefficients,
                                    gainsDB: appliedBands,
                                    frequencies: EqualizerSettings.frequencies,
                                    q: EqualizerSettings.q,
                                    channels: eqChannels,
                                    sampleRate: eqSampleRate)
            vDSP_biquadm_SetTargetsDouble(setup, coefficients, 0.995, 0.05, 0, 0,
                                          vDSP_Length(EqualizerSettings.bandCount),
                                          vDSP_Length(eqChannels))
            eqRunning = true
        }

        for channel in 0..<eqChannels {
            eqInputs[channel] = UnsafePointer(outData + channel)
            eqOutputs[channel] = outData + channel
        }

        // Optional-указатель лежит в памяти так же, как обычный, поэтому
        // массивы переиспользуются без копирования.
        let inputs = UnsafeMutableRawPointer(eqInputs)
            .assumingMemoryBound(to: UnsafePointer<Float>.self)
        let outputs = UnsafeMutableRawPointer(eqOutputs)
            .assumingMemoryBound(to: UnsafeMutablePointer<Float>.self)

        // Считаем прямо в выходном буфере: проверено, результат совпадает с
        // раздельным. Шаг равен числу каналов — буфер чередующийся.
        vDSP_biquadm(setup,
                     inputs, vDSP_Stride(outChannels),
                     outputs, vDSP_Stride(outChannels),
                     vDSP_Length(frames))
    }
}
