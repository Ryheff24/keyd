import SwiftUI
import SharedProtocol

// MARK: - Main Test Runner View

struct TransportTestRunnerView: View {
    @StateObject private var runner = TransportTestRunner()

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
        }
        .navigationTitle("Transport Tests")
        .navigationBarTitleDisplayMode(.inline)
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
