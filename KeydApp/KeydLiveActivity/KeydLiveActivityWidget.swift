import ActivityKit
import WidgetKit
import SwiftUI

/// ActivityKit widget providing Dynamic Island and Lock Screen views for Keyd connection status.
/// Expanded Dynamic Island shows status + latency + reconnect button (CONTEXT.md locked decision).
struct KeydLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KeydConnectionAttributes.self) { context in
            // Lock Screen / Notification Center banner view
            HStack(spacing: 10) {
                Circle()
                    .fill(context.state.status.color)
                    .frame(width: 12, height: 12)
                Text(context.state.status.label)
                    .font(.headline)
                if let ms = context.state.latencyMs {
                    Text("\(ms)ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                // Reconnect button: CONTEXT.md locked decision — expanded view has reconnect button
                Link(destination: URL(string: "keyd://reconnect")!) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.8))

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view (shown when user long-presses Dynamic Island)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(context.state.status.color)
                            .frame(width: 12, height: 12)
                        Text(context.state.status.label)
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        if let ms = context.state.latencyMs {
                            Text("\(ms)ms")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        // Reconnect button: CONTEXT.md locked decision for expanded view
                        Link(destination: URL(string: "keyd://reconnect")!) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("keyd — macOS keyboard bridge")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            } compactLeading: {
                // Compact view leading: color dot indicates transport
                Circle()
                    .fill(context.state.status.color)
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                // Compact view trailing: latency or transport abbreviation
                if let ms = context.state.latencyMs {
                    Text("\(ms)ms")
                        .font(.caption2)
                        .foregroundColor(.white)
                } else {
                    Text(context.state.status.shortLabel)
                        .font(.caption2)
                        .foregroundColor(.white)
                }
            } minimal: {
                // Minimal view: just the color dot
                Circle()
                    .fill(context.state.status.color)
                    .frame(width: 8, height: 8)
            }
        }
    }
}
