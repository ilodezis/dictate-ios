import ActivityKit
import Foundation

/// A UI string from Localizable.strings of the running bundle (app or extension): English fallback, Russian.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// The Live Activity: on while the app holds the microphone, so the orange dot always has an explanation.
struct DictateAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// ready, recording, sending, done (typed), copied, failed
        var phase: String
        var since: Date
    }
}
