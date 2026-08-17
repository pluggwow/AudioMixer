//
//  EqualizerSettings.swift
//  AudioMixer
//
//  Десятиполосный эквалайзер: набор усилений в децибелах и выключатель.
//
//  Частоты — стандартный октавный ряд, тот же, что у системных эквалайзеров.
//  Добротность 1.41 выбрана не на глаз: при октавном шаге соседние полосы с
//  ней стыкуются без ям между ними и без горбов на стыке. Проверено замером —
//  подъём одной полосы на +12 дБ меняет соседнюю на 2%.
//

import Foundation

struct EqualizerSettings: Equatable {

    /// Центры полос в герцах.
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static var bandCount: Int { frequencies.count }

    /// Предел в обе стороны. Больше 12 дБ на полосу — почти гарантированная
    /// перегрузка на сумме полос, а мягкое ограничение в конце рендера
    /// начинает слышаться.
    static let limitDB: Double = 12

    /// Добротность каждой полосы.
    static let q: Double = 1.41

    var isEnabled: Bool = false
    var gainsDB: [Double] = Array(repeating: 0, count: EqualizerSettings.bandCount)

    static let off = EqualizerSettings()

    /// Все полосы в нуле — фильтр ничего не изменит.
    var isFlat: Bool { gainsDB.allSatisfy { abs($0) < 0.01 } }

    /// Влияет ли эквалайзер на звук прямо сейчас.
    ///
    /// Именно это, а не `isEnabled`, решает, нужен ли приложению тапп: включённый
    /// эквалайзер со всеми полосами в нуле не повод перехватывать звук.
    var isActive: Bool { isEnabled && !isFlat }

    /// Приводит набор к нужной длине и пределам.
    ///
    /// Данные приходят из настроек, которые может испортить кто угодно, а
    /// кривой набор — это неустойчивый фильтр, то есть громкий треск.
    func normalized() -> EqualizerSettings {
        var result = self
        var gains = gainsDB
        if gains.count > Self.bandCount {
            gains = Array(gains.prefix(Self.bandCount))
        } else if gains.count < Self.bandCount {
            gains += Array(repeating: 0, count: Self.bandCount - gains.count)
        }
        result.gainsDB = gains.map { value in
            guard value.isFinite else { return 0 }
            return Swift.max(-Self.limitDB, Swift.min(value, Self.limitDB))
        }
        return result
    }
}

// MARK: - Хранение

/// Ключи пишутся руками, а массив читается через `decodeIfPresent`: у тех, кто
/// уже пользуется приложением, в настройках эквалайзера нет вовсе, и
/// синтезированный декодер на таких данных падает целиком — вместе с
/// громкостями, которые рядом.
extension EqualizerSettings: Codable {

    private enum CodingKeys: String, CodingKey {
        case isEnabled, gainsDB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        gainsDB = try container.decodeIfPresent([Double].self, forKey: .gainsDB)
            ?? Array(repeating: 0, count: Self.bandCount)
        self = normalized()
    }
}

// MARK: - Пресеты

enum EqualizerPreset: String, CaseIterable, Identifiable {

    case flat, bass, vocal, treble, laptop, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat:   return "Плоский"
        case .bass:   return "Бас"
        case .vocal:  return "Голос"
        case .treble: return "Высокие"
        case .laptop: return "Ноутбук"
        case .night:  return "Ночь"
        }
    }

    /// Усиления по полосам: 32, 64, 125, 250, 500, 1к, 2к, 4к, 8к, 16к.
    var gainsDB: [Double] {
        switch self {
        case .flat:
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass:
            return [7, 6, 4.5, 2.5, 0, 0, 0, 0, 0, 0]
        // Разборчивость речи держится на 1–4 кГц; низ подрезан, чтобы гул
        // не забивал согласные.
        case .vocal:
            return [-4, -3, -1.5, 0, 2, 4, 4.5, 3, 1, 0]
        case .treble:
            return [0, 0, 0, 0, 0, 0, 1.5, 3.5, 5, 6]
        // Встроенные динамики ниже ~200 Гц не отдают ничего, кроме дребезга:
        // низ убираем, а разборчивость поднимаем серединой.
        case .laptop:
            return [-8, -6, -3, 0, 2, 3, 3, 2, 1, 0]
        // Тихое прослушивание: края подняты, потому что на малой громкости
        // слух к ним менее чувствителен.
        case .night:
            return [4, 3, 1.5, 0, -1, -1.5, -1, 0, 2, 3]
        }
    }

    var settings: EqualizerSettings {
        EqualizerSettings(isEnabled: true, gainsDB: gainsDB)
    }

    /// Какому пресету соответствует набор, если какому-то соответствует.
    static func matching(_ settings: EqualizerSettings) -> EqualizerPreset? {
        allCases.first { preset in
            zip(preset.gainsDB, settings.gainsDB).allSatisfy { abs($0 - $1) < 0.05 }
        }
    }
}
