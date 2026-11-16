import AppIntents
import SwiftUI

@main
struct DictateApp: App {
    @State private var model = Dictation.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in Task { await model.open(url) } }
        }
    }
}

/// The Action Button: first press records, the next one stops and puts the text on the clipboard.
/// An audio recording intent may start the microphone from the background, as long as a Live Activity shows it.
struct DictateIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "IntentTitle"
    static let description = IntentDescription("IntentDescription")

    @MainActor
    func perform() async throws -> some IntentResult {
        await Dictation.shared.toggle()
        return .result()
    }
}

struct DictateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(), phrases: ["\(.applicationName)"], shortTitle: "IntentShortTitle",
            systemImageName: "mic")
    }
}
