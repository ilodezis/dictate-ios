import AppIntents

// Compiled into the app and the widget extension: Control Center and the Live Activity refer to these,
// and the system runs audio-recording and Live Activity intents in the app's process. Only the app
// target defines MAIN_APP, so the extension carries the declarations without the app's code.

/// The Action Button: first press records, the next one stops and puts the text on the clipboard.
/// An audio recording intent may start the microphone from the background, as long as a Live Activity shows it.
struct DictateIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "IntentTitle"
    static let description = IntentDescription("IntentDescription")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if MAIN_APP
        await Dictation.shared.toggle()
        #endif
        return .result()
    }
}

/// Control Center: turns the microphone on for the keyboard without opening the app, or off.
struct MicrophoneIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "MicrophoneIntentTitle"
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
