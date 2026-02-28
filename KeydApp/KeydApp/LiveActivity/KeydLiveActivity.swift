import ActivityKit
import Combine

/// Manages the ActivityKit Live Activity lifecycle for connection status (main app target).
/// The Dynamic Island rendering is done by the KeydLiveActivity Widget Extension — NOT here.
/// This class only requests/updates/ends the activity; the system calls the widget extension
/// to render it in the Dynamic Island.
@MainActor
final class KeydLiveActivityManager: ObservableObject {
    private(set) var activity: Activity<KeydConnectionAttributes>?
    private var endTask: Task<Void, Never>?

    init() {
        let lingeringIDs = Set(Activity<KeydConnectionAttributes>.activities.map(\.id))
        guard !lingeringIDs.isEmpty else { return }

        let finalState = KeydConnectionAttributes.ContentState(status: .disconnected, latencyMs: nil)
        let content = ActivityContent(state: finalState, staleDate: nil)

        Task {
            for existing in Activity<KeydConnectionAttributes>.activities where lingeringIDs.contains(existing.id) {
                await existing.end(content, dismissalPolicy: .immediate)
            }
        }
    }

    func start(status: KeydConnectionAttributes.ContentState.Status) {
        endTask?.cancel()
        endTask = nil

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
        endTask?.cancel()
        endTask = nil

        let newState = KeydConnectionAttributes.ContentState(status: status, latencyMs: latencyMs)
        Task {
            let content = ActivityContent(state: newState, staleDate: nil)
            await activity?.update(content)
        }
    }

    func end() {
        endTask?.cancel()

        let finalState = KeydConnectionAttributes.ContentState(status: .disconnected, latencyMs: nil)
        endTask = Task {
            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity?.end(content, dismissalPolicy: .immediate)
            activity = nil
            endTask = nil
            print("[LiveActivity] Ended")
        }
    }
}
