import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DictateWidgets: WidgetBundle {
    var body: some Widget {
        DictateLiveActivity()
    }
}

/// The session in the Dynamic Island and on the lock screen: why the microphone is on and what it is doing.
struct DictateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictateAttributes.self) { context in
            HStack(spacing: 12) {
                PhaseIcon(phase: context.state.phase).font(.title2)
                Text(title(context.state.phase)).font(.headline)
                Spacer()
                PhaseDetail(state: context.state)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseDetail(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(title(context.state.phase)).font(.headline)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                PhaseDetail(state: context.state)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }

    private func title(_ phase: String) -> String {
        switch phase {
        case "recording": L("StatusRecording")
        case "sending": L("StatusSending")
        case "done": L("ActivityDone")
        case "failed": L("ActivityFailed")
        default: L("StatusReady")
        }
    }
}

private struct PhaseIcon: View {
    let phase: String

    var body: some View {
        switch phase {
        case "recording": Image(systemName: "mic.fill").foregroundStyle(.red)
        case "sending": Image(systemName: "waveform").foregroundStyle(.orange)
        case "done": Image(systemName: "checkmark").foregroundStyle(.green)
        case "failed": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        default: Image(systemName: "mic").foregroundStyle(.blue)
        }
    }
}

private struct PhaseDetail: View {
    let state: DictateAttributes.ContentState

    var body: some View {
        if state.phase == "recording" {
            Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .frame(maxWidth: 52)
        } else {
            Text(state.since, style: .time).font(.caption).foregroundStyle(.secondary)
        }
    }
}
