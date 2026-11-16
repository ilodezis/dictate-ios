import CoreFoundation
import Foundation
import notify

/// What the app and its extensions share. A keyboard extension cannot use the microphone, so it asks the app,
/// which keeps the microphone running in the background, and gets the text back the same way:
/// state lives in the App Group defaults, Darwin notifications say "look again".
enum Bridge {
    static let groupID = (Bundle.main.object(forInfoDictionaryKey: "DictateAppGroup") as? String) ?? ""
    static let defaults = UserDefaults(suiteName: groupID) ?? .standard
    /// Opens the app, which turns the microphone on and records straight away for the keyboard.
    static let recordURL = URL(string: "dictate://record")!
    /// The Control Center button.
    static let controlKind = "dictate.microphone"

    enum Phase: String {
        case off, ready, recording, sending
    }

    enum Signal: String {
        case start = "dictate.start", stop = "dictate.stop", cancel = "dictate.cancel", state = "dictate.state"
        /// The keyboard showed up with full access: setup in the app can tick it off.
        case keyboard = "dictate.keyboard"
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

    // MARK: - Level

    /// The voice level while recording, for the keyboard's animation: rides on the notification's own state,
    /// so fifteen updates a second do not touch the shared defaults.
    private static let levelName = "dictate.level"

    static func postLevel(_ level: Float) {
        var token: Int32 = 0
        guard notify_register_check(levelName, &token) == 0 else { return }
        notify_set_state(token, UInt64(max(0, min(level, 1)) * 10_000))
        notify_post(levelName)
        notify_cancel(token)
    }

    /// The handler gets 0...1 on the main queue.
    static func observeLevel(_ handler: @escaping (Float) -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(levelName, &token, .main) { token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            handler(Float(state) / 10_000)
        }
    }

    // MARK: - State

    static var phase: Phase {
        get { Phase(rawValue: defaults.string(forKey: "phase") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "phase") }
    }

    /// The app pushes this forward while it holds the microphone; a killed app simply stops pushing.
    static var aliveUntil: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "aliveUntil")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "aliveUntil") }
    }

    static var isAlive: Bool { phase != .off && aliveUntil > Date() }

    /// Set by the keyboard; it can only write here with full access, which is exactly what setup needs to know.
    static var keyboardSeen: Bool {
        get { defaults.bool(forKey: "keyboardSeen") }
        set { defaults.set(newValue, forKey: "keyboardSeen") }
    }

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
