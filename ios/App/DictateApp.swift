import AppIntents
import SwiftUI

@main
struct DictateApp: App {
    @State private var model = Dictation.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in Task { await model.open(url) } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.appeared() }
            case .background: model.openedFromKeyboard = false
            default: break
            }
        }
    }
}

struct DictateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(), phrases: ["\(.applicationName)"], shortTitle: "IntentShortTitle",
            systemImageName: "mic")
    }
}
