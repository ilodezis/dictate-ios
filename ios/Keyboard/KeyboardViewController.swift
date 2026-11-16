import ObjectiveC
import Observation
import SwiftUI
import UIKit

/// A keyboard with one button. The microphone is the app's: the keyboard asks it over the Bridge
/// and types what comes back.
final class KeyboardViewController: UIInputViewController {
    private let state = KeyboardState()

    override func viewDidLoad() {
        super.viewDidLoad()
        state.controller = self
        let host = UIHostingController(rootView: KeyboardView(state: state))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 206),
        ])
        host.didMove(toParent: self)
        Bridge.observe(.state) { [weak self] in
            MainActor.assumeIsolated { self?.state.refresh() }
        }
        Bridge.observeLevel { [weak self] level in
            MainActor.assumeIsolated {
                guard let state = self?.state, state.phase == .recording else { return }
                state.level = level
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.hasFullAccess = hasFullAccess
        state.showsGlobe = needsInputModeSwitchKey
        if hasFullAccess, !Bridge.keyboardSeen {
            Bridge.keyboardSeen = true
            Bridge.post(.keyboard)
        }
        // Text meant for a field the keyboard has long left must not land in this one.
        _ = Bridge.takeResult()
        state.refresh()
        state.startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        state.stopPolling()
        state.stopDeleting()
    }

    /// Joins the text to what is already typed with a space, unless the cursor already follows one.
    func insert(_ text: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let needsSpace = before.last.map { !$0.isWhitespace } ?? false
        textDocumentProxy.insertText(needsSpace ? " " + text : text)
    }

    /// Extensions may not open URLs, except through the application object at the end of the responder chain.
    @discardableResult
    func open(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(method_getImplementation(method), to: Open.self)
                open(current, selector, url as NSURL, NSDictionary(), nil as AnyObject?)
                return true
            }
            responder = current.next
        }
        return false
    }
}

@Observable
@MainActor
final class KeyboardState {
    @ObservationIgnored weak var controller: KeyboardViewController?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var deleter: Timer?
    @ObservationIgnored private var deletes = 0

    var phase = Bridge.Phase.off
    var recordingStarted = Date()
    /// 0...1 from the app while recording.
    var level: Float = 0
    /// Flashes a tick on the button when the text has landed.
    var typed = false
    var hasFullAccess = true
    var showsGlobe = false
    var notice: String?

    func refresh() {
        let new = Bridge.isAlive ? Bridge.phase : .off
        if new == .recording, phase != .recording {
            recordingStarted = Date()
            level = 0
        }
        if new != phase {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { phase = new }
        }
        if let text = Bridge.takeResult() {
            controller?.insert(text)
            notice = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { typed = true }
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeOut(duration: 0.25)) { typed = false }
            }
        }
        if let problem = Bridge.takeNotice() { show(problem) }
    }

    /// Darwin notifications cover the changes; this covers an app that died without saying so.
    func startPolling() {
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == text { withAnimation(.snappy) { notice = nil } }
        }
    }

    func microphone() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch phase {
        case .off:
            // The microphone is off and only the app can turn it on from here.
            if controller?.open(Bridge.recordURL) != true { show(L("KeyboardOpenAppManually")) }
        case .ready: Bridge.post(.start)
        case .recording: Bridge.post(.stop)
        case .sending: break
        }
    }

    func cancel() {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Bridge.post(.cancel)
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { controller?.open(url) }
    }

    func space() { tap { $0.insertText(" ") } }
    func newline() { tap { $0.insertText("\n") } }
    func nextKeyboard() { controller?.advanceToNextInputMode() }

    private func tap(_ action: (UITextDocumentProxy) -> Void) {
        guard let proxy = controller?.textDocumentProxy else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action(proxy)
    }

    // MARK: - Delete with repeat

    /// Like the system key: one character, then repeating after a pause, then whole words.
    func startDeleting() {
        guard deleter == nil else { return }
        deletes = 0
        deleteOnce()
        deleter = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatCharacters() }
        }
    }

    func stopDeleting() {
        deleter?.invalidate()
        deleter = nil
    }

    private func repeatCharacters() {
        deleter = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deletes += 1
                if self.deletes > 15 { self.repeatWords() } else { self.deleteOnce() }
            }
        }
    }

    /// A long hold: whole words, slower.
    private func repeatWords() {
        deleter?.invalidate()
        deleter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.deleteWord() }
        }
    }

    private func deleteOnce() {
        tap { $0.deleteBackward() }
    }

    private func deleteWord() {
        guard let proxy = controller?.textDocumentProxy else { return }
        var chars = Array(proxy.documentContextBeforeInput ?? "")
        var count = 0
        while let last = chars.last, last.isWhitespace { chars.removeLast(); count += 1 }
        while let last = chars.last, !last.isWhitespace { chars.removeLast(); count += 1 }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        for _ in 0..<max(count, 1) { proxy.deleteBackward() }
    }
}

struct KeyboardView: View {
    @Bindable var state: KeyboardState

    var body: some View {
        if state.hasFullAccess {
            keyboard
        } else {
            VStack(spacing: 14) {
                Text(L("KeyboardNeedsFullAccess"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button(L("OpenSettings"), action: state.openSettings)
                    .buttonStyle(.borderedProminent)
                if state.showsGlobe {
                    Key(symbol: "globe", width: 50, action: state.nextKeyboard)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var keyboard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                ZStack {
                    if state.phase == .recording {
                        Button(action: state.cancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 50, height: 44)
                        }
                        .buttonStyle(KeyStyle())
                        .accessibilityLabel(L("KeyboardCancel"))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .frame(width: 50)
                Spacer()
                MicButton(state: state)
                Spacer()
                DeleteKey(state: state)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let notice = state.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            HStack(spacing: 6) {
                if state.showsGlobe { Key(symbol: "globe", width: 50, action: state.nextKeyboard) }
                Button(action: state.space) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(KeyStyle())
                .accessibilityLabel(L("KeySpace"))
                Key(symbol: "return", width: 88, action: state.newline)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// The one button: off (opens the app to turn the microphone on), ready, recording, sending.
/// While recording, a ring follows the voice and a timer runs under it.
private struct MicButton: View {
    @Bindable var state: KeyboardState
    @State private var spin = false

    var body: some View {
        Button(action: state.microphone) {
            ZStack {
                if state.phase == .recording {
                    // Slow breathing underneath, the voice on top of it.
                    Breathing()
                    Circle()
                        .fill(Color.red.opacity(0.28))
                        .scaleEffect(1 + CGFloat(state.level) * 0.32)
                        .animation(.spring(response: 0.14, dampingFraction: 0.6), value: state.level)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if state.phase == .sending {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .padding(-6)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                        .onDisappear { spin = false }
                }
                Circle().fill(fill)
                content
                    .id(contentID)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            .frame(width: 92, height: 92)
            .contentShape(.circle)
        }
        .buttonStyle(PressStyle())
        .disabled(state.phase == .sending)
        .accessibilityLabel(label)
        .overlay(alignment: .bottom) {
            if state.phase == .recording {
                Text(timerInterval: state.recordingStarted...Date.distantFuture, countsDown: false)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize()
                    .offset(y: 22)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var contentID: String { state.typed ? "typed" : state.phase.rawValue }

    @ViewBuilder private var content: some View {
        if state.typed {
            Image(systemName: "checkmark").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
        } else {
            switch state.phase {
            case .off:
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            case .recording:
                RoundedRectangle(cornerRadius: 7).fill(.white).frame(width: 28, height: 28)
            case .sending:
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
    }

    private var fill: AnyShapeStyle {
        if state.typed { return AnyShapeStyle(Color.green.gradient) }
        switch state.phase {
        case .off: return AnyShapeStyle(Color.primary.opacity(0.12))
        case .ready: return AnyShapeStyle(Color.accentColor.gradient)
        case .recording: return AnyShapeStyle(Color.red.gradient)
        case .sending: return AnyShapeStyle(Color.accentColor.opacity(0.7).gradient)
        }
    }

    private var label: String {
        switch state.phase {
        case .off: L("KeyboardMicOff")
        case .ready: L("KeyboardDictate")
        case .recording: L("KeyboardStop")
        case .sending: L("StatusSending")
        }
    }
}

/// A soft red halo that breathes while recording, even through silence.
private struct Breathing: View {
    @State private var out = false

    var body: some View {
        Circle()
            .fill(Color.red.opacity(0.16))
            .scaleEffect(out ? 1.24 : 1.04)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: out)
            .onAppear { out = true }
    }
}

/// Squeezes a little under the finger and springs back.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// A key: lights up and dips while held.
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(KeyBackground(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct DeleteKey: View {
    let state: KeyboardState
    @State private var pressed = false

    var body: some View {
        Image(systemName: pressed ? "delete.left.fill" : "delete.left")
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: 19))
            .frame(width: 50, height: 44)
            .background(KeyBackground(pressed: pressed))
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        state.startDeleting()
                    }
                    .onEnded { _ in
                        pressed = false
                        state.stopDeleting()
                    }
            )
            .accessibilityLabel(L("KeyDelete"))
            .accessibilityAddTraits(.isButton)
    }
}

private struct Key: View {
    let symbol: String
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: width, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(KeyStyle())
    }
}

/// The system key look: white keys on light, translucent grey on dark.
private struct KeyBackground: View {
    var pressed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(pressed ? 0.12 : 0.28) : Color.white.opacity(pressed ? 0.6 : 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.18), radius: 0, x: 0, y: 1)
    }
}
