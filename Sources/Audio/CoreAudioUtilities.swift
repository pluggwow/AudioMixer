//
//  CoreAudioUtilities.swift
//  AudioMixer
//
//  Тонкая типобезопасная обёртка над AudioObjectGetPropertyData / SetPropertyData.
//  Нужна, чтобы остальной код не тонул в UnsafeMutablePointer и OSStatus.
//

import Foundation
import CoreAudio
import OSLog

// MARK: - Ошибки

enum CAError: LocalizedError {
    case status(OSStatus, String)
    case objectNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .status(code, context):
            return "\(context): OSStatus \(code) (\(code.fourCCDescription))"
        case let .objectNotFound(what):
            return "Core Audio object not found: \(what)"
        }
    }
}

@inline(__always)
func caCheck(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CAError.status(status, context()) }
}

// MARK: - Описание свойства

struct AudioProperty: Hashable {
    var selector: AudioObjectPropertySelector
    var scope: AudioObjectPropertyScope
    var element: AudioObjectPropertyElement

    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

// MARK: - Доступ к свойствам

extension AudioObjectID {

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func hasProperty(_ property: AudioProperty) -> Bool {
        var address = property.address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ property: AudioProperty) -> Bool {
        var address = property.address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func dataSize(_ property: AudioProperty,
                  qualifier: UnsafeRawPointer? = nil,
                  qualifierSize: UInt32 = 0) throws -> UInt32 {
        var address = property.address
        var size: UInt32 = 0
        try caCheck(
            AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qualifier, &size),
            "GetPropertyDataSize(\(property.selector.fourCCDescription))"
        )
        return size
    }

    /// Чтение POD-значения фиксированного размера (UInt32, Float32, pid_t, AudioObjectID, ASBD...).
    func read<T>(_ property: AudioProperty, defaultValue: T) throws -> T {
        var address = property.address
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        try caCheck(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
            },
            "GetPropertyData(\(property.selector.fourCCDescription))"
        )
        return value
    }

    /// Чтение массива POD-значений (список устройств, список процессов и т.д.).
    func readArray<T>(_ property: AudioProperty,
                      qualifier: UnsafeRawPointer? = nil,
                      qualifierSize: UInt32 = 0) throws -> [T] {
        var address = property.address
        var size = try dataSize(property, qualifier: qualifier, qualifierSize: qualifierSize)
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }

        let buffer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        try caCheck(
            AudioObjectGetPropertyData(self, &address, qualifierSize, qualifier, &size, buffer),
            "GetPropertyData array(\(property.selector.fourCCDescription))"
        )
        let actual = Int(size) / MemoryLayout<T>.stride
        // Swift.min, а не UInt32.min: в расширении AudioObjectID безымянный min —
        // это статическое свойство типа.
        return Array(UnsafeBufferPointer(start: buffer, count: Swift.min(actual, capacity)))
    }

    /// Чтение CFString-свойства (имя устройства, bundle ID процесса, UID).
    func readString(_ property: AudioProperty) throws -> String {
        var address = property.address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        try caCheck(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
            },
            "GetPropertyData string(\(property.selector.fourCCDescription))"
        )
        return (value as String?) ?? ""
    }

    /// Мягкий вариант — не бросает, возвращает nil.
    func readStringIfPresent(_ property: AudioProperty) -> String? {
        guard hasProperty(property) else { return nil }
        let value = try? readString(property)
        return (value?.isEmpty == false) ? value : nil
    }

    func write<T>(_ value: T, to property: AudioProperty) throws {
        var address = property.address
        var value = value
        try caCheck(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
            },
            "SetPropertyData(\(property.selector.fourCCDescription))"
        )
    }

    /// Запись CFArray (используется для kAudioAggregateDevicePropertyTapList).
    func writeArray(_ array: CFArray, to property: AudioProperty) throws {
        var address = property.address
        var value = array
        try caCheck(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0)
            },
            "SetPropertyData array(\(property.selector.fourCCDescription))"
        )
    }

    /// Сырое чтение в raw-буфер. Нужно для AudioBufferList (stream configuration),
    /// у которого размер известен только в рантайме.
    func readRaw(_ property: AudioProperty) throws -> UnsafeMutableRawBufferPointer {
        var address = property.address
        var size = try dataSize(property)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<UInt64>.alignment
        )
        do {
            try caCheck(
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!),
                "GetPropertyData raw(\(property.selector.fourCCDescription))"
            )
        } catch {
            buffer.deallocate()
            throw error
        }
        return buffer
    }
}

// MARK: - Наблюдение за свойствами (вместо polling)

/// RAII-обёртка над AudioObjectAddPropertyListenerBlock.
/// Слушатель снимается автоматически в deinit — это важно, иначе Core Audio
/// будет держать блок и дёргать его для уже уничтоженных объектов.
final class AudioPropertyObserver {

    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init?(objectID: AudioObjectID,
          property: AudioProperty,
          queue: DispatchQueue = .main,
          handler: @escaping () -> Void) {

        self.objectID = objectID
        self.address = property.address
        self.queue = queue

        let listener: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = listener

        let status = AudioObjectAddPropertyListenerBlock(objectID, &self.address, queue, listener)
        guard status == noErr else {
            self.block = nil
            return nil
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

// MARK: - Утилиты

extension OSStatus {
    /// Многие коды Core Audio — это four-char-code ('!obj', 'who?', 'nope').
    var fourCCDescription: String {
        let value = UInt32(bitPattern: self)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        guard printable else { return "\(self)" }
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
}

extension AudioObjectPropertySelector {
    var fourCCDescription: String { OSStatus(bitPattern: self).fourCCDescription }
}

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.AudioMixer"
    static let engine = Logger(subsystem: subsystem, category: "AudioEngine")
    static let processes = Logger(subsystem: subsystem, category: "Processes")
    static let devices = Logger(subsystem: subsystem, category: "Devices")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
}
