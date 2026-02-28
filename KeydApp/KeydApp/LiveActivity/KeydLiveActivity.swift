import ActivityKit
import Combine

/// Manages the ActivityKit Live Activity lifecycle for connection status (main app target).
/// The Dynamic Island rendering is done by the KeydLiveActivity Widget Extension — NOT here.
/// This class only requests/updates/ends the activity; the system calls the widget extension
/// to render it in the Dynamic Island.
@MainActor
final class KeydLiveActivityManager: ObservableObject {
    private(set) var activity: Activity<KeydConnectionAttributes>?

    func start(status: KeydConnectionAttributes.ContentState.Status) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] Live Activities not enabled on this device")
            return
        }

        let initialState = KeydConnectionAttributes.ContentState(status: status, latencyMs: nil)
        let attributes = KeydConnectionAttributes()
        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            activity = try Activity<KeydConnectionAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            print("[LiveActivity] Started: \(status.rawValue)")
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    func update(status: KeydConnectionAttributes.ContentState.Status, latencyMs: Int? = nil) {
        let newState = KeydConnectionAttributes.ContentState(status: status, latencyMs: latencyMs)
        Task {
            let content = ActivityContent(state: newState, staleDate: nil)
            await activity?.update(content)
        }
    }

    func end() {
        let finalState = KeydConnectionAttributes.ContentState(status: .disconnected, latencyMs: nil)
        Task {
            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity?.end(content, dismissalPolicy: .immediate)
            activity = nil
        }
    }
}
