//
//  BiquadCoefficients.swift
//  AudioMixer
//
//  Расчёт коэффициентов полосового фильтра.
//
//  Считается это прямо на realtime-потоке, поэтому функции ничего не
//  выделяют и пишут в готовый буфер. Тригонометрия из libm на RT-потоке
//  допустима: она не аллоцирует и не блокируется, а десять полос обходятся
//  примерно в микросекунду — и только когда полосы действительно поменяли.
//

import Foundation

enum BiquadCoefficients {

    /// Сколько чисел занимает одна секция: b0, b1, b2, a1, a2.
    static let perSection = 5

    /// Peaking EQ по кулинарной книге Роббера Бристоу-Джонсона — та же
    /// формула, что стоит за полосой любого графического эквалайзера.
    ///
    /// Коэффициенты нормируются на a0, потому что vDSP ждёт именно такой вид.
    private static func peaking(freq: Double,
                                gainDB: Double,
                                q: Double,
                                sampleRate: Double,
                                into out: UnsafeMutablePointer<Double>) {

        // Полоса выше половины частоты дискретизации физически не существует:
        // на 44,1 кГц это касается верхней полосы 16 кГц у некоторых устройств.
        // Такую полосу просто пропускаем — фильтр остаётся прозрачным.
        guard freq * 2 < sampleRate, gainDB.isFinite else {
            out[0] = 1; out[1] = 0; out[2] = 0; out[3] = 0; out[4] = 0
            return
        }

        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)

        let a0 = 1 + alpha / a
        out[0] = (1 + alpha * a) / a0
        out[1] = (-2 * cosw) / a0
        out[2] = (1 - alpha * a) / a0
        out[3] = (-2 * cosw) / a0
        out[4] = (1 - alpha / a) / a0
    }

    /// Заполняет массив для `vDSP_biquadm`: все полосы на все каналы.
    ///
    /// Порядок обязателен такой: сначала секция, внутри неё все каналы. Если
    /// разложить наоборот, vDSP не ругается — он молча ставит один фильтр в
    /// один канал дважды, а другой не ставит никуда. Ловится это только
    /// замером: подъём полосы на +12 дБ даёт +24 дБ в одном канале и ничего
    /// в другом.
    ///
    /// - Parameter gainsDB: усиления по полосам, ровно `frequencies.count`.
    /// - Parameter out: буфер на `sections * channels * perSection` чисел.
    static func fill(_ out: UnsafeMutablePointer<Double>,
                     gainsDB: UnsafePointer<Float>,
                     frequencies: [Double],
                     q: Double,
                     channels: Int,
                     sampleRate: Double) {

        var cursor = out
        for (index, freq) in frequencies.enumerated() {
            // Секция считается один раз и копируется на все каналы: полосы у
            // нас общие для левого и правого.
            peaking(freq: freq,
                    gainDB: Double(gainsDB[index]),
                    q: q,
                    sampleRate: sampleRate,
                    into: cursor)

            let section = cursor
            cursor += perSection
            for _ in 1..<Swift.max(channels, 1) {
                cursor[0] = section[0]
                cursor[1] = section[1]
                cursor[2] = section[2]
                cursor[3] = section[3]
                cursor[4] = section[4]
                cursor += perSection
            }
        }
    }
}
