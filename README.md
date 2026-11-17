# keyd

Two personal Apple-device projects in one repo:

- **keyd-rd** (active): an iPad Pro acts as a low-latency remote display and input device for a Mac,
  over a USB-C cable or wirelessly over Wi-Fi/AWDL.
- **keyd** (v1, inactive): an iPhone acts as a keyboard and editor that types into the Mac in real time
  over USB or AWDL.

These are hobby projects for my own devices. They are not distributed, signed for release, or
supported. The code is published as a reference for anyone working on the same problems:
- low-latency screen streaming between Apple devices;
- USB NCM and AWDL transports;
- formal models of transport and session behaviour.

## keyd-rd: iPad remote desktop for macOS

The Mac agent captures the display and sends it to the iPad. The iPad renders the frames and sends
touch, mouse and keyboard input back.

| | Mac agent (`RemoteDesktop/macOS`) | iPad app (`RemoteDesktop/iPadOS`) |
|---|---|---|
| Language | C and Objective-C (no Swift runtime) | Swift |
| Video | ScreenCaptureKit; LZ4 + delta frames on USB; VideoToolbox HEVC on Wi-Fi/AWDL | VideoToolbox decode; Metal with `CAMetalDisplayLink`, ProMotion 120 Hz |
| Input | `CGEvent` injection | Touch-to-mouse, hardware and on-screen keyboard |

**Transports**, in order of preference:
1. **USB NCM.** A direct USB-C link, detected with `getifaddrs()`.
2. **AWDL.** Peer-to-peer Wi-Fi.
3. **Infrastructure Wi-Fi.**

All channels use TLS 1.3. Devices pair with a QR code, and the Mac's identity key lives in the
keychain (Secure Enclave). No key files exist anywhere.

**Wire protocol**: fixed binary headers, defined in `RemoteDesktop/Shared`.

**Timing**: both sides timestamp with `CACurrentMediaTime()`, synced with Cristian's algorithm.
Glass-to-glass latency is measured from capture time to the iPad's target presentation time.

### Status

This is a work in progress. Frame rate, frame pacing and tail latency are the open problems,
especially on AWDL.
- `.planning/METRICS.md` holds the measured numbers. The E2E harness updates it on every run, and it
  reports p99.9 and worst-second figures.
- `.planning/research/` and `docs/research/` hold the investigations.

### Formal models

Behaviour that crosses the iPad–Mac boundary is modelled in TLA+ before it is coded: pairing,
transport switching, session lifecycle, input and frame delivery. The models are in
`RemoteDesktop/tla`; `METHOD.md` explains the approach and `PLAN.md` shows status.

```bash
make -C RemoteDesktop/tla verify
```

### End-to-end tests

`RemoteDesktop/scripts/run-e2e-tests.sh` does the whole loop on two physical devices:
1. builds both apps and installs and launches them;
2. streams a fixed capture video;
3. runs the test phases;
4. writes per-second strict metrics (`e2e_strict.py`).

```bash
./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "what changed"
```

Running it needs:
- a paired iPad and Mac;
- your own signing team;
- a `device-config.mk` (copy `device-config.mk.example`);
- your own capture video.

The paths in the scripts and docs point at the author's machine and need adjusting.

## Repository layout

| Path | What it is |
|---|---|
| `RemoteDesktop/macOS` | Mac agent (capture, encode, transport, input injection) |
| `RemoteDesktop/iPadOS` | iPad app (transport, decode, Metal render, input) |
| `RemoteDesktop/Shared` | Wire protocol headers shared by both sides |
| `RemoteDesktop/tla` | TLA+ models and proofs |
| `RemoteDesktop/scripts` | Build, debug and E2E harness scripts, log analysers |
| `KeydApp`, `macOS/KeydAgent`, `SharedProtocol` | keyd v1 (iPhone keyboard) |
| `.planning` | Requirements, roadmap, metrics, research notes |
| `docs/research` | Longer investigations and reviews |

## Building

You need Xcode, macOS 14.2 or later on the Mac, and iPadOS 17 or later on the iPad. Open
`RemoteDesktop/RemoteDesktop.xcworkspace` and set your own development team.

The Mac agent needs Screen Recording and Accessibility permissions. Launch it with `open -a` so macOS
attributes those permissions to the app rather than to your terminal.

## Notes

Much of this code was written with AI coding agents. Agent configuration and tooling is committed:
- `CLAUDE.md`, `agents.md`;
- `.claude/`, `.codex/`, `.cursor/`, `.github/`.

## License

Apache-2.0, the same as agentlog. See [LICENSE](LICENSE). `RemoteDesktop/Shared/lz4.c` and `lz4.h`
are LZ4 by Yann Collet, under their own BSD 2-Clause license (see their headers).
