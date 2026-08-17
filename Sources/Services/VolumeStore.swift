//
//  VolumeStore.swift
//  AudioMixer
//
//  Персистентность уровней по bundle identifier.
//  Сценарий из ТЗ: Spotify выставлен на 35%, закрыт, снова открыт -> снова 35%.
//

import Foundation
import Combine

@MainActor
final class VolumeStore: ObservableObject {

    private enum Keys {
        static let apps = "com.example.AudioMixer.storedApps"
    }

    @Published private(set) var storage: [String: StoredAppSettings] = [:]

    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?

    /// Данные на диске есть, но прочитать их не удалось. В этом состоянии
    /// storage пуст не потому, что настроек нет, а потому что мы их не поняли —
    /// и любая запись стёрла бы всё сохранённое. Поэтому запись блокируется.
    private var loadFailed = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Чтение

    func settings(for bundleID: String) -> StoredAppSettings? {
        storage[bundleID]
    }

    /// Уровень для приложения, которое только что появилось.
    func resolvedVolume(for bundleID: String, defaultVolume: Float, rememberEnabled: Bool) -> (Float, Bool) {
        guard rememberEnabled,
              let stored = storage[bundleID],
              stored.rememberVolume else {
            return (defaultVolume, false)
        }
        return (stored.volume, stored.isMuted)
    }

    // MARK: - Запись

    func update(bundleID: String, displayName: String, volume: Float, isMuted: Bool) {
        var entry = storage[bundleID] ?? StoredAppSettings()
        entry.volume = max(0, min(volume, 1))
        entry.isMuted = isMuted
        entry.displayName = displayName.isEmpty ? entry.displayName : displayName
        entry.lastSeen = .now
        storage[bundleID] = entry
        scheduleSave()
    }

    /// Закрепление не зависит от «запоминать громкости»: это не громкость,
    /// а состав списка, и запись нужна даже для приложения, которому
    /// громкость никогда не меняли — записи в storage для него ещё нет.
    func setPinned(_ pinned: Bool, for bundleID: String, displayName: String, anchor: PinAnchor?) {
        var entry = storage[bundleID] ?? StoredAppSettings()
        entry.isPinned = pinned
        entry.anchorBeforePin = anchor
        entry.displayName = displayName.isEmpty ? entry.displayName : displayName
        entry.lastSeen = .now
        storage[bundleID] = entry
        scheduleSave()
    }

    /// Своё устройство вывода для приложения. `nil` — вернуться к системному.
    /// Как и закрепление, не зависит от «запоминать громкости»: это не
    /// громкость, а маршрут.
    func setOutputDevice(_ uid: String?, for bundleID: String, displayName: String) {
        var entry = storage[bundleID] ?? StoredAppSettings()
        entry.outputDeviceUID = uid
        entry.displayName = displayName.isEmpty ? entry.displayName : displayName
        entry.lastSeen = .now
        storage[bundleID] = entry
        scheduleSave()
    }

    /// Полосы эквалайзера. Как закрепление и устройство, не зависит от
    /// «запоминать громкости»: это настройка звучания, а не громкость.
    func setEqualizer(_ settings: EqualizerSettings, for bundleID: String, displayName: String) {
        var entry = storage[bundleID] ?? StoredAppSettings()
        entry.equalizer = settings.normalized()
        entry.displayName = displayName.isEmpty ? entry.displayName : displayName
        entry.lastSeen = .now
        storage[bundleID] = entry
        scheduleSave()
    }

    /// Пользователь передвинул строку сам — прежнее место больше не актуально,
    /// открепление не должно отменять его выбор.
    func clearPinAnchor(for bundleID: String) {
        guard var entry = storage[bundleID], entry.anchorBeforePin != nil else { return }
        entry.anchorBeforePin = nil
        storage[bundleID] = entry
        scheduleSave()
    }

    /// Закреплённые приложения: из них строятся строки для тех, кто сейчас закрыт.
    var pinned: [(bundleID: String, settings: StoredAppSettings)] {
        storage
            .filter(\.value.isPinned)
            .map { ($0.key, $0.value) }
    }

    func setRememberVolume(_ remember: Bool, for bundleID: String) {
        guard var entry = storage[bundleID] else { return }
        entry.rememberVolume = remember
        storage[bundleID] = entry
        scheduleSave()
    }

    func forget(bundleID: String) {
        storage.removeValue(forKey: bundleID)
        scheduleSave()
    }

    /// Явное намерение пользователя стереть всё — снимает блокировку записи.
    func forgetAll() {
        storage.removeAll()
        loadFailed = false
        scheduleSave()
    }

    // MARK: - Персистентность

    /// Дебаунс: тянуть слайдер = сотни изменений в секунду,
    /// писать UserDefaults на каждое — расточительно.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    private func save() {
        guard !loadFailed else {
            AppLog.processes.error("Сохранение пропущено: настройки не прочитались при старте, запись затёрла бы их")
            return
        }
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: Keys.apps)
    }

    private func load() {
        // Ключа нет — просто первый запуск, это не ошибка.
        guard let data = defaults.data(forKey: Keys.apps) else { return }
        do {
            storage = try JSONDecoder().decode([String: StoredAppSettings].self, from: data)
        } catch {
            loadFailed = true
            AppLog.processes.error(
                "Не удалось прочитать сохранённые громкости: \(error.localizedDescription, privacy: .public). Запись заблокирована, чтобы не потерять данные."
            )
        }
    }

    func flush() {
        saveTask?.cancel()
        save()
    }
}
