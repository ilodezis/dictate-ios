import ActivityKit
import AVFoundation
import Observation
import os
import UIKit
import WidgetKit

/// The whole client: the microphone held in the background, dictations, where the text goes.
@Observable
@MainActor
final class Dictation {
    static let shared = Dictation()
    private let log = Logger(subsystem: "app.dictate", category: "session")
    static let historySize = 50
    /// Minutes without a dictation before the microphone is let go; 0 keeps it until turned off.
    static let holdChoices = [0, 5, 10, 30, 60]

    /// Where a dictation's text goes: into the field under the keyboard, or onto the clipboard.
    enum Target { case keyboard, clipboard }

    var phase = Bridge.Phase.off
    var level: Float = 0
    var recordingStarted = Date()
    /// The keyboard opened the app: show how to get back, until the app leaves the screen.
    var openedFromKeyboard = false
    var notice: String?
    var history = UserDefaults.standard.stringArray(forKey: "history") ?? [] {
        didSet { UserDefaults.standard.set(history, forKey: "history") }
    }
    var server = UserDefaults.standard.string(forKey: "server") ?? "" {
        didSet { UserDefaults.standard.set(server.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "server") }
    }
    var holdMinutes = UserDefaults.standard.object(forKey: "holdMinutes") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(holdMinutes, forKey: "holdMinutes") }
    }
    var onboarded = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    var hasToken = Keychain.token != nil
    var hasMicrophone = AVAudioApplication.shared.recordPermission == .granted
    var keyboardSeen = Bridge.keyboardSeen
    var failedCount = FailedStore.all().count
    var terms: [String] = []

    var hasServer: Bool { server.lowercased().hasPrefix("https://") }

    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private var lastUse = Date()
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var activity: Activity<DictateAttributes>?
    /// The user turned the microphone off: do not turn it back on by itself until the app is opened again.
    @ObservationIgnored private var heldOff = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var starting: Task<Bool, Never>?
    @ObservationIgnored private var levelPosted = Date.distantPast

    private init() {
        // A previous run may have died holding the microphone.
        Bridge.phase = .off
        Bridge.aliveUntil = .distantPast
        // Someone set up before onboarding existed.
        if !onboarded, hasServer, hasToken { onboarded = true }
        recorder.onLevel = { level in MainActor.assumeIsolated { Dictation.shared.heard(level) } }
        Bridge.observe(.start) { MainActor.assumeIsolated { Dictation.shared.startRecording() } }
        Bridge.observe(.stop) { MainActor.assumeIsolated { Dictation.shared.stopRecording(to: .keyboard) } }
        Bridge.observe(.cancel) { MainActor.assumeIsolated { Dictation.shared.cancelRecording() } }
        Bridge.observe(.keyboard) { MainActor.assumeIsolated { Dictation.shared.keyboardSeen = Bridge.keyboardSeen } }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 99
                Dictation.shared.log.notice("interruption type=\(type?.rawValue ?? 99, privacy: .public) reason=\(reason, privacy: .public)")
                if type == .began { Dictation.shared.interruptionBegan() } else { Dictation.shared.interruptionEnded() }
            }
        }
        // The old ones are gone with the process that started them.
        for old in Activity<DictateAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        loadVocabulary()
    }

    // MARK: - Microphone

    /// The app came to the screen: refresh what setup can see, and have the keyboard ready.
    func appeared() async {
        hasToken = Keychain.token != nil
        hasMicrophone = AVAudioApplication.shared.recordPermission == .granted
        keyboardSeen = Bridge.keyboardSeen
        heldOff = false
        if onboarded, hasMicrophone { await hold() }
    }

    func requestMicrophone() async {
        hasMicrophone = await AVAudioApplication.requestRecordPermission()
        if !hasMicrophone { notice = L("NoticeNoMicrophone") }
    }

    /// Turns the microphone on and keeps it, so the keyboard can dictate. Only works with the app on screen,
    /// or from an audio recording intent (Control Center, Action Button).
    @discardableResult
    func hold() async -> Bool {
        // Opening from the keyboard asks twice at once: the link and the app coming to the screen.
        if let starting { return await starting.value }
        if phase != .off {
            lastUse = Date()
            return true
        }
        let task = Task { await start() }
        starting = task
        let started = await task.value
        starting = nil
        return started
    }

    private func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else {
            hasMicrophone = false
            notice = L("NoticeNoMicrophone")
            return false
        }
        hasMicrophone = true
        do {
            try recorder.start()
        } catch {
            notice = L("NoticeMicrophoneFailed", error.localizedDescription)
            return false
        }
        notice = nil
        heldOff = false
        lastUse = Date()
        set(.ready)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Dictation.shared.beat() }
        }
        beat()
        return true
    }

    /// The off button, here, on the Live Activity and in Control Center.
    func turnOff() {
        heldOff = true
        resumeAfterInterruption = false
        release("turnOff")
    }

    private func release(_ reason: String) {
        log.notice("release: \(reason, privacy: .public) phase=\(self.phase.rawValue, privacy: .public)")
        if phase == .recording { stopRecording(to: .clipboard) }
        heartbeat?.invalidate()
        heartbeat = nil
        recorder.stop()
        Bridge.aliveUntil = .distantPast
        set(.off)
    }

    private func beat() {
        if phase == .ready, holdMinutes > 0, Date().timeIntervalSince(lastUse) > Double(holdMinutes * 60) {
            return release("idle")
        }
        Bridge.aliveUntil = Date().addingTimeInterval(6)
    }

    /// A call or Siri took the microphone. What was said so far is sent; the microphone comes back after, if it can.
    private func interruptionBegan() {
        guard phase != .off else { return }
        resumeAfterInterruption = true
        release("interruption")
    }

    private func interruptionEnded() {
        guard resumeAfterInterruption, !heldOff else { return }
        resumeAfterInterruption = false
        Task {
            if await !hold() { notice = L("NoticeInterrupted") }
        }
    }

    /// `dictate://record` from the keyboard when the microphone was off: turn it on and record for it right away.
    func open(_ url: URL) async {
        guard url.scheme == "dictate", url.host() == "record" else { return }
        openedFromKeyboard = true
        guard onboarded, await hold() else { return }
        startRecording()
    }

    // MARK: - Dictation

    /// The Action Button: start, or stop and copy.
    func toggle() async {
        switch phase {
        case .off: if await hold() { startRecording() }
        case .ready: startRecording()
        case .recording: stopRecording(to: .clipboard)
        case .sending: break
        }
    }

    /// Control Center: microphone on, or off.
    func toggleMicrophone() async {
        guard phase == .off else { return turnOff() }
        guard await hold() else { return }
        // iOS kills an audio recording intent that leaves the microphone on without a Live Activity.
        if activity == nil {
            let reason = activityFailure ?? "unknown"
            turnOff()
            notice = L("NoticeMicrophoneFailed", reason)
        }
    }

    /// Each buffer's level while recording; the keyboard animates with it, a few times a second is enough.
    private func heard(_ level: Float) {
        self.level = level
        guard Date().timeIntervalSince(levelPosted) > 0.066 else { return }
        levelPosted = Date()
        Bridge.postLevel(min(level * 6, 1))
    }

    func startRecording() {
        guard phase == .ready else { return }
        lastUse = Date()
        recordingStarted = Date()
        level = 0
        do {
            try recorder.begin()
        } catch {
            notice = L("NoticeMicrophoneFailed", error.localizedDescription)
            return
        }
        set(.recording)
    }

    /// The text goes to whoever stopped the recording: the keyboard types it, anything else copies it.
    func stopRecording(to target: Target) {
        guard phase == .recording else { return }
        let samples = recorder.end()
        let sampleRate = recorder.sampleRate
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
            return settle(L("NoticeEncodeFailed"), shown: "failed")
        }
        do {
            let text = try await Transcriber.current().send(audio)
            guard !text.isEmpty else { return settle(nil) }
            remember(text)
            switch target {
            case .keyboard: Bridge.deliver(text)
            case .clipboard: UIPasteboard.general.string = text
            }
            settle(nil, shown: target == .clipboard ? "copied" : "done")
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

    /// Back to waiting for the next dictation, unless the microphone was turned off meanwhile.
    private func settle(_ problem: String?, shown: String? = nil) {
        if let problem {
            notice = problem
            Bridge.report(problem)
        }
        guard phase == .sending else { return Bridge.post(.state) }
        set(.ready, shown: shown)
        guard shown != nil else { return }
        // The result stays on the Live Activity for a moment, then it is plain "ready" again.
        Task {
            try? await Task.sleep(for: .seconds(shown == "failed" ? 4 : 2))
            if phase == .ready { showActivity(Bridge.Phase.ready.rawValue) }
        }
    }

    private func remember(_ text: String) {
        history.insert(text, at: 0)
        if history.count > Self.historySize { history.removeLast(history.count - Self.historySize) }
    }

    func forget(_ offsets: IndexSet) {
        history.remove(atOffsets: offsets)
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func saveToken(_ token: String) {
        Keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        hasToken = Keychain.token != nil
        loadVocabulary()
    }

    // MARK: - Phase and Live Activity

    private func set(_ new: Bridge.Phase, shown: String? = nil) {
        let switched = (phase == .off) != (new == .off)
        phase = new
        Bridge.phase = new
        Bridge.post(.state)
        if new == .off { endActivity() } else { showActivity(shown ?? new.rawValue) }
        if switched { ControlCenter.shared.reloadControls(ofKind: Bridge.controlKind) }
    }

    /// Why the Live Activity did not start; nil while it runs.
    private var activityFailure: String?

    private func showActivity(_ shown: String) {
        let state = DictateAttributes.ContentState(phase: shown, since: phase == .recording ? recordingStarted : Date())
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activityFailure = "Live Activities are disabled"
            return
        }
        do {
            activity = try Activity.request(attributes: DictateAttributes(), content: content)
            activityFailure = nil
        } catch {
            activityFailure = String(describing: error)
            Logger(subsystem: "app.dictate", category: "activity").error("Activity.request failed: \(error)")
        }
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
