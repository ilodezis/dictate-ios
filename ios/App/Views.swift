import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var model: Dictation

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SessionRow(model: model)
                } footer: {
                    if model.openedFromKeyboard && model.phase != .off { Text(L("HintSwipeBack")) }
                }

                Section {
                    Button {
                        Task { await model.toggle() }
                    } label: {
                        Label(dictateTitle, systemImage: model.phase == .recording ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .disabled(model.phase == .sending)
                    if let text = model.lastText {
                        Text(text).textSelection(.enabled)
                    }
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
                            model.notice = L("NoticeCopied")
                        } label: {
                            Text(text).lineLimit(3).foregroundStyle(.primary)
                        }
                    }
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
        }
    }

    private var dictateTitle: String {
        switch model.phase {
        case .recording: L("DictateStop")
        case .sending: L("StatusSending")
        case .off, .ready: L("DictateHere")
        }
    }
}

private struct SessionRow: View {
    @Bindable var model: Dictation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                if model.phase == .recording {
                    Text(model.recordingStarted, style: .timer)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.phase == .off ? L("SessionOffHint") : L("SessionOnHint", model.sessionMinutes))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.phase == .off ? L("SessionStart") : L("SessionStop")) {
                if model.phase == .off {
                    Task { await model.startSession() }
                } else {
                    model.endSession()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var status: String {
        switch model.phase {
        case .off: L("StatusOff")
        case .ready: L("StatusReady")
        case .recording: L("StatusRecording")
        case .sending: L("StatusSending")
        }
    }

    private var color: Color {
        switch model.phase {
        case .off: .secondary
        case .ready: .green
        case .recording: .red
        case .sending: .orange
        }
    }
}

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

struct SettingsView: View {
    @Bindable var model: Dictation
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                TextField(L("ServerPlaceholder"), text: $model.server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L("Server"))
            }

            Section {
                SecureField(L("TokenPlaceholder"), text: $token)
                Button(L("TokenSave")) {
                    model.saveToken(token)
                    token = ""
                }
                .disabled(token.isEmpty)
            } header: {
                Text(L("Token"))
            } footer: {
                Text(model.hasToken ? L("TokenSaved") : L("TokenMissing"))
            }

            Section(L("Session")) {
                Picker(L("SessionLength"), selection: $model.sessionMinutes) {
                    ForEach(Dictation.sessionChoices, id: \.self) { Text(L("Minutes", $0)).tag($0) }
                }
            }

            Section {
                Text(L("KeyboardSetup"))
                Button(L("OpenSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text(L("Keyboard"))
            }

            Section {
                Text(L("ActionButtonSetup"))
            } header: {
                Text(L("ActionButton"))
            }
        }
        .navigationTitle(L("Settings"))
    }
}
