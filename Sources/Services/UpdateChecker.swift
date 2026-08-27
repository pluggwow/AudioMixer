//
//  UpdateChecker.swift
//  AudioMixer
//
//  Проверка обновлений через GitHub Releases.
//
//  Это единственное место во всём приложении, которое ходит в сеть. До него не
//  ходило никуда, и в README про это сказано отдельно — чтобы человек, который
//  спросит «а оно ничего не отправляет», получил честный ответ.
//
//  Запрос без токена: репозиторий публичный, GitHub отдаёт последний релиз
//  анонимно. Токен зашивать в приложение нельзя — его оттуда вытащит кто угодно.
//

import Foundation

@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Когда проверяли в прошлый раз. Автоматическая проверка чаще раза в сутки
    /// не нужна никому: релизы выходят не чаще.
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Короткие сроки ожидания: проверка обновлений не тот повод, ради
        // которого стоит держать соединение полминуты.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["Accept": "application/vnd.github+json"]
        self.session = URLSession(configuration: config)
    }

    /// Проверить, если с прошлого раза прошли сутки. Для кнопки в настройках —
    /// `force: true`, там ждать сутки бессмысленно.
    func check(force: Bool) async {
        if !force, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.interval {
            return
        }

        state = .checking
        do {
            let (data, response) = try await session.data(from: AppInfo.latestReleaseAPI)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 403 — исчерпан лимит анонимных запросов, 404 — релизов ещё нет.
                throw CheckError.http(http.statusCode)
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            defaults.set(Date(), forKey: Self.lastCheckKey)

            let remote = Self.normalize(release.tagName)
            if Self.isNewer(remote, than: AppInfo.version), let page = URL(string: release.htmlURL) {
                state = .available(version: remote, page: page)
            } else {
                state = .upToDate
            }
        } catch {
            AppLog.processes.error(
                "Проверка обновлений не удалась: \(error.localizedDescription, privacy: .public)"
            )
            state = .failed(error.localizedDescription)
        }
    }

    private enum CheckError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(404): return String(localized: "Релизов пока нет")
            case .http(403): return String(localized: "GitHub временно не отвечает на запросы")
            case .http(let code): return String(format: String(localized: "GitHub ответил %lld"), code)
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    // MARK: - Сравнение версий

    /// «v0.2.0» → «0.2.0». Тег принято писать с буквой, версия в плисте — без.
    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Почленное сравнение чисел, а не строк: «0.10.0» больше «0.9.0», хотя
    /// строкой — меньше. Недостающие части считаются нулями: 0.2 == 0.2.0.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = parts(remote), b = parts(local)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
