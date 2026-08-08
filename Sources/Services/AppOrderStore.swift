//
//  AppOrderStore.swift
//  AudioMixer
//
//  Порядок строк, заданный пользователем вручную.
//
//  Отдельно от VolumeStore намеренно: там запись блокируется, если настройки
//  не прочитались при старте (иначе они были бы затёрты). Порядок строк такой
//  защиты не стоит — терять из-за него громкости, как и наоборот, незачем.
//

import Foundation
import Combine

@MainActor
final class AppOrderStore: ObservableObject {

    private enum Keys {
        static let order = "com.example.AudioMixer.appOrder"
    }

    /// bundleID в порядке, заданном пользователем. Пусто — порядок автоматический.
    @Published private(set) var order: [String] = []

    /// Список копится: приложение, которое пользователь один раз переставил,
    /// остаётся в нём и после закрытия — чтобы при следующем запуске встать
    /// на своё место. Потолок нужен, чтобы за годы работы в UserDefaults
    /// не осел список из тысяч bundleID.
    private let limit = 200

    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Дубликаты сюда попасть не могут, но если файл настроек кто-то правил
        // руками — два одинаковых bundleID сломали бы ForEach по id.
        var seen = Set<String>()
        order = (defaults.stringArray(forKey: Keys.order) ?? []).filter { seen.insert($0).inserted }
    }

    var isCustom: Bool { !order.isEmpty }

    /// Вплести новый порядок видимых строк в сохранённый.
    ///
    /// Приложения, которых сейчас в списке нет, остаются на своих местах, а
    /// видимые занимают позиции, которые в сохранённом порядке принадлежали
    /// видимым. Наивная замена (`order = visibleOrder`) роняла бы закрытое
    /// приложение в конец списка при любой перестановке соседей.
    func apply(visibleOrder: [String]) {
        let visible = Set(visibleOrder)
        var queue = visibleOrder[...]
        var merged: [String] = []
        merged.reserveCapacity(max(order.count, visibleOrder.count))

        for bundleID in order {
            if visible.contains(bundleID) {
                if let next = queue.popFirst() { merged.append(next) }
            } else {
                merged.append(bundleID)
            }
        }
        // Приложения, которых в сохранённом порядке ещё не было.
        merged.append(contentsOf: queue)

        order = Array(merged.prefix(limit))
        scheduleSave()
    }

    /// Переставить приложение на место, описанное якорем. Работает по
    /// сохранённому списку, включая закрытые приложения, — поэтому вернуть
    /// строку можно и за соседа, которого сейчас не видно.
    ///
    /// `false` — якоря в списке уже нет (приложение забыли или вытеснили из
    /// потолка), возвращать не за что; порядок при этом не меняется.
    @discardableResult
    func place(_ bundleID: String, at anchor: PinAnchor) -> Bool {
        var updated = order
        guard let current = updated.firstIndex(of: bundleID) else { return false }
        updated.remove(at: current)

        switch anchor {
        case .top:
            updated.insert(bundleID, at: 0)
        case .after(let anchorID):
            guard let position = updated.firstIndex(of: anchorID) else { return false }
            updated.insert(bundleID, at: position + 1)
        }

        order = updated
        scheduleSave()
        return true
    }

    /// Вернуться к автоматическому порядку.
    func reset() {
        order = []
        scheduleSave()
    }

    // MARK: - Персистентность

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    private func save() {
        if order.isEmpty {
            defaults.removeObject(forKey: Keys.order)
        } else {
            defaults.set(order, forKey: Keys.order)
        }
    }

    func flush() {
        saveTask?.cancel()
        save()
    }
}
