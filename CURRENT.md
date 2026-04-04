# CURRENT

## Active Objective

- Lane: usb
- Goal: restore and harden USB transport performance headroom under aggressive stream load (no E2E run in this loop by constraint)

## Latest Run

- Timestamp: 2026-04-04 (lane B USB iteration)
- Command: `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData build` and `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData build`
- Notes: USB-focused profiling/fix iteration only; E2E script intentionally not run per constraint.
- Result: macOS build ✅, iPadOS build ✅

## Instrumentation Added This Iteration

- Surfaces touched:
  - `RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift`
  - `RemoteDesktop/iPadOS/Transport/UDPReassembler.swift`
  - `RemoteDesktop/macOS/Transport/USBNetworkTransport.m`
- New log signals:
  - iPad USB TCP receive/drain path:
    - `USBTransport: tcp-recv append=... buffer=... readOffset=...`
    - `USBTransport: tcp-drain partial msgLen=... available=...`
    - `USBTransport: tcp-drain delivered=... elapsed=... start=... end=... totalMsgs=...`
    - `USBTransport: tcp-compact #... consumed=... unread=... elapsed=... newBuffer=...`
  - iPad chunk reassembly:
    - `UDPReassembler: reassemble seq=... chunks=... bytes=... elapsed=...`
  - mac USB HEVC chunk send batching:
    - `USB media chunk batch build: ...`
    - `USB media chunk batch ready: ... buildElapsed=...`
    - `USB media chunk batch send success/error: ... elapsed=...`
- Why needed: prior USB behavior had no direct timing/queue visibility across TCP drain compaction and chunk-batch send cost, making regression causality ambiguous.

## Key Metrics (Latest)

- E2E metrics: not collected in this loop (E2E script not run per lane constraint).
- Build status:
  - macOS `RemoteDesktopAgent`: **BUILD SUCCEEDED**
  - iPadOS `RemoteDesktopApp`: **BUILD SUCCEEDED**

## Current Hypothesis

- Residual USB regression risk was primarily in:
  1) iPad TCP reassembly compaction frequency (`removeSubrange`) causing avoidable memmove stalls,
  2) iPad chunk reassembly append growth churn,
  3) mac HEVC chunk-per-send recursion overhead and weak per-batch observability.

## Next Change

- Let orchestrator run USB validation to quantify:
  - TCP drain elapsed/compaction cadence improvements,
  - chunk batch send elapsed stability,
  - any remaining sender backpressure/drop bursts.

## Validation Plan

- Run USB validation command externally (orchestrator lane flow).
- Triaging focus:
  - iPad logs: `tcp-drain`, `tcp-compact`, `reassemble`.
  - mac logs: `chunk batch ready/send success`, `TCP backpressure`.
- Confirm no correctness/security regressions and no increased reconnect churn.
