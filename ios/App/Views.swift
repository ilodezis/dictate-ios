import SwiftUI
import UIKit

struct RootView: View {
    @Bindable var model: Dictation

    var body: some View {
        if !model.onboarded {
            OnboardingView(model: model)
        } else if model.openedFromKeyboard {
            BackView(model: model)
        } else {
            MainView(model: model)
        }
    }
}

// MARK: - Main screen

struct MainView: View {
    @Bindable var model: Dictation
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusRow(model: model)
                }

                if model.failedCount > 0 {
                    Section {
                        Button(L("RetryFailed", model.failedCount)) { model.retryFailed() }
                    }
                }

                if let notice = model.notice {
                    Section { Text(notice).foregroundStyle(.secondary) }
                }

                Section(L("History")) {
                    if model.history.isEmpty {
                        Text(L("HistoryEmpty")).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in
                        Button {
                            model.copy(text)
                            showCopied()
                        } label: {
                            Text(text).lineLimit(4).foregroundStyle(.primary)
                        }
                    }
                    .onDelete(perform: model.forget)
                }
            }
            .navigationTitle(L("AppName"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        DictionaryView(model: model)
                    } label: {
                        Image(systemName: "character.book.closed")
                    }
                    .accessibilityLabel(L("Dictionary"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(L("Settings"))
                }
            }
            .overlay(alignment: .bottom) {
                if copied {
                    Text(L("Copied"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glassEffect()
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func showCopied() {
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.snappy) { copied = false }
        }
    }
}

/// What the microphone is doing, and the one switch for it.
private struct StatusRow: View {
    @Bindable var model: Dictation

    var body: some View {
        HStack(spacing: 14) {
            PhaseBadge(phase: model.phase, level: model.level)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if model.phase == .recording {
                    Text(model.recordingStarted, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if model.phase == .ready, model.holdMinutes > 0 {
                    Text(L("StatusOffAfter", model.holdMinutes))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.phase == .off {
                Button(L("TurnOn")) { Task { await model.hold() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(L("TurnOff")) { model.turnOff() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        switch model.phase {
        case .off: L("StatusOff")
        case .ready: L("StatusReady")
        case .recording: L("StatusRecording")
        case .sending: L("StatusSending")
        }
    }
}

struct PhaseBadge: View {
    let phase: Bridge.Phase
    let level: Float

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.15))
            if phase == .recording {
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 3)
                    .scaleEffect(1 + CGFloat(min(level * 8, 0.3)))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
            if phase == .sending {
                ProgressView()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 46, height: 46)
    }

    private var symbol: String {
        switch phase {
        case .off: "mic.slash.fill"
        case .ready: "mic.fill"
        case .recording: "waveform"
        case .sending: "waveform"
        }
    }

    private var color: Color {
        switch phase {
        case .off: .secondary
        case .ready: .green
        case .recording: .red
        case .sending: .orange
        }
    }
}

// MARK: - Opened from the keyboard

/// The keyboard had to open the app to turn the microphone on. The only thing to do here is to go back.
struct BackView: View {
    @Bindable var model: Dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "arrow.up.backward")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.tint)
            Text(L("BackTitle"))
                .font(.largeTitle.bold())
            Text(L("BackHow"))
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 12) {
                PhaseBadge(phase: model.phase, level: model.level)
                if model.phase == .recording {
                    Text(model.recordingStarted, style: .timer)
                        .font(.title2.monospacedDigit())
                } else {
                    Text(model.phase == .off ? L("StatusOff") : L("StatusReady"))
                        .font(.headline)
                }
                Spacer()
                Button(L("BackStay")) { model.openedFromKeyboard = false }
            }
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - First run

struct OnboardingView: View {
    @Bindable var model: Dictation
    @State private var trial = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ServerFields(model: model)
                } header: {
                    StepHeader(title: L("Server"), done: model.hasServer && model.hasToken)
                }

                Section {
                    if model.hasMicrophone {
                        Text(L("MicrophoneAllowed")).foregroundStyle(.secondary)
                    } else {
                        Button(L("MicrophoneAllow")) { Task { await model.requestMicrophone() } }
                    }
                } header: {
                    StepHeader(title: L("Microphone"), done: model.hasMicrophone)
                }

                Section {
                    KeyboardSteps()
                    TextField(L("KeyboardTryHere"), text: $trial)
                } header: {
                    StepHeader(title: L("Keyboard"), done: model.keyboardSeen)
                } footer: {
                    Text(L("KeyboardTryHint"))
                }

                Section {
                    Button(L("OnboardingDone")) {
                        model.onboarded = true
                        Task { await model.appeared() }
                    }
                    .disabled(!(model.hasServer && model.hasToken && model.hasMicrophone))
                }
            }
            .navigationTitle(L("AppName"))
        }
    }
}

private struct StepHeader: View {
    let title: String
    let done: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }
}

private struct KeyboardSteps: View {
    var body: some View {
        Text(L("KeyboardSetup"))
        Button(L("OpenSettings")) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}

/// Server address and token, in setup and in Settings.
private struct ServerFields: View {
    @Bindable var model: Dictation
    @State private var token = ""

    var body: some View {
        TextField(L("ServerPlaceholder"), text: $model.server)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        HStack {
            SecureField(model.hasToken ? L("TokenSaved") : L("TokenPlaceholder"), text: $token)
                .onSubmit(save)
            if !token.isEmpty {
                Button(L("TokenSave"), action: save)
            }
        }
    }

    private func save() {
        guard !token.isEmpty else { return }
        model.saveToken(token)
        token = ""
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @Bindable var model: Dictation
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(L("TermPlaceholder"), text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button(L("TermAdd"), action: add)
                        .disabled(Dictation.parseTerms(draft) == nil)
                }
            } footer: {
                Text(L("TermHint"))
            }
            Section(L("TermsCount", model.terms.count)) {
                ForEach(model.terms, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        let gone = offsets.map { model.terms[$0] }
                        gone.forEach(model.removeTerm)
                    }
            }
        }
        .navigationTitle(L("Dictionary"))
        .onAppear { model.loadVocabulary() }
    }

    private func add() {
        guard let parts = Dictation.parseTerms(draft) else { return }
        model.addTerms(parts)
        draft = ""
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable var model: Dictation

    var body: some View {
        Form {
            Section(L("Server")) {
                ServerFields(model: model)
            }

            Section(L("Microphone")) {
                Picker(L("TurnOffAfter"), selection: $model.holdMinutes) {
                    ForEach(Dictation.holdChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? L("Never") : L("Minutes", minutes)).tag(minutes)
                    }
                }
            }

            Section(L("Keyboard")) {
                KeyboardSteps()
            }

            Section {
                Text(L("ControlCenterSetup"))
                Text(L("ActionButtonSetup"))
            } header: {
                Text(L("WithoutApp"))
            }
        }
        .navigationTitle(L("Settings"))
    }
}
