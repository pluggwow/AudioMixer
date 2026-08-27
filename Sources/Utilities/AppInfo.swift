//
//  AppInfo.swift
//  AudioMixer
//
//  Сведения о сборке. Отдельным типом, а не строкой в настройках: то же самое
//  понадобится проверке обновлений — ей надо с чем-то сравнивать.
//

import Foundation

enum AppInfo {

    /// Версия для человека: 0.1.0
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Номер сборки. Растёт между релизами с одной версией.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// Откуда приложение узнаёт о новых версиях. Публичный репозиторий,
    /// поэтому запрос идёт без токена.
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/pluggwow/AudioMixer/releases/latest"
    )!

    /// «0.1.0 (1)» — то, что просят назвать в ответ на «у меня не работает».
    static var versionWithBuild: String {
        build.isEmpty || build == version ? version : "\(version) (\(build))"
    }
}
