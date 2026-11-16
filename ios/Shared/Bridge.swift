import CoreFoundation
import Foundation

/// What the app and the keyboard share. A keyboard extension cannot use the microphone, so it asks the app,
/// which keeps a recording session alive in the background, and gets the text back the same way:
/// state lives in the App Group defaults, Darwin notifications say "look again".
enum Bridge {
    static let groupID = (Bundle.main.object(forInfoDictionaryKey: "DictateAppGroup") as? String) ?? ""
    static let defaults = UserDefaults(suiteName: groupID) ?? .standard
    /// Opens the app, starts a session and records straight away for the keyboard.
    static let recordURL = URL(string: "dictate://session?record=1")!

    enum Phase: String {
        case off, ready, recording, sending
    }

    enum Signal: String {
        case start = "dictate.start", stop = "dictate.stop", cancel = "dictate.cancel", state = "dictate.state"
    }

    // MARK: - Signals

    private static var handlers: [String: () -> Void] = [:]
    private static let observer = NSObject()

    static func post(_ signal: Signal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(signal.rawValue as CFString), nil, nil, true)
    }

    /// Handlers run on the main thread; one per signal per process.
    static func observe(_ signal: Signal, _ handler: @escaping () -> Void) {
        let isNew = handlers[signal.rawValue] == nil
        handlers[signal.rawValue] = handler
        guard isNew else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(observer).toOpaque(),
            { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                DispatchQueue.main.async { Bridge.handlers[name]?() }
            },
            signal.rawValue as CFString, nil, .deliverImmediately)
    }

    // MARK: - State

    static var phase: Phase {
        get { Phase(rawValue: defaults.string(forKey: "phase") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "phase") }
    }

    /// The app pushes this forward while its session runs; a killed app simply stops pushing.
    static var aliveUntil: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "aliveUntil")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "aliveUntil") }
    }

    static var isAlive: Bool { phase != .off && aliveUntil > Date() }

    /// Text for the keyboard. Taken once; a stale one (the keyboard was gone) is dropped, never pasted later.
    static func deliver(_ text: String) {
        defaults.set(text, forKey: "result")
        defaults.set(Date().timeIntervalSince1970, forKey: "resultAt")
    }

    static func takeResult() -> String? {
        guard let text = defaults.string(forKey: "result") else { return nil }
        let age = Date().timeIntervalSince1970 - defaults.double(forKey: "resultAt")
        defaults.removeObject(forKey: "result")
        return age < 60 ? text : nil
    }

    /// A one-line problem report for the keyboard (the dictation itself is kept by the app).
    static func report(_ notice: String) {
        defaults.set(notice, forKey: "notice")
    }

    static func takeNotice() -> String? {
        defer { defaults.removeObject(forKey: "notice") }
        return defaults.string(forKey: "notice")
    }
}
