import ActivityKit
import AVFoundation
import Observation
import UIKit

/// The whole client: one session that holds the microphone, dictations inside it, where the text goes.
@Observable
@MainActor
final class Dictation {
    static let shared = Dictation()
    static let historySize = 50
    static let sessionChoices = [5, 10, 30, 60]

    /// Where a dictation's text goes: into the field under the keyboard, or onto the clipboard.
    enum Target { case keyboard, clipboard }

    var phase = Bridge.Phase.off
    var level: Float = 0
    var recordingStarted = Date()
    /// The keyboard opened the app: show how to get back.
    var openedFromKeyboard = false
    var notice: String?
    var lastText: String?
    var history = UserDefaults.standard.stringArray(forKey: "history") ?? [] {
        didSet { UserDefaults.standard.set(history, forKey: "history") }
    }
    var server = UserDefaults.standard.string(forKey: "server") ?? "" {
        didSet { UserDefaults.standard.set(server.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "server") }
    }
    /// Minutes without a dictation before the session lets the microphone go.
    var sessionMinutes = UserDefaults.standard.object(forKey: "sessionMinutes") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(sessionMinutes, forKey: "sessionMinutes") }
    }
    var hasToken = Keychain.token != nil
    var failedCount = FailedStore.all().count
    var terms: [String] = []

    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private var target = Target.clipboard
    @ObservationIgnored private var lastUse = Date()
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var activity: Activity<DictateAttributes>?

    private init() {
        // A previous run may have died mid-session.
        Bridge.phase = .off
        Bridge.aliveUntil = .distantPast
        recorder.onLevel = { level in MainActor.assumeIsolated { Dictation.shared.level = level } }
        Bridge.observe(.start) { MainActor.assumeIsolated { Dictation.shared.startRecording(for: .keyboard) } }
        Bridge.observe(.stop) { MainActor.assumeIsolated { Dictation.shared.stopRecording() } }
        Bridge.observe(.cancel) { MainActor.assumeIsolated { Dictation.shared.cancelRecording() } }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { if began { Dictation.shared.interrupted() } }
        }
        // The old ones for this session are gone with the process that started them.
        for old in Activity<DictateAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        loadVocabulary()
    }

    // MARK: - Session

    @discardableResult
    func startSession() async -> Bool {
        if phase != .off {
            lastUse = Date()
            return true
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            notice = L("NoticeNoMicrophone")
            return false
        }
        do {
            try recorder.start()
        } catch {
            notice = L("NoticeMicrophoneFailed", error.localizedDescription)
            return false
        }
        notice = nil
        lastUse = Date()
        set(.ready)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Dictation.shared.beat() }
        }
        beat()
        return true
    }

    func endSession() {
        if phase == .recording { stopRecording() }
        heartbeat?.invalidate()
        heartbeat = nil
        recorder.stop()
        Bridge.aliveUntil = .distantPast
        openedFromKeyboard = false
        set(.off)
    }

    private func beat() {
        if phase == .ready, Date().timeIntervalSince(lastUse) > Double(sessionMinutes * 60) { return endSession() }
        Bridge.aliveUntil = Date().addingTimeInterval(6)
    }

    private func interrupted() {
        guard phase != .off else { return }
        notice = L("NoticeInterrupted")
        endSession()
    }

    /// `dictate://session?record=1` from the keyboard: start a session and record for it right away.
    func open(_ url: URL) async {
        guard url.scheme == "dictate", url.host() == "session" else { return }
        openedFromKeyboard = true
        guard await startSession() else { return }
        if url.query()?.contains("record=1") == true { startRecording(for: .keyboard) }
    }

    // MARK: - Dictation

    /// The Action Button and the button in the app: start, or stop and copy.
    func toggle() async {
        switch phase {
        case .off: if await startSession() { startRecording(for: .clipboard) }
        case .ready: startRecording(for: .clipboard)
        case .recording: stopRecording()
        case .sending: break
        }
    }

    func startRecording(for target: Target) {
        guard phase == .ready else { return }
        self.target = target
        lastUse = Date()
        recordingStarted = Date()
        level = 0
        recorder.begin()
        set(.recording)
    }

    func stopRecording() {
        guard phase == .recording else { return }
        let samples = recorder.end()
        let sampleRate = recorder.sampleRate
        let target = self.target
        lastUse = Date()
        set(.sending)
        Task { await finish(samples, sampleRate: sampleRate, target: target) }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        _ = recorder.end()
        set(.ready)
    }

    private func finish(_ samples: [Float], sampleRate: Double, target: Target) async {
        let speech = trimSilence(samples, sampleRate: sampleRate)
        // A tap with nothing said is not a dictation.
        guard Double(speech.count) / sampleRate >= 0.3 else { return settle(nil) }
        let audio: Data
        do {
            audio = try Encoder.m4a(speech, sampleRate: sampleRate)
        } catch {
            return settle(L("NoticeEncodeFailed"))
        }
        do {
            let text = try await Transcriber.current().send(audio)
            guard !text.isEmpty else { return settle(nil) }
            remember(text)
            switch target {
            case .keyboard: Bridge.deliver(text)
            case .clipboard: UIPasteboard.general.string = text
            }
            settle(nil, shown: "done")
        } catch {
            // Invariant: a dictation is never lost. The audio waits for "Send again".
            do {
                try FailedStore.save(audio)
                failedCount = FailedStore.all().count
                settle(L("NoticeSaved", error.localizedDescription), shown: "failed")
            } catch {
                settle(L("NoticeLost", error.localizedDescription), shown: "failed")
            }
        }
    }

    /// Back to waiting for the next dictation, unless the session ended meanwhile.
    private func settle(_ problem: String?, shown: String? = nil) {
        if let problem {
            notice = problem
            Bridge.report(problem)
        }
        if phase == .sending { set(.ready, shown: shown) } else { Bridge.post(.state) }
    }

    private func remember(_ text: String) {
        lastText = text
        history.insert(text, at: 0)
        if history.count > Self.historySize { history.removeLast(history.count - Self.historySize) }
    }

    func retryFailed() {
        Task {
            var last: String?
            for file in FailedStore.all() {
                do {
                    let text = try await Transcriber.current().send(Data(contentsOf: file))
                    if !text.isEmpty {
                        remember(text)
                        last = text
                    }
                    try? FileManager.default.removeItem(at: file)
                } catch {
                    failedCount = FailedStore.all().count
                    notice = L("NoticeRetryFailed", error.localizedDescription)
                    return
                }
            }
            failedCount = FailedStore.all().count
            if let last { UIPasteboard.general.string = last }
            notice = L(last == nil ? "NoticeRetriedNoText" : "NoticeRetriedCopied")
        }
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    func saveToken(_ token: String) {
        Keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        hasToken = Keychain.token != nil
        loadVocabulary()
    }

    // MARK: - Phase and Live Activity

    private func set(_ new: Bridge.Phase, shown: String? = nil) {
        phase = new
        Bridge.phase = new
        Bridge.post(.state)
        if new == .off { endActivity() } else { showActivity(shown ?? new.rawValue) }
    }

    private func showActivity(_ shown: String) {
        let content = ActivityContent(state: DictateAttributes.ContentState(phase: shown, since: Date()), staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: DictateAttributes(), content: content)
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Dictionary

    /// Comma-separated words from the field; nil unless there is at least one and every one is a valid term.
    static func parseTerms(_ text: String) -> [String]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy(Vocabulary.isTerm) ? parts : nil
    }

    func loadVocabulary() {
        guard let worker = try? Transcriber.current() else { return }
        Task {
            // Offline: the screen just shows the last list it had.
            if let list = try? await worker.vocabulary("GET") { terms = list }
        }
    }

    func addTerms(_ parts: [String]) {
        Task {
            // One at a time: the worker rewrites the whole list on each call, parallel adds would drop words.
            for term in parts { await changeVocabulary("POST", term) }
        }
    }

    func removeTerm(_ term: String) {
        Task { await changeVocabulary("DELETE", term) }
    }

    private func changeVocabulary(_ method: String, _ term: String) async {
        do {
            terms = try await Transcriber.current().vocabulary(method, term: term)
            notice = L(method == "DELETE" ? "NoticeTermRemoved" : "NoticeTermAdded", term)
        } catch {
            notice = L("NoticeTermFailed", error.localizedDescription)
        }
    }
}
