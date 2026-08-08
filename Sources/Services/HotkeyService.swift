//
//  HotkeyService.swift
//  AudioMixer
//
//  ЗАДЕЛ ПОД ГОРЯЧИЕ КЛАВИШИ. Намеренно не реализовано в MVP.
//
//  Почему это не «просто добавить»:
//  клавиши громкости на Mac — это НЕ обычные key events. Они приходят как
//  NSEvent типа .systemDefined (subtype 8, NX_KEYTYPE_SOUND_UP/DOWN) и не
//  перехватываются ни NSEvent.addGlobalMonitorForEvents, ни Carbon
//  RegisterEventHotKey. Единственный рабочий путь — CGEvent.tapCreate на
//  .systemDefined, а он требует разрешения Accessibility (отдельный TCC-запрос)
//  и корректной обработки таймаута тапа.
//
//  Поэтому: интерфейс определён сейчас, реализация — после MVP,
//  чтобы не тащить второй permission-flow в первую версию.
//

import Foundation

enum HotkeyAction: String, CaseIterable {
    case increaseFocusedAppVolume
    case decreaseFocusedAppVolume
    case toggleFocusedAppMute
}

@MainActor
protocol HotkeyServiceProtocol: AnyObject {
    var isAvailable: Bool { get }
    func start()
    func stop()
    var handler: ((HotkeyAction) -> Void)? { get set }
}

@MainActor
final class NoopHotkeyService: HotkeyServiceProtocol {
    var isAvailable: Bool { false }
    var handler: ((HotkeyAction) -> Void)?
    func start() {}
    func stop() {}
}
