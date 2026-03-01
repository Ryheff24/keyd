import SwiftUI
import SharedProtocol
import CryptoKit

// MARK: - Main Test Runner View

struct TransportTestRunnerView: View {
    @StateObject private var runner = TransportTestRunner()
    @StateObject private var suiteCRunner = IntegrationSuiteCRunner()

    var body: some View {
        List {
            if runner.results.isEmpty && !runner.isRunning {
                Section {
                    Text("Tap Run All to execute all 24 FSM scenarios.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }

            if runner.isRunning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Running scenarios...")
                            .foregroundColor(.secondary)
                        ProgressView(value: runner.progress)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !runner.results.isEmpty {
                Section("Summary") {
                    HStack {
                        Label("\(runner.passedCount) passed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Label("\(runner.failedCount) failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(runner.failedCount > 0 ? .red : .secondary)
                    }
                }

                let suiteAResults = runner.results.filter { result in
                    allScenarios.first(where: { $0.id == result.id })?.suite == .singleDevice
                }
                let suiteBResults = runner.results.filter { result in
                    allScenarios.first(where: { $0.id == result.id })?.suite == .multiDevice
                }

                if !suiteAResults.isEmpty {
                    Section("Suite A: Single-Device") {
                        ForEach(suiteAResults) { result in
                            NavigationLink(destination: ScenarioDetailView(result: result, runner: runner)) {
                                ScenarioRowView(result: result)
                            }
                        }
                    }
                }

                if !suiteBResults.isEmpty {
                    Section("Suite B: Multi-Device") {
                        ForEach(suiteBResults) { result in
                            NavigationLink(destination: ScenarioDetailView(result: result, runner: runner)) {
                                ScenarioRowView(result: result)
                            }
                        }
                    }
                }
            }

            // Suite C: Connected (semi-automated, requires physical device + Mac in --test-mode)
            Section("Suite C: Connected") {
                if suiteCRunner.isConnected {
                    ForEach(suiteCRunner.results) { result in
                        ScenarioRowView(result: ScenarioResult(
                            id: result.id,
                            scenarioName: result.name,
                            passed: result.passed,
                            stepsExecuted: 1,
                            invariantViolations: [],
                            eventTrace: [],
                            failureDetail: result.detail,
                            finalState: .disconnected
                        ))
                    }
                    if suiteCRunner.isRunning {
                        ProgressView(suiteCRunner.currentStep)
                            .padding(.vertical, 4)
                    } else {
                        Button("Run Suite C") {
                            Task { await suiteCRunner.runAll() }
                        }
                        .disabled(suiteCRunner.isRunning)
                    }
                } else {
                    Text("Not connected to Mac agent. Plug in USB cable and start the Mac agent with --test-mode.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("Transport Tests")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            suiteCRunner.refreshConnectionState()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if runner.isRunning {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button("Run All") {
                        Task { await runner.runAll() }
                    }
                }
            }
        }
    }
}

// MARK: - Scenario Row

private struct ScenarioRowView: View {
    let result: ScenarioResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.passed ? .green : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(result.id)
                        .font(.headline)
                        .fontDesign(.monospaced)
                    Spacer()
                    Text("\(result.stepsExecuted) steps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(result.scenarioName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Scenario Detail View

struct ScenarioDetailView: View {
    let result: ScenarioResult
    let runner: TransportTestRunner

    @State private var showingTrace = false
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        List {
            Section("Result") {
                HStack {
                    Label(
                        result.passed ? "PASSED" : "FAILED",
                        systemImage: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundColor(result.passed ? .green : .red)
                    .fontWeight(.semibold)
                    Spacer()
                    Text("\(result.stepsExecuted) steps")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Final State")
                    Spacer()
                    Text(result.finalState.description)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            if !result.invariantViolations.isEmpty {
                Section("Invariant Violations (\(result.invariantViolations.count))") {
                    ForEach(Array(result.invariantViolations.enumerated()), id: \.offset) { _, violation in
                        Text(violation)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
            }

            if let detail = result.failureDetail {
                Section("Failure Detail") {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }

            Section("Actions") {
                Button {
                    Task { await runner.rerun(scenarioID: result.id) }
                } label: {
                    Label("Re-run Scenario", systemImage: "arrow.clockwise")
                }
                .disabled(runner.isRunning)

                Button {
                    exportTrace()
                } label: {
                    Label("Export Event Trace", systemImage: "square.and.arrow.up")
                }
                .disabled(result.eventTrace.isEmpty)
            }

            Section("Event Trace (\(result.eventTrace.count) events)") {
                if result.eventTrace.isEmpty {
                    Text("No events recorded")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(result.eventTrace.prefix(50).enumerated()), id: \.offset) { idx, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("#\(idx + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                Text(entry.event)
                                    .font(.system(size: 11, design: .monospaced))
                                    .fontWeight(.medium)
                            }
                            HStack {
                                Text("  ")
                                Text("\(entry.previousState) → \(entry.newState)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    if result.eventTrace.count > 50 {
                        Text("... \(result.eventTrace.count - 50) more events (export for full trace)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("\(result.id): \(result.scenarioName)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.data as Any, item.filename])
        }
    }

    private func exportTrace() {
        let log = TransportEventLog(capacity: result.eventTrace.count + 1)
        for entry in result.eventTrace { log.append(entry) }
        let data = log.exportJSON()
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "keyd-trace-\(result.id)-\(timestamp).json"
        shareItem = ShareItem(data: data, filename: filename)
    }
}

// MARK: - Share helpers

private struct ShareItem: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - Suite C: Connected (semi-automated integration tests)

/// Drives Suite C: Connected tests in the UI runner.
/// Suite C tests are semi-automated: they require a physical device and Mac agent with --test-mode,
/// and may prompt the user for a manual step (e.g. "unplug USB cable now").
/// Results are advisory only — they never block deployment.
@MainActor
final class IntegrationSuiteCRunner: ObservableObject {
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var currentStep = "Running..."
    @Published var results: [SuiteCResult] = []

    struct SuiteCResult: Identifiable {
        let id: String
        let name: String
        let passed: Bool
        let detail: String?
    }

    private var harness: SuiteCHarness?

    init() {
        refreshConnectionState()
    }

    /// Refreshes connection state from TransportManagerRegistry.
    func refreshConnectionState() {
        let tm = TransportManagerRegistry.shared.transportManager
        isConnected = tm?.isConnected ?? false
        if isConnected { harness = harness ?? SuiteCHarness() }
    }

    func runAll() async {
        guard !isRunning else { return }
        if harness == nil { harness = SuiteCHarness() }
        guard let harness else { return }

        isRunning = true
        results = []
        currentStep = "Connecting..."

        // USB→AWDL fallback (semi-automated: prompts human to unplug USB cable)
        currentStep = "C-01: USB→AWDL Fallback"
        do {
            let result = try await IntegrationTestCase.runUSBAWDLFallback(
                harness: harness,
                onPrompt: { [weak self] in
                    await MainActor.run {
                        self?.currentStep = "MANUAL: Unplug USB cable now. Waiting 10s..."
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10s window
                }
            )
            results.append(SuiteCResult(
                id: "C-01",
                name: "USB→AWDL Fallback",
                passed: result.passed,
                detail: result.detail
            ))
        } catch {
            results.append(SuiteCResult(
                id: "C-01",
                name: "USB→AWDL Fallback",
                passed: false,
                detail: error.localizedDescription
            ))
        }

        currentStep = "Done"
        isRunning = false
        refreshConnectionState()
    }
}

// MARK: - SuiteCHarness (IntegrationHarnessProtocol conformance for UI runner)

/// Concrete IntegrationHarnessProtocol implementation for Suite C UI runner.
/// Does not import XCTest — uses TransportManagerRegistry directly.
@MainActor
final class SuiteCHarness: IntegrationHarnessProtocol {
    private weak var transportManager: TransportManager?
    private weak var pairingManager: PairingManager?
    private var observers: [NSObjectProtocol] = []

    init() {
        self.transportManager = TransportManagerRegistry.shared.transportManager
        self.pairingManager = TransportManagerRegistry.shared.pairingManager
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isConnectedToAgent: Bool { transportManager?.isConnected ?? false }

    var currentTransport: ConnectionKind? {
        guard let tm = transportManager else { return nil }
        switch tm.connectionState {
        case .usbConnected: return .usb
        case .awdlConnected: return .awdl
        default: return nil
        }
    }

    func connect(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transportManager?.isConnected == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw HarnessError.connectionTimeout
    }

    func reset(timeout: TimeInterval) async throws {
        guard let tm = transportManager else { throw HarnessError.noTransportManager }
        _ = try await awaitMessage(matching: { msg in
            if case .testResetAck = msg { return true }
            return false
        }, beforeSend: {
            tm.sendTestMessage(.testReset)
        }, timeout: timeout)
    }

    func awaitMessage(
        matching predicate: @escaping @MainActor (KeydMessage) -> Bool,
        timeout: TimeInterval
    ) async throws -> KeydMessage {
        try await awaitMessage(matching: predicate, beforeSend: nil, timeout: timeout)
    }

    func awaitMessage(
        matching predicate: @escaping @MainActor (KeydMessage) -> Bool,
        beforeSend: (() -> Void)?,
        timeout: TimeInterval
    ) async throws -> KeydMessage {
        guard let tm = transportManager else { throw HarnessError.noTransportManager }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<KeydMessage, Error>) in
            var resumed = false

            let observer = tm.registerTestMessageObserver(predicate: predicate) { [weak self] message in
                guard !resumed else { return }
                resumed = true
                if let self {
                    for obs in self.observers { NotificationCenter.default.removeObserver(obs) }
                    self.observers.removeAll()
                }
                continuation.resume(returning: message)
            }
            observers.append(observer)

            beforeSend?()

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !resumed else { return }
                resumed = true
                if let self {
                    for obs in self.observers { NotificationCenter.default.removeObserver(obs) }
                    self.observers.removeAll()
                }
                continuation.resume(throwing: HarnessError.messageTimeout)
            }
        }
    }

    func sendAndAwait(
        _ message: KeydMessage,
        expecting predicate: @escaping @MainActor (KeydMessage) -> Bool,
        timeout: TimeInterval
    ) async throws {
        guard let tm = transportManager else { throw HarnessError.noTransportManager }
        _ = try await awaitMessage(matching: predicate, beforeSend: {
            tm.sendTestMessage(message)
        }, timeout: timeout)
    }

    func injectPairingToken(_ payload: TestPairingPayload) {
        guard let tm = transportManager, let pm = pairingManager else { return }
        Task { @MainActor in
            await tm.injectTestPairingToken(payload, pairingManager: pm)
        }
    }

    enum HarnessError: Error, LocalizedError {
        case connectionTimeout
        case noTransportManager
        case messageTimeout

        var errorDescription: String? {
            switch self {
            case .connectionTimeout: return "Connection timeout"
            case .noTransportManager: return "TransportManager not available"
            case .messageTimeout: return "Message timeout"
            }
        }
    }
}
