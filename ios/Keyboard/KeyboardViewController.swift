import ObjectiveC
import Observation
import SwiftUI
import UIKit

/// A keyboard with one big button. The microphone is the app's: the keyboard asks it over the Bridge
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
            host.view.heightAnchor.constraint(equalToConstant: 250),
        ])
        host.didMove(toParent: self)
        Bridge.observe(.state) { [weak self] in
            MainActor.assumeIsolated { self?.state.refresh() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.hasFullAccess = hasFullAccess
        state.showsGlobe = needsInputModeSwitchKey
        // Text meant for a field the keyboard has long left must not land in this one.
        _ = Bridge.takeResult()
        state.refresh()
        state.startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        state.stopPolling()
    }

    /// Joins the text to what is already typed with a space, unless the cursor already follows one.
    func insert(_ text: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let needsSpace = before.last.map { !$0.isWhitespace } ?? false
        textDocumentProxy.insertText(needsSpace ? " " + text : text)
    }

    /// Extensions may not open URLs, except through the application object at the end of the responder chain.
    func openApp() {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(method_getImplementation(method), to: Open.self)
                open(current, selector, Bridge.recordURL as NSURL, NSDictionary(), nil as AnyObject?)
                return
            }
            responder = current.next
        }
        state.notice = L("KeyboardOpenAppManually")
    }
}

@Observable
@MainActor
final class KeyboardState {
    @ObservationIgnored weak var controller: KeyboardViewController?
    @ObservationIgnored private var poller: Timer?

    var phase = Bridge.Phase.off
    var hasFullAccess = true
    var showsGlobe = true
    var notice: String?

    func refresh() {
        phase = Bridge.isAlive ? Bridge.phase : .off
        if let text = Bridge.takeResult() {
            controller?.insert(text)
            notice = nil
        }
        if let problem = Bridge.takeNotice() { notice = problem }
    }

    /// Darwin notifications cover the changes; this covers a session that died without saying so.
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

    func microphone() {
        guard hasFullAccess else {
            notice = L("KeyboardNeedsFullAccess")
            return
        }
        notice = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch phase {
        case .off: controller?.openApp()
        case .ready: Bridge.post(.start)
        case .recording: Bridge.post(.stop)
        case .sending: break
        }
    }

    func cancel() {
        if phase == .recording { Bridge.post(.cancel) }
    }

    func space() { controller?.textDocumentProxy.insertText(" ") }
    func newline() { controller?.textDocumentProxy.insertText("\n") }
    func delete() { controller?.textDocumentProxy.deleteBackward() }
    func nextKeyboard() { controller?.advanceToNextInputMode() }
}

struct KeyboardView: View {
    @Bindable var state: KeyboardState

    var body: some View {
        VStack(spacing: 12) {
            Text(state.notice ?? status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32)

            Button(action: state.microphone) {
                ZStack {
                    Circle().fill(color.gradient)
                    if state.phase == .sending {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: icon).font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 104, height: 104)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in state.cancel() })
            .accessibilityLabel(status)

            HStack(spacing: 8) {
                if state.showsGlobe { key("globe", action: state.nextKeyboard) }
                Button(action: state.space) {
                    Text(L("KeySpace"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                key("delete.left", action: state.delete)
                key("return", action: state.newline)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func key(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 52, height: 44)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        guard state.hasFullAccess else { return L("KeyboardNeedsFullAccess") }
        switch state.phase {
        case .off: return L("KeyboardStartSession")
        case .ready: return L("KeyboardTapToDictate")
        case .recording: return L("KeyboardTapToStop")
        case .sending: return L("StatusSending")
        }
    }

    private var icon: String {
        switch state.phase {
        case .off: "mic.badge.plus"
        case .ready: "mic.fill"
        case .recording: "stop.fill"
        case .sending: "waveform"
        }
    }

    private var color: Color {
        switch state.phase {
        case .off: .gray
        case .ready: .blue
        case .recording: .red
        case .sending: .orange
        }
    }
}
