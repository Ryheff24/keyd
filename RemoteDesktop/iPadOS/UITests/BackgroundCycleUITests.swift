import XCTest

/// E2E background cycle (run-e2e-tests.sh, background-recovery phase). Attaches to the
/// already-running app by bundle id: this bundle has no target application, so running it
/// neither reinstalls nor relaunches the app, and the harness's console capture stays attached.
/// Sends the app to the background with the Home button, waits KEYD_BG_SECONDS (passed as
/// TEST_RUNNER_KEYD_BG_SECONDS), then brings the same process back with activate().
final class BackgroundCycleUITests: XCTestCase {
    func testBackgroundCycle() throws {
        let env = ProcessInfo.processInfo.environment
        let seconds = Double(env["KEYD_BG_SECONDS"] ?? "") ?? 5
        let app = XCUIApplication(bundleIdentifier: "com.ryheff.keyd.remote.app")
        print("[UITEST] background-cycle entry state=\(app.state.rawValue) seconds=\(seconds)")
        XCTAssertEqual(app.state, .runningForeground, "app not in the foreground at start")

        XCUIDevice.shared.press(.home)
        let suspended = app.wait(for: .runningBackgroundSuspended, timeout: 10)
        print("[UITEST] background-cycle backgrounded suspended=\(suspended) state=\(app.state.rawValue)")
        XCTAssertNotEqual(app.state, .runningForeground, "Home did not background the app")

        Thread.sleep(forTimeInterval: seconds)
        app.activate()
        let foreground = app.wait(for: .runningForeground, timeout: 10)
        print("[UITEST] background-cycle exit foreground=\(foreground) state=\(app.state.rawValue)")
        XCTAssertTrue(foreground, "app did not return to the foreground")
    }
}
