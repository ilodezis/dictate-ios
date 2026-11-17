import AppIntents

// Compiled into the app and the widget extension: Control Center and the Live Activity refer to these,
// and the system runs audio-recording and Live Activity intents in the app's process. Only the app
// target defines MAIN_APP, so the extension carries the declarations without the app's code.

/// Control Center: turns the microphone on for the keyboard without opening the app, or off.
struct MicrophoneIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "MicrophoneIntentTitle"
    // Only the Control Center button runs it; run from Shortcuts, iOS refuses it the Live Activity it requires.
    static let isDiscoverable = false
    static let description = IntentDescription("MicrophoneIntentDescription")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if MAIN_APP
        await Dictation.shared.toggleMicrophone()
        #endif
        return .result()
    }
}

/// The off button on the Live Activity.
struct TurnOffIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "TurnOffIntentTitle"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if MAIN_APP
        Dictation.shared.turnOff()
        #endif
        return .result()
    }
}
