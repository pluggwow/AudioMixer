//
//  AudioProcessMonitor.swift
//  AudioMixer
//
//  Перечисление аудио-процессов БЕЗ polling.
//  Подписываемся на kAudioHardwarePropertyProcessObjectList (появление/исчезновение)
//  и на kAudioProcessPropertyIsRunningOutput каждого процесса (начал/перестал играть).
//  В idle это стоит ровно ноль CPU.
//

import Foundation
import CoreAudio
import AppKit
import Combine

struct AudioProcessInfo: Identifiable, Hashable {
    let objectID: AudioObjectID
    /// PID процесса, который реально выводит звук. Именно на него ставится tap —
    /// у Safari это WebKit.GPU, а не сам Safari.
    let pid: pid_t
    /// PID приложения-владельца: с него берутся имя и иконка.
    let ownerPID: pid_t
    /// bundleID владельца, а не аудиопроцесса — под ним хранятся настройки.
    let bundleID: String
    var name: String
    var isRunningOutput: Bool

    var id: pid_t { pid }
}

@MainActor
final class AudioProcessMonitor: ObservableObject {

    @Published private(set) var processes: [AudioProcessInfo] = []

    private var listObserver: AudioPropertyObserver?
    private var runningObservers: [AudioObjectID: AudioPropertyObserver] = [:]
    private var refreshTask: Task<Void, Never>?

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Аудио выводят не сами приложения, а их хелперы: у Safari — WebKit.GPU
    /// («Safari Graphics and Media», без нормальной иконки), у Electron-программ —
    /// «… Helper». Показывать их как отдельные строки неправильно: пользователь
    /// видит две записи одного приложения и служебные имена.
    ///
    /// Система умеет отвечать, кто «ответственный» за процесс, — это ровно
    /// родительское приложение. Символ приватный, поэтому берём его через dlsym:
    /// если он когда-нибудь исчезнет, приложение просто откатится на сам процесс,
    /// а не упадёт при запуске.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Приложение-владелец аудиопроцесса.
    private static func owningApplication(for pid: pid_t) -> (app: NSRunningApplication, pid: pid_t)? {
        if let responsiblePID {
            let owner = responsiblePID(pid)
            if owner > 0, owner != pid, let app = NSRunningApplication(processIdentifier: owner) {
                return (app, owner)
            }
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return (app, pid)
    }

    func start() {
        listObserver = AudioPropertyObserver(
            objectID: .system,
            property: AudioProperty(kAudioHardwarePropertyProcessObjectList)
        ) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
    }

    func stop() {
        listObserver = nil
        runningObservers.removeAll()
        refreshTask?.cancel()
    }

    /// Небольшая коалесценция: при запуске приложения Core Audio может прислать
    /// несколько нотификаций подряд. Нет смысла перестраивать список на каждую.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    func refresh() {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try AudioObjectID.system.readArray(
                AudioProperty(kAudioHardwarePropertyProcessObjectList)
            )
        } catch {
            AppLog.processes.error("Process list read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        var result: [AudioProcessInfo] = []
        var seen = Set<AudioObjectID>()

        for objectID in objectIDs {
            guard let info = makeInfo(objectID: objectID) else { continue }
            seen.insert(objectID)
            result.append(info)

            // Подписка на «начал/перестал выводить звук».
            if runningObservers[objectID] == nil {
                runningObservers[objectID] = AudioPropertyObserver(
                    objectID: objectID,
                    property: AudioProperty(kAudioProcessPropertyIsRunningOutput)
                ) { [weak self] in
                    Task { @MainActor in self?.scheduleRefresh() }
                }
            }
        }

        // Снимаем слушателей с исчезнувших процессов.
        for key in runningObservers.keys where !seen.contains(key) {
            runningObservers.removeValue(forKey: key)
        }

        // Активные сверху, дальше по алфавиту — список не должен «прыгать».
        result.sort {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        guard result != processes else { return }
        processes = result
    }

    /// Обычные приложения, которым место в списке только пока они звучат.
    ///
    /// Finder держит аудиоклиент постоянно — ради системных звуков и
    /// предпросмотра, — но собственного звука, которым хотелось бы управлять,
    /// у него нет. По общему правилу он попадал в список навсегда, потому что
    /// это `.regular` приложение с иконкой в Dock. Здесь исключение, а не
    /// чёрный список: если Finder всё-таки заиграет (быстрый просмотр видео),
    /// строка появится, и громкость ему выставить можно.
    private static let onlyWhilePlaying: Set<String> = [
        "com.apple.finder"
    ]

    private func makeInfo(objectID: AudioObjectID) -> AudioProcessInfo? {
        // PID может исчезнуть между получением списка и чтением свойств —
        // это нормальная гонка, просто пропускаем процесс.
        guard let pid: pid_t = try? objectID.read(
            AudioProperty(kAudioProcessPropertyPID), defaultValue: pid_t(-1)
        ), pid > 0, pid != ownPID else { return nil }

        // Отсекаем системные хелперы без UI (coreaudiod, VTDecoderXPCService и т.п.):
        // у них нет NSRunningApplication, и показывать их пользователю бессмысленно.
        guard let owner = Self.owningApplication(for: pid),
              let bundleID = owner.app.bundleIdentifier else { return nil }

        let isRunning = ((try? objectID.read(
            AudioProperty(kAudioProcessPropertyIsRunningOutput), defaultValue: UInt32(0)
        )) ?? 0) != 0

        // Обычные приложения показываем всегда — им можно выставить громкость
        // заранее. Фоновых агентов (Пункт управления, PowerChime, MonitorControl,
        // loginwindow) — только пока они реально звучат: иначе они забивают
        // список тем, чем управлять незачем.
        let alwaysVisible = owner.app.activationPolicy == .regular
            && !Self.onlyWhilePlaying.contains(bundleID)
        guard alwaysVisible || isRunning else { return nil }

        return AudioProcessInfo(
            objectID: objectID,
            pid: pid,
            ownerPID: owner.pid,
            bundleID: bundleID,
            name: owner.app.localizedName ?? bundleID,
            isRunningOutput: isRunning
        )
    }
}
