import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DictateWidgets: WidgetBundle {
    var body: some Widget {
        DictateLiveActivity()
        MicrophoneControl()
    }
}

/// Control Center and the Lock Screen: the microphone on or off without opening the app.
struct MicrophoneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Bridge.controlKind, provider: Provider()) { isOn in
            ControlWidgetButton(action: MicrophoneIntent()) {
                Label(isOn ? L("ControlOn") : L("ControlOff"), systemImage: isOn ? "mic.fill" : "mic.slash")
            }
            .tint(.green)
        }
        .displayName("ControlName")
        .description("ControlDescription")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { Bridge.isAlive }
    }
}

/// The Dynamic Island and the lock screen: why the microphone is on, what it is doing, and how to turn it off.
struct DictateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictateAttributes.self) { context in
            HStack(spacing: 12) {
                PhaseIcon(phase: context.state.phase).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(context.state.phase)).font(.headline)
                    if context.state.phase == "recording" {
                        Elapsed(since: context.state.since).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                OffButton()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase).font(.title2).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state.phase)).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == "recording" {
                        Elapsed(since: context.state.since).padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    OffButton()
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                // Only recording has something to say on the right: how long.
                if context.state.phase == "recording" {
                    Elapsed(since: context.state.since)
                }
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }

    private func title(_ phase: String) -> String {
        switch phase {
        case "recording": L("StatusRecording")
        case "sending": L("StatusSending")
        case "done": L("ActivityTyped")
        case "copied": L("ActivityCopied")
        case "failed": L("ActivityFailed")
        default: L("ActivityReady")
        }
    }
}

private struct OffButton: View {
    var body: some View {
        Button(intent: TurnOffIntent()) {
            Label(L("TurnOff"), systemImage: "mic.slash")
        }
        .tint(.secondary)
    }
}

private struct Elapsed: View {
    let since: Date

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .frame(maxWidth: 52)
    }
}

private struct PhaseIcon: View {
    let phase: String

    var body: some View {
        switch phase {
        case "recording": Image(systemName: "waveform").foregroundStyle(.red)
        case "sending": Image(systemName: "ellipsis").foregroundStyle(.orange)
        case "done", "copied": Image(systemName: "checkmark").foregroundStyle(.green)
        case "failed": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        default: Image(systemName: "mic.fill").foregroundStyle(.green)
        }
    }
}
