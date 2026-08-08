//
//  AppIconProvider.swift
//  AudioMixer
//
//  Иконки приложений. Кэш обязателен: NSWorkspace.icon(forFile:) читает диск,
//  а список перестраивается на каждое изменение аудио-состояния.
//

import AppKit

@MainActor
final class AppIconProvider {

    static let shared = AppIconProvider()

    private var cache: [String: NSImage] = [:]

    private init() {}

    func icon(bundleID: String, pid: pid_t) -> NSImage? {
        if let cached = cache[bundleID] { return cached }

        var image: NSImage?

        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            image = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }

        guard let image else { return nil }
        // 64, а не 32: строка показывает иконку в 34 точки, на Retina это 68 пикселей —
        // с 32 она была бы мыльной.
        image.size = NSSize(width: 64, height: 64)
        cache[bundleID] = image
        return image
    }

    func purge() { cache.removeAll() }
}
