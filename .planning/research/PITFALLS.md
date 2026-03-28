# Pitfalls Research

**Domain:** iPadOS-to-macOS remote desktop (keyd-rd)
**Researched:** 2026-03-27
**Confidence:** MEDIUM-HIGH (WebSearch verified against Apple Developer Forums, official docs, WWDC sessions, and open-source implementations. USB NCM viability section has additional evidence from community reports.)

---

## CRITICAL FINDING: USB NCM Accessibility from Regular iPadOS Apps

**Verdict: VIABLE with caveats — but requires Local Network permission and careful interface binding.**

When an iPad is connected to a Mac via USB-C/Thunderbolt, macOS creates a USB NCM (CDC-NCM) network interface — a real link-local Ethernet-like link. Starting with iOS 16, two CDC-NCM interfaces are created after mode switching.

**What is accessible to regular (non-jailbroken) iPadOS apps:**
- The USB NCM interface appears as `.wiredEthernet` type in `NWPathMonitor` on the iPad side
- Regular apps CAN open TCP/UDP sockets over this interface using `Network.framework`
- No special entitlement is required to initiate or listen on TCP/UDP connections to link-local addresses over this interface
- `NWParameters.requiredInterface` can be used to pin a connection to the specific wiredEthernet interface
- The "Local Network" privacy permission (`NSLocalNetworkUsageDescription`) IS required if the app sends UDP packets or connects to link-local addresses (triggered on first send, not on socket creation)

**Critical gotchas:**
1. Link-local addresses (fe80::/10 or 169.254.x.x) require explicit interface binding. Using `NWParameters.requiredInterface` with the specific `NWInterface` object (not just `requiredInterfaceType`) is required for link-local to work correctly — the TCP SYN must carry the correct source interface IP or the connection is dropped
2. The multicast entitlement (`com.apple.developer.networking.multicast`) IS required for multicast/broadcast — but unicast TCP/UDP does NOT need it
3. Service discovery via mDNS/Bonjour requires `NSBonjourServices` in Info.plist and `NSLocalNetworkUsageDescription`
4. The USB NCM interface is NOT guaranteed to have a stable interface name (en4, en7, en8 vary by device and connection order) — always use NWPathMonitor to find the current wiredEthernet interface by type, not by name

**Alternative if USB NCM proves unreliable:** Fall back to the existing usbmuxd TCP tunnel (proven in keyd v1.0). Media throughput over usbmuxd is limited by TCP framing overhead but is viable for HEVC-encoded streams. Reserve USB NCM as the primary path for LZ4+delta wired mode.

**Confidence:** MEDIUM (multiple Apple Developer Forum threads confirm wiredEthernet access from iPadOS apps; specific USB NCM peer-to-peer iPad↔Mac scenario has fewer confirmed reports than general wiredEthernet adapter use cases)

---

## Critical Pitfalls

### Pitfall 1: ScreenCaptureKit Monthly Re-Authorization Prompt (macOS Sequoia+)

**Severity: CRITICAL — Breaks unattended/background operation**

**What goes wrong:**
macOS Sequoia (15.0+) added a periodic re-authorization prompt for all apps using ScreenCaptureKit. Initially weekly, later reduced to monthly. The prompt fires even for apps that previously had permission. An unattended agent (running without user interaction) will silently stop capturing after the permission lapses — `SCShareableContent` callbacks stop firing, stream continues but delivers no frames, or returns `SCStreamError.connectionInvalid` (-3805).

**Why it happens:**
Apple added this privacy UX as a security measure. Any app using `SCShareableContent.getWithCompletionHandler` or `SCStream` without using the `SCContentSharingPicker` triggers the periodic re-authorization cycle. There is a "Persistent Content Capture" entitlement for VNC-class apps that bypasses this, but Apple has provided no public documentation on how to obtain it, and it appears to require an explicit entitlement request to Apple (form-based process). Jump Desktop uses this entitlement.

**How to avoid:**
- Apply for the `com.apple.developer.screencapture.persist` (Persistent Content Capture) entitlement via Apple's entitlement request form — this is specifically designed for remote desktop / VNC use cases and should be approvable for a personal-use self-signed app if the request is made
- As a fallback for the self-signed case: add a menu bar status indicator that explicitly shows capture permission status; prompt the user to re-authorize if the stream stops delivering frames
- Detect permission lapse: register a handler that fires when `SCStream` produces 0 frames for >2 seconds during active session; distinguish from "display sleeping" vs "permission lapsed" (the latter produces no output even with display awake)
- macOS 15.1 reduced the frequency further; test on the actual macOS version

**Warning signs:**
- Stream starts successfully but delivers no frame callbacks after an initial burst
- `SCStreamError` code -3805 (`connectionInvalid`) in the stream error callback
- App worked last week, now captures 0 frames after launching

**Phase to address:** Phase 1 (Screen Capture + Transport). Must be verified during initial ScreenCaptureKit integration before any other pipeline work.

---

### Pitfall 2: Link-Local IPv6 Requires Explicit Interface Binding on Both Sides

**Severity: CRITICAL — Silent connection failure, no useful error**

**What goes wrong:**
Attempting to open a `NWConnection` to a link-local address (fe80::) without pinning it to the specific interface results in a silently dropped or rejected connection. The connection enters a `.failed` state with a generic error. This affects BOTH the Mac side (Objective-C `Network.framework` or BSD sockets) and the iPad side (Swift `Network.framework`).

**Why it happens:**
Link-local addresses are per-interface by definition (the same fe80:: prefix appears on every interface). The OS needs the scope ID (interface index) to route correctly. `Network.framework` requires using `NWParameters.requiredInterface` with the exact `NWInterface` object from `NWPathMonitor`, not just `requiredInterfaceType: .wiredEthernet`. On the BSD socket side (C code on macOS), the `IPV6_BOUND_IF` socket option or `sin6_scope_id` field must be set correctly.

**How to avoid:**
- iPad side: Use `NWPathMonitor` to obtain the current `NWPath`, extract the `NWInterface` with type `.wiredEthernet`, then pass that interface object directly to `NWParameters.requiredInterface`
- Mac side (C/Obj-C): Use `if_nametoindex("en7")` (or whatever interface NWPathMonitor reports) and set `sin6_scope_id` in the `sockaddr_in6` struct before calling `connect()` or `bind()`
- For service discovery over USB NCM: Use Bonjour/mDNS with `NSBonjourServices` declared — Bonjour handles scope correctly and will discover services on the link-local interface without manual IP address management
- Test with both IPv4 link-local (169.254.x.x) and IPv6 link-local (fe80::) — macOS may prefer one over the other depending on macOS version and interface configuration

**Warning signs:**
- `NWConnection` goes to `.failed` state immediately on wiredEthernet
- BSD socket `connect()` returns `ENETUNREACH` or `EHOSTUNREACH`
- Ping to fe80:: address works in Terminal but app connection fails (Terminal uses the correct scope ID automatically with `%en7` syntax)

**Phase to address:** Phase 1 (USB NCM Transport). Write a minimal two-device loopback test on USB NCM before implementing the full pipeline.

---

### Pitfall 3: IOSurface Recycling Corrupts In-Flight Metal Renders

**Severity: CRITICAL — Invisible frame corruption, hard to reproduce**

**What goes wrong:**
`ScreenCaptureKit` delivers frames as `CMSampleBuffer`/`CVPixelBuffer` backed by `IOSurface`. When the `CMSampleBuffer` is released (ARC or explicit release), its underlying `IOSurface` returns to the ScreenCaptureKit pool and can be reused for the NEXT frame immediately. If LZ4 compression or the send pipeline holds a reference to the IOSurface data (e.g., a raw pointer from `CVPixelBufferGetBaseAddress`) beyond the sample buffer's lifetime, it will read corrupted/partially-written data from the next frame being captured into the same surface.

**Why it happens:**
Developers lock the CVPixelBuffer (`CVPixelBufferLockBaseAddress`), get a raw pointer, pass it to `LZ4_compress_default()`, then release the pixel buffer — not realizing the lock is advisory and that releasing the sample buffer allows the surface to be recycled. If LZ4 compression runs on a background thread and the sample buffer is released on the capture callback thread before compression completes, the pointer is dangling.

**How to avoid:**
- Hold the `CMSampleBuffer` (or `CVPixelBuffer`) retain count for the ENTIRE duration of LZ4 compression — do not release until `LZ4_compress_default` returns
- Use `CMSampleBufferCreateCopy` if you need to pass the buffer across threads and cannot guarantee lifetime
- Alternative: Use `IOSurfaceLock`/`IOSurfaceUnlock` directly with `kIOSurfaceLockReadOnly` flag for the duration of the compress operation
- In the C compression path: treat the IOSurface pointer as valid only inside the lock/unlock pair; never cache the raw pointer across a potential release boundary
- Set `SCStreamConfiguration.queueDepth` to 3 (default) or 4 — higher values give more pipeline slack but use more RAM

**Warning signs:**
- Occasional corrupted frames with clean seams suggesting partial write-over (not noise corruption)
- Corruption reproducible only under load (multiple background apps capturing frames faster)
- Frame corruption disappears when compression is moved to main thread (serializes with release)

**Phase to address:** Phase 1 (Screen Capture + Compression). Unit test with LZ4 roundtrip against known frames before integrating into the real capture pipeline.

---

### Pitfall 4: Delta Frame XOR Race Condition on Reference Frame

**Severity: CRITICAL — Diverging decoder state, escalating corruption**

**What goes wrong:**
The delta frame scheme XORs the current frame against a reference (previous keyframe). If the reference frame buffer is mutated while a delta frame is being XORed against it (on the Mac: compressor starts new keyframe → updates reference buffer → simultaneously a delta frame read is in progress), the decoder receives a delta that was partially computed against the old reference and partially the new one. The XOR produces garbage. Since the decoder accumulates these deltas, every subsequent frame is corrupted until the next keyframe.

**Why it happens:**
The reference frame buffer is a shared mutable resource accessed by both the keyframe writer (copy new frame into reference) and the delta frame compressor (read reference for XOR). Without a reader-writer lock, these operations can interleave.

**How to avoid:**
- Maintain TWO reference frame buffers (double-buffer pattern): a "committed" reference (read-only for delta computation) and a "pending" reference (write target for the new keyframe). Atomically swap them only when the keyframe has been fully compressed and sent
- Use a `pthread_rwlock_t` (or `dispatch_semaphore_t`) around reference buffer access: readers (delta computation) take read lock, writers (keyframe copy) take write lock
- Rule: A new keyframe invalidates the reference buffer. Do not start computing a new delta until the new keyframe has been acknowledged as received by the iPad (or use a timer-based approach with a hard keyframe interval)
- In the binary protocol: include a `keyframe_seq` field that the decoder must match before applying a delta — if the delta references a keyframe seq the decoder hasn't received, discard it and request a new keyframe

**Warning signs:**
- Decoder state drifts over time, with corruption increasing between keyframe intervals
- Corruption appears only when the delta threshold is exceeded (fast-changing content) — not during static content
- Adding a sleep before delta computation causes corruption to disappear (masks the race)

**Phase to address:** Phase 1 (Compression + Protocol). Tested in `DeltaTests.c` with synthetic concurrent writes before integration.

---

### Pitfall 5: ProMotion 120Hz Requires Explicit Opt-In; MTKView Defaults to 60Hz

**Severity: HIGH — Silent 60Hz cap despite 120Hz hardware**

**What goes wrong:**
`MTKView.preferredFramesPerSecond = 120` is not sufficient to achieve 120Hz rendering on ProMotion iPads. Without `CADisableMinimumFrameDuration = YES` in Info.plist, the system clamps all `CADisplayLink`-based rendering to 60Hz. Even with the plist key set, `MTKView` must use `CAMetalDisplayLink` (not the built-in MTKView timer) for correct frame pacing at variable rates. Using MTKView's default timer at high frame rates produces uneven cadence (12ms-20ms-12ms instead of 8.3ms-8.3ms-8.3ms).

**Why it happens:**
ProMotion's variable refresh rate requires explicit opt-in at both the plist level and the rendering loop level. The plist key tells the system the app is ProMotion-aware. `CAMetalDisplayLink` provides a callback that fires at the display's actual cadence (which can vary from 24Hz to 120Hz dynamically) rather than a fixed interval timer.

**How to avoid:**
- Add `CADisableMinimumFrameDuration` key with value `YES` to Info.plist
- Use `CAMetalDisplayLink` instead of MTKView's built-in `preferredFramesPerSecond` for the render loop
- Use triple buffering (3 drawables) — 2 is documented as "basically impossible to make work" with the compositor
- Use a semaphore with count 3 to gate drawable acquisition so the render thread never stalls
- Present with `commandBuffer.present(drawable)` not `drawable.present()` directly — let Metal's scheduler handle presentation timing

**Warning signs:**
- FPS counter shows 60Hz even with `preferredFramesPerSecond = 120`
- Irregular frame intervals visible in Instruments (Time Profiler)
- Adding an Instruments capture causes stuttering due to frame timing sensitivity

**Phase to address:** Phase 2 (Metal Renderer). Verify with Instruments Frame Debugger before considering rendering complete.

---

### Pitfall 6: VideoToolbox Low-Latency HEVC Has Undocumented Incompatibilities

**Severity: HIGH — Silent bitrate control failure, encoder ignores constraints**

**What goes wrong:**
The `kVTCompressionPropertyKey_EnableLowLatencyRateControl` property (required for realtime streaming) cannot be combined with `kVTCompressionPropertyKey_ConstantBitRate`. Attempting to set both causes one to be silently ignored — typically the bitrate constraint, resulting in unconstrained output that floods the Wi-Fi channel. Additionally, `kVTCompressionPropertyKey_AverageBitRate` and `kVTCompressionPropertyKey_DataRateLimits` have been reported as having no effect on the hardware HEVC encoder in some macOS versions — the encoder produces variable bitrate output regardless.

**Why it happens:**
Apple's VideoToolbox hardware encoder has a different feature matrix than the software encoder. Properties that appear to be settable return `noErr` but are silently ignored if the hardware encoder doesn't support the combination. The documentation for low-latency rate control was added in WWDC21 but the interaction with bitrate properties is not documented.

**How to avoid:**
- Enable low-latency rate control in the `encoderSpecification` dictionary at session creation time, not as a property set post-creation
- Use only `kVTCompressionPropertyKey_AverageBitRate` for bitrate control with low-latency mode — not constant bitrate
- Verify actual encoder output rate experimentally by measuring bytes per second on the output side during Wi-Fi tests
- Do NOT set B-frame count properties when using low-latency mode — they conflict and the encoder may silently disable low-latency operation
- Test with `kVTCompressionPropertyKey_RealTime = true` (required for low-latency) — without this the encoder buffers multiple frames for quality optimization, blowing the 25ms latency budget

**Warning signs:**
- `VTCompressionSessionSetProperty` returns `noErr` but bitrate is unconstrained at runtime
- Frame intervals jump to 33ms+ under motion even with 60fps target (B-frame buffering)
- Wi-Fi channel saturates despite "set" bitrate limit

**Phase to address:** Phase 3 (Wireless/HEVC path). Benchmark actual output rate before declaring Wi-Fi mode operational.

---

### Pitfall 7: ScreenCaptureKit Audio Capture Fails Silently on macOS 15

**Severity: HIGH — Audio streaming silently produces no output**

**What goes wrong:**
On macOS 15 (Sequoia), attempts to capture system audio via `SCStream` with `capturesAudio = true` may fail with `SCStreamError` code -3805 (`connectionInvalid`) or simply produce no audio callbacks. The stream appears to start successfully, video frames arrive normally, but `stream(_:didOutputSampleBuffer:ofType:)` is never called for audio.

**Why it happens:**
macOS 15 changed audio capture internals. The preferred approach is now the CoreAudio Tap API (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`), available since macOS 14.4. ScreenCaptureKit's audio path was not reliably updated to match.

**How to avoid:**
- Use the CoreAudio Tap API for audio capture on macOS 14.4+: create a `CATapDescription`, use `AudioHardwareCreateProcessTap` to tap system output, wrap in an aggregate device, read via `AudioDeviceCreateIOProcIDWithBlock`
- Add `NSAudioCaptureUsageDescription` to Info.plist — required for the Tap API permission prompt
- Fall back to ScreenCaptureKit audio capture only on macOS 12-14.3 where the Tap API is unavailable
- Implement a capability detection path at startup: attempt CoreAudio Tap first, fall back to SCKit audio if it fails
- The Tap API does NOT require the Screen Recording permission — it uses Microphone permission category — this is an advantage over SCKit audio

**Warning signs:**
- `SCStream` audio type callbacks never fire despite `capturesAudio = true`
- No error in `stream(_:didStopWithError:)` — stream appears healthy
- Reproducible on macOS 15, works on macOS 14.x with same code

**Phase to address:** Phase 4 (Audio Streaming). Verify CoreAudio Tap API works before building the audio pipeline.

---

### Pitfall 8: Sequoia's Screen Recording Permission Prompt Fires on Every API Call Path

**Severity: HIGH — Blocks SCShareableContent for 3-10 seconds on first call**

**What goes wrong:**
On macOS Sequoia, calling `SCShareableContent.getWithCompletionHandler` sometimes blocks for 3-10 seconds or never calls the completion handler if the periodic re-authorization prompt is about to appear. This blocks the capture initialization path and can cause the agent to appear "hung" at startup.

**Why it happens:**
The SCKit permission check presents the re-authorization UI synchronously relative to the completion handler. If the user has dismissed the prompt or it is awaiting user interaction, the completion handler is deferred until the user responds (or times out).

**How to avoid:**
- Call `SCShareableContent.getWithCompletionHandler` on a background queue, not the main queue
- Implement a 5-second timeout on initial content enumeration; if the timeout fires, assume permission is pending and display a menu bar status indicating "Awaiting screen recording permission"
- After timeout, retry the enumeration every 30 seconds
- Do not block agent startup on SCKit initialization — start the network listener and pairing flow independently, then add SCKit streaming capability once permission is confirmed

**Warning signs:**
- Agent appears to launch but never starts streaming
- Completion handler called with empty content list on macOS 15
- Works immediately on macOS 14, hangs on macOS 15

**Phase to address:** Phase 1 (Screen Capture). Handle permission delays as a first-class state in the agent startup sequence.

---

## Moderate Pitfalls

### Pitfall 9: Local Network Permission Blocks UDP on First Launch

**Severity: MEDIUM — Requires user interaction, one-time**

**What goes wrong:**
On iPadOS 14+, sending the first UDP packet (or opening the first TCP connection) to a local network address triggers the "Would like to find and connect to devices on your local network" permission prompt. Until the user grants this, all local network sockets silently fail — no error is returned, packets are dropped. This affects the USB NCM interface even though it is a direct point-to-point connection, not a traditional LAN.

**How to avoid:**
- Add `NSLocalNetworkUsageDescription` to Info.plist with a clear explanation ("Required to connect to the Mac over USB")
- Add `NSBonjourServices` with your service type (e.g., `_keyd-rd._tcp`) if using Bonjour for discovery
- Do NOT use Bonjour for USB NCM transport (use fixed link-local address + stored port); but still declare the service type for the Wi-Fi fallback path
- Design the pairing flow to trigger the local network permission prompt early and explicitly (send a probe packet during pairing, not at session start)
- The permission is one-time per app install; once granted, subsequent launches work without prompting

**Warning signs:**
- UDP socket sends return 0 bytes written but no error
- NWConnection goes to `.waiting` state with `POSIXError.EPERM` or local network error
- Works on simulator, fails on physical device (simulator skips the permission check in Xcode 14+)

**Phase to address:** Phase 1 (Transport + Pairing). Test Local Network permission grant during initial pairing flow design.

---

### Pitfall 10: NWPathMonitor wiredEthernet Reports False Positives

**Severity: MEDIUM — May trigger USB NCM mode over wrong interface**

**What goes wrong:**
`NWPathMonitor` reports `.wiredEthernet` for ANY Ethernet-like interface, including USB Ethernet adapters (hubs, dongles) and the iPad's USB NCM link to the Mac. If the user has an Ethernet hub connected, `NWPathMonitor` will report wiredEthernet for both — and the wrong interface will be selected for the USB NCM transport, causing connection failures that look like USB NCM transport bugs.

**How to avoid:**
- Do not rely solely on `interfaceType == .wiredEthernet`; also check the interface's link-local address to confirm it is the Mac-connected NCM interface
- During pairing, exchange the Mac's USB NCM interface IP (link-local) with the iPad; store it and use it to identify the correct interface on subsequent connections
- Alternatively: use Bonjour service advertisement from the Mac on the NCM interface only (advertise with `interface` set to the specific NCM interface) and let the iPad discover via that specific interface

**Warning signs:**
- Transport fails intermittently when the user also has an Ethernet adapter connected
- `NWPathMonitor` reports multiple wiredEthernet interfaces simultaneously
- USB NCM transport works in isolation, fails when other adapters are present

**Phase to address:** Phase 1 (Transport). Include multi-interface detection in the USB NCM path implementation from the start.

---

### Pitfall 11: CGEvent Injection at 120-240Hz Triggers Accessibility Watchdog

**Severity: MEDIUM — Accessibility permission silently revoked or injection throttled**

**What goes wrong:**
Injecting CGEvents at 240Hz (one event per 4ms) is at the extreme high end of what macOS's accessibility subsystem expects. Under high CPU load (e.g., simultaneous LLM inference), the accessibility event queue can back up. macOS may throttle or drop injected events without error. Additionally, posting a high volume of mouse-move events can cause system behavior changes (e.g., hover tooltips flickering, UI elements responding to phantom moves).

**How to avoid:**
- Batch input events on the iPad before sending: if multiple mouse-move events accumulate in a 4ms window, send only the most recent position (the intermediate positions are not visible at 60Hz anyway)
- On the Mac injection side, use `CGEventPost(kCGHIDEventTap, event)` rather than `kCGSessionEventTap` — HID tap has lower overhead
- Implement adaptive batching: measure actual event injection rate vs target rate; if falling behind, drop intermediate move events (never drop clicks or key events)
- Test under load: run an LLM concurrently during input injection and verify event delivery fidelity

**Warning signs:**
- Mouse cursor movement on Mac is jerky despite smooth touch input on iPad
- Clicks are delivered but moves are dropped under load
- Accessibility permission disappears from System Preferences after heavy use (rare but documented)

**Phase to address:** Phase 2 (Input Handling). Build adaptive batching into the input pipeline from the start.

---

### Pitfall 12: SMAppService Login Item Registration Succeeds but Agent Doesn't Launch

**Severity: MEDIUM — Requires explicit user action to fix after OS upgrade**

**What goes wrong:**
`SMAppService.mainApp.register()` returns `.success` but the agent is not actually running after login. The `status` property shows `.enabled` but `launchctl list | grep keyd` shows nothing. This happens reliably after macOS upgrades and intermittently on fresh installs in macOS 13-15.

**Why it happens:**
SMAppService has documented bugs in macOS Ventura 13.6 and Sequoia where the launchd job is not correctly associated despite the API reporting success. The issue is especially common when the app bundle has been modified (code re-signed) since the last registration.

**How to avoid:**
- After registering, verify using `SMAppService.mainApp.status` — if `.notRegistered` or `.requiresApproval`, surface a menu bar alert to the user
- Implement a "Fix Launch at Login" menu bar option that calls `unregister()` followed by `register()` — this reliably resolves stuck registration state
- Check `status` after every launch; if the agent is running but the login item shows `.notRegistered`, re-register silently
- Do not rely on SMAppService alone for critical first-launch experience — include a manual launch option

**Warning signs:**
- Agent requires manual launch after OS upgrade
- `SMAppService.mainApp.status` returns `.enabled` but process is not in process list
- Registration works on first install but breaks after Xcode re-sign

**Phase to address:** Phase 1 (Agent Infrastructure). Test login item registration and re-registration on macOS 14 and 15.

---

### Pitfall 13: LZ4 Block Mode vs Frame Mode Confusion Causes Decompress Failures

**Severity: MEDIUM — Silent decompression failure or assert on iPad**

**What goes wrong:**
`lz4.c` (single-file vendored) exposes two distinct APIs: the block API (`LZ4_compress_default`, `LZ4_decompress_safe`) and the frame API (`LZ4F_*`). These are NOT interchangeable. Compressing with the block API on the Mac and attempting to decompress with the frame API on the iPad (or vice versa) produces an immediate error (-1 return or negative decompressed size). This is easy to mistake for a transport corruption issue.

**How to avoid:**
- Use the block API (`LZ4_compress_default` / `LZ4_decompress_safe`) exclusively for the hot path — it is simpler, has no header overhead, and operates on a single contiguous buffer matching the frame protocol design
- The frame API adds a 7-byte header and is designed for streaming files, not network datagrams
- Include a `compressed_size` field in the media frame header (it's already in the 24-byte header design as `size`) so the decompressor knows the exact byte count
- Write a `DeltaTests.c` test that compresses with block API and decompresses with block API on the same machine before testing cross-device

**Warning signs:**
- `LZ4_decompress_safe` returns a negative value (decompression failure)
- Decompression works in unit tests, fails over the wire (suggests the header is being parsed as data)
- Frame deserialization passes but decompressed size is wrong

**Phase to address:** Phase 1 (Compression + Protocol). Protocol unit tests must cover compress-decompress roundtrip before transport work begins.

---

### Pitfall 14: Touch-to-Mouse Coordinate Mapping Requires Affine Transform, Not Simple Scaling

**Severity: MEDIUM — Misaligned cursor, usability failure**

**What goes wrong:**
Naively mapping iPad touch coordinates to Mac screen coordinates using a simple scale factor (iPad width / Mac width) produces misaligned cursor behavior on Retina displays. The Mac may have multiple logical resolutions (Retina scaling, display zoom), and the iPad Metal renderer may add letterboxing or pillarboxing if aspect ratios differ. A touch at the bottom-right of the iPad screen does not map to the bottom-right of the Mac screen.

**Why it happens:**
There are three coordinate spaces in play: iPad touch coordinates (points), iPad Metal renderer coordinates (pixels, with potential letterbox offsets), and Mac screen coordinates (logical pixels, with Retina scale). Each transformation needs to be tracked independently.

**How to avoid:**
- Exchange Mac display geometry at connection time: send `{logicalWidth, logicalHeight, scaleFactor}` as part of the session handshake
- On the iPad side, compute the render viewport (accounting for aspect ratio letterboxing) and translate touch coordinates within the rendered content area first, then scale to Mac logical coordinates
- Use `CGDisplayBounds()` on the Mac to get the current display geometry (including Retina scale); send this to the iPad in the session handshake
- Test with both native resolution and scaled ("More Space" / "Larger Text") display settings on the Mac — these change `CGDisplayBounds` values
- Account for macOS dock and menu bar: the Mac mouse can go to (0,0) but the dock changes where application content starts — the mapping should cover the full Mac display (0,0) to (width, height), not the "safe area"

**Warning signs:**
- Cursor offset increases proportionally toward bottom-right corner
- Cursor works correctly until Mac display settings are changed
- Scrolling works but click position is wrong by a constant offset (suggests letterbox math is correct but offset from viewport edge is missing)

**Phase to address:** Phase 2 (Input Handling + Touch Translation). Validate coordinate mapping with a "cursor calibration" test before declaring input complete.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcode port 12345 for USB NCM | Simpler setup | Conflicts if keyd v1.0 also running | Never — use separate port (e.g., 12346) or negotiate |
| Skip DTLS on UDP media over USB | Less latency overhead | No integrity check on wired path; harder to add later | Never — TLS 1.3 mandatory per spec |
| Fixed reference frame buffer (no double-buffer) | Simpler code | Delta race condition (Pitfall 4) | Never — correctness is non-negotiable |
| Parse frame headers in Swift with Codable | Fast to implement | JSON in data path violates spec; ~50x slower than binary parse | Never — binary protocol is locked decision |
| Single dispatch queue for capture + compress | No synchronization code | Blocks capture delivery at 120fps | Never for >60fps; acceptable at 30fps eco mode only |
| Skip CoreAudio Tap, use only SCKit audio | One less API to learn | SCKit audio silently fails on macOS 15 (Pitfall 7) | Never for macOS 15+ primary target |
| Use NWInterface.InterfaceType check only | Simpler interface detection | Multi-adapter false positive (Pitfall 10) | Only in dev/test with known single-adapter setup |
| LZ4 frame mode instead of block mode | Easier streaming semantics | Frame/block API mismatch with binary protocol (Pitfall 13) | Never — block mode is correct for this use case |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| ScreenCaptureKit + Obj-C | SCStream's output delegate is held weakly in Sonoma+ | Store the delegate object in an ivar on the owning class, not a local variable |
| ScreenCaptureKit + Obj-C | Calling SCKit APIs from C functions | Wrap in `@autoreleasepool {}` blocks; SCKit returns Obj-C objects that ARC manages |
| VideoToolbox + Obj-C | Compression session callback fires on random thread | Never touch UIKit or AppKit from the VT callback; dispatch to main queue if needed |
| Network.framework + C | `nw_connection_t` is an Obj-C object under the hood | Use `nw_retain`/`nw_release` in C code; or wrap in Obj-C to use ARC |
| Metal + Swift | `MTLCommandBuffer` must be committed before the drawable is presented | Always call `commit()` before `present()`; reversing these silently drops frames |
| IOSurface + C | `IOSurfaceLock` must be matched with `IOSurfaceUnlock` | Use `IOSurfaceLock`/`Unlock` in a paired pattern even in error paths; missing unlock leaks surface |
| CGEvent + C | `CGEventRef` created with `CGEventCreate` must be released with `CFRelease` | No ARC for CoreFoundation types in C; track all CGEvent allocations manually |
| Bonjour on Mac + iPad | mDNS TTL too short causes repeated re-discovery | Set `txtRecord` TTL to 60+ seconds; use `SCContentSharingPicker` equivalent Bonjour approach for Wi-Fi fallback |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Copying IOSurface data instead of locking in-place | Mac CPU spikes to 5-8% during capture | Lock IOSurface, pass pointer directly to LZ4; never memcpy the frame data | Always — 4K frame is ~33MB/s at 60fps; memcpy adds ~15ms |
| Allocating LZ4 output buffer per frame | Heap fragmentation, latency spikes | Pre-allocate `LZ4_COMPRESSBOUND(srcSize)` buffers in a pool at startup | Above ~60fps with 4K frames |
| SCStreamConfiguration.queueDepth > 8 | Higher RAM but documented as unsupported | Keep at 3-4; Apple doc says ≤8 | Undefined behavior above 8 |
| Metal drawables requested before previous frame committed | GPU stall, frame queue backup | Use semaphore with count = 3 to gate drawable acquisition | Any consistent >120fps render attempt |
| LZ4 compress on main thread | App becomes unresponsive | Always compress on a dedicated high-priority background queue | Immediately at 4K resolution |
| Polling NSPasteboard at <500ms intervals | Clipboard monitoring wastes CPU | Poll at 500ms with `changeCount` comparison; skip if no change | Continuous polling wastes ~1% CPU for zero benefit |
| NWPathMonitor updates on background queue not dispatched to main | UI updates crash on background thread | Always dispatch UI changes to main queue in path update handler | Every time |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Cleartext UDP for media over USB (no DTLS) | Eavesdropping possible (unlikely over USB but violates spec) | DTLS 1.3 mandatory per RD-SEC-01; use NWProtocolDTLS |
| Self-signed certificate regenerated on every launch | Certificate pinning breaks daily; pairing needs re-done | Generate once during pairing, store in Keychain with kSecAttrAccessibleAfterFirstUnlock |
| Storing ECDH private key in UserDefaults | Key accessible without Keychain protection | Store in Keychain with `kSecClassKey`, access group matching bundle ID |
| No replay protection on UDP media stream | Attacker can replay old frames | Include sequence number in media header (already in spec as `seq` field); validate monotonic increase |
| Screen Recording permission granted to non-pinned TLS | Agent could be impersonated if certificate validation fails | Always validate certificate against pinned value from QR pairing exchange |

---

## "Looks Done But Isn't" Checklist

- [ ] **USB NCM Transport:** Often missing Local Network permission prompt handling — verify the app correctly requests and recovers from permission denial, and that the permission prompt fires during pairing (not silently dropped)
- [ ] **ScreenCaptureKit:** Often missing permission re-authorization handling for Sequoia monthly prompts — verify the agent detects capture stoppage and surfaces re-authorization to the user
- [ ] **Delta Frames:** Often missing keyframe request mechanism on iPad side — verify the iPad can request a fresh keyframe when decoder state is uncertain (e.g., after packet loss simulation)
- [ ] **Coordinate Mapping:** Often missing Retina scale factor exchange in session handshake — verify with a Retina Mac and a Mac with "Larger Text" display setting active simultaneously
- [ ] **ProMotion 120Hz:** Often missing `CADisableMinimumFrameDuration` plist key — verify with Instruments that frame delivery is actually at 120Hz and not capped at 60Hz
- [ ] **VideoToolbox HEVC:** Often missing actual bitrate validation — verify measured output bitrate matches target by measuring bytes per second on the receive side
- [ ] **Audio Sync:** Often missing video/audio timestamp alignment — verify audio and video timestamps both reference the same clock (use `mach_absolute_time` on Mac, synchronize to session start)
- [ ] **Failover:** Often missing state machine for transport degradation — verify USB→Wi-Fi failover completes within 2 seconds and input events are not dropped during transition
- [ ] **SMAppService:** Often missing re-registration after code signing — verify login item status after every Xcode re-sign cycle
- [ ] **IOSurface Lifetime:** Often not holding sample buffer retain count through LZ4 compression — verify with ASan or Instruments Allocations that no use-after-free occurs during compression

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| SCKit permission lapsed (Sequoia monthly prompt) | LOW | Add capture state monitoring; show menu bar "Re-authorize" prompt; test with tccutil reset on dev machine |
| Link-local binding failure | LOW | Add explicit interface binding from the start; do not attempt to retrofit |
| IOSurface use-after-free corruption | HIGH | Requires pipeline redesign; add retain/release accounting audit; requires physical device testing |
| Delta XOR race condition | MEDIUM | Introduce double-buffer for reference frame; add sequence validation in binary protocol |
| VideoToolbox ignoring bitrate | MEDIUM | Restructure session creation to set low-latency in encoderSpecification at create-time; re-test wireless path |
| USB NCM not viable (blocked by Apple policy) | HIGH | Fall back to usbmuxd TCP tunnel for media (lower throughput, ~500Mbps effective vs 5Gbps NCM); HEVC encode for wired mode instead of LZ4 |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| SCKit monthly re-auth (Pitfall 1) | Phase 1: Screen Capture | Verify with tccutil reset + SCKit stream start/stop cycle |
| Link-local binding (Pitfall 2) | Phase 1: USB NCM Transport | Two-device loopback test on USB NCM before pipeline work |
| IOSurface recycling (Pitfall 3) | Phase 1: Compression | LZ4 roundtrip test under concurrent capture load |
| Delta XOR race condition (Pitfall 4) | Phase 1: Compression + Protocol | DeltaTests.c with concurrent write simulation |
| ProMotion 120Hz opt-in (Pitfall 5) | Phase 2: Metal Renderer | Instruments Frame Debugger verification |
| VideoToolbox HEVC incompatibilities (Pitfall 6) | Phase 3: HEVC Wireless | Measured bitrate benchmark before declaring wireless mode complete |
| SCKit audio failure macOS 15 (Pitfall 7) | Phase 4: Audio Streaming | CoreAudio Tap API integration test on macOS 15 |
| SCKit permission delay at startup (Pitfall 8) | Phase 1: Agent Infrastructure | Startup timing test with permission prompt pending |
| Local Network permission (Pitfall 9) | Phase 1: Transport + Pairing | Physical device first-launch test |
| NWPathMonitor false positive (Pitfall 10) | Phase 1: USB NCM Transport | Test with Ethernet hub also connected |
| CGEvent injection throttling (Pitfall 11) | Phase 2: Input Handling | Load test with concurrent LLM process running |
| SMAppService bugs (Pitfall 12) | Phase 1: Agent Infrastructure | Re-sign + relaunch + verify login item status |
| LZ4 API mismatch (Pitfall 13) | Phase 1: Compression | Protocol unit test: compress block API → decompress block API |
| Touch coordinate mapping (Pitfall 14) | Phase 2: Input Handling | Calibration test with Retina + scaled display settings |

---

## Sources

- [Apple Developer Forums: USB CDC ECM or NCM device requirements](https://developer.apple.com/forums/thread/769793)
- [Apple Developer Forums: connect to device from iPad/iPhone over link-local](https://developer.apple.com/forums/thread/725414)
- [Apple Developer Forums: running 120Hz with low latency](https://developer.apple.com/forums/thread/763426)
- [ScreenCaptureKit Issue: SCStreamErrorDomain -3805 on macOS 15](https://github.com/ronaldoussoren/pyobjc/issues/647)
- [macOS Sequoia adds weekly screen recording permission prompt - 9to5Mac](https://9to5mac.com/2024/08/06/macos-sequoia-screen-recording-privacy-prompt/)
- [Michael Tsai: Sequoia Screen Recording Prompts and Persistent Content Capture](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/)
- [macOS Sequoia 15.1 reduces permission prompt frequency - iDownloadBlog](https://www.idownloadblog.com/2024/10/09/macos-sequoia-15-1-macos-screen-recording-prompts-frequency-reduced/)
- [TidBITS: How to Avoid Sequoia's Repetitive Screen Recording Prompts](https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/)
- [Jump Desktop: macOS Sequoia Screen Recording Policies](https://support.jumpdesktop.com/hc/en-us/articles/29070118000781-macOS-Sequoia-Screen-Recording-Policies-and-Jump-Desktop-Connect)
- [Apple Developer Documentation: Encoding video for low-latency conferencing](https://developer.apple.com/documentation/VideoToolbox/encoding-video-for-low-latency-conferencing)
- [WWDC21: Explore low-latency video encoding with VideoToolbox](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [OBS Studio Issue: RealTime VT property + bitrate limit causes frame drops](https://github.com/obsproject/obs-studio/issues/5840)
- [Apple Developer Documentation: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [AudioCap: Sample code for CoreAudio Tap API](https://github.com/insidegui/AudioCap)
- [Apple Developer Documentation: TN3179 Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple Developer Documentation: NWParameters.requiredInterface](https://developer.apple.com/documentation/network/nwparameters/requiredinterface)
- [Apple Developer Documentation: NWInterface.InterfaceType.wiredEthernet](https://developer.apple.com/documentation/network/nwinterface/interfacetype/wiredethernet)
- [WWDC21: Optimize for variable refresh rate displays](https://developer.apple.com/videos/play/wwdc2021/10147/)
- [Apple Developer Forums: ScreenCaptureKit SCStream startCapture fails](https://developer.apple.com/forums/thread/739809)
- [Apple Developer Forums: SMAppService login item registration](https://developer.apple.com/forums/thread/726826)
- [Synacktiv: iOS journey in the USB networking stack](https://www.synacktiv.com/en/publications/ios-a-journey-in-the-usb-networking-stack)
- [LZ4 Frame Format Description](https://android.googlesource.com/platform/external/lz4/+/HEAD/doc/lz4_Frame_format.md)

---
*Pitfalls research for: iPadOS-to-macOS remote desktop (keyd-rd)*
*Researched: 2026-03-27*
