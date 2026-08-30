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
    private var pollTask: Task<Void, Never>?
    /// Когда приложение из `onlyWhilePlaying` звучало в последний раз.
    private var lastPlayed: [String: Date] = [:]
    private var graceTask: Task<Void, Never>?

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
        startPolling()
    }

    /// Периодический опрос вдобавок к нотификациям.
    ///
    /// На нотификацию kAudioProcessPropertyIsRunningOutput полагаться нельзя:
    /// проверено — QuickLookUIService (быстрый просмотр видео от Finder) уже
    /// звучал, а приложение продолжало считать, что со звуком никого нет.
    /// Нотификации приходят на появление и исчезновение процессов, а вот
    /// «этот начал играть» доезжает не всегда.
    ///
    /// Опрос дешёвый: два десятка чтений свойств раз в две секунды — доли
    /// микросекунды на фоне работающего IOProc.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        listObserver = nil
        runningObservers.removeAll()
        refreshTask?.cancel()
        graceTask?.cancel()
        pollTask?.cancel()
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
            seen.insert(objectID)

            // Слушателя вешаем на ВСЕ процессы, а не только на попавшие в
            // список. Иначе о том, что скрытый процесс начал играть, сообщить
            // некому — и он так и не появится: ровно так пропадал Finder с
            // быстрым просмотром видео.
            if runningObservers[objectID] == nil {
                runningObservers[objectID] = AudioPropertyObserver(
                    objectID: objectID,
                    property: AudioProperty(kAudioProcessPropertyIsRunningOutput)
                ) { [weak self] in
                    Task { @MainActor in self?.scheduleRefresh() }
                }
            }

            guard let info = makeInfo(objectID: objectID) else { continue }
            result.append(info)
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

        scheduleGraceExpiry(for: result)

        guard result != processes else { return }
        processes = result
    }

    /// Системные агенты, которые звучат исключительно служебными сигналами:
    /// щелчок регулятора громкости, звук подключения питания, звуки входа
    /// в систему. Не показываем их никогда — даже пока они звучат.
    ///
    /// Общего правила «фоновый агент виден, пока звучит» здесь мало: щелчок
    /// Пункта управления раздаётся ровно в момент, когда пользователь крутит
    /// системную громкость, поэтому строка выскакивала именно тогда, когда
    /// мешает больше всего.
    ///
    /// Дело не только в мусоре в списке. Этот щелчок — то, по чему громкость
    /// оценивают на слух. Приглушив его отдельно, пользователь получил бы
    /// неверный ориентир: система играет громко, а подтверждение тихое.
    private static let neverShow: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.PowerChime",
        "com.apple.loginwindow",
        "com.apple.systemuiserver"
    ]

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

    /// Сколько такое приложение остаётся в списке после того, как замолчало.
    ///
    /// Исчезать сразу нельзя: видео в быстром просмотре ставят на паузу,
    /// перематывают и запускают снова, а строка в этот момент пропадала бы
    /// из-под курсора.
    private static let lingerAfterPlaying: TimeInterval = 180

    private func isWithinGrace(_ bundleID: String) -> Bool {
        guard let played = lastPlayed[bundleID] else { return false }
        return Date().timeIntervalSince(played) < Self.lingerAfterPlaying
    }

    /// Строка, оставленная «на отсрочке», сама по себе не исчезнет: нотификаций
    /// больше не будет, приложение уже молчит. Поэтому будим себя к сроку.
    private func scheduleGraceExpiry(for result: [AudioProcessInfo]) {
        graceTask?.cancel()

        let deadlines = result
            .filter { !$0.isRunningOutput && Self.onlyWhilePlaying.contains($0.bundleID) }
            .compactMap { lastPlayed[$0.bundleID] }
            .map { $0.addingTimeInterval(Self.lingerAfterPlaying) }

        guard let nearest = deadlines.min() else { return }
        let delay = max(nearest.timeIntervalSinceNow, 0.5)

        graceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    private func makeInfo(objectID: AudioObjectID) -> AudioProcessInfo? {
        // PID может исчезнуть между получением списка и чтением свойств —
        // это нормальная гонка, просто пропускаем процесс.
        guard let pid: pid_t = try? objectID.read(
            AudioProperty(kAudioProcessPropertyPID), defaultValue: pid_t(-1)
        ), pid > 0, pid != ownPID else { return nil }

        // Отсекаем системные хелперы без UI (coreaudiod, VTDecoderXPCService и т.п.):
        // у них нет NSRunningApplication, и показывать их пользователю бессмысленно.
        guard let owner = Self.owningApplication(for: pid),
              let bundleID = owner.app.bundleIdentifier,
              !Self.neverShow.contains(bundleID) else { return nil }

        let isRunning = ((try? objectID.read(
            AudioProperty(kAudioProcessPropertyIsRunningOutput), defaultValue: UInt32(0)
        )) ?? 0) != 0

        // Обычные приложения показываем всегда — им можно выставить громкость
        // заранее. Фоновых агентов (Пункт управления, PowerChime, MonitorControl,
        // loginwindow) — только пока они реально звучат: иначе они забивают
        // список тем, чем управлять незачем.
        if isRunning, Self.onlyWhilePlaying.contains(bundleID) {
            lastPlayed[bundleID] = .now
        }

        let alwaysVisible = owner.app.activationPolicy == .regular
            && !Self.onlyWhilePlaying.contains(bundleID)
        guard alwaysVisible || isRunning || isWithinGrace(bundleID) else { return nil }

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
