# 08 — OS 26/27 platform changes for the keyd-rd streaming pipeline (2026-11-15)

Read-only research. No repo code was changed. Small throwaway probe programs were compiled and run in the
session scratchpad (not in the repo) to check what the M1 Max actually accepts on macOS 27.2.

## Method, versions, evidence tags

- Installed: **Xcode 27.2 (27B52)**, not 27.1 as the brief assumed. SDKs `MacOSX27.2.sdk`, `iPhoneOS27.2.sdk`.
  Host Mac: MacBook Pro 18,4, **Apple M1 Max**, macOS 27.2 (26B5101f). iPad: iPad Pro M4 (from planning docs).
- The last E2E commit on `main` (`f017d17`) is dated **2026-05-08**. No passing E2E run is recorded on 27.2. Several
  items below are "does the old code still do what it thinks on 27.2" questions that only an E2E run answers.
- Tags:
  - **[SDK-verified]**: symbol and availability read from the 27.2 SDK headers or swiftinterface.
  - **[probe: M1 Max, 27.2]**: measured by a scratch program on this Mac. It shows runtime behavior on this
    hardware only, not on the iPad, and not on other Macs.
  - **[docs]**: Apple documentation. This tier was mostly **unavailable**. `scripts/xcode-docs.sh` and the Xcode
    MCP `DocumentationSearch` both return "agent isn't approved to use Xcode's tools yet" until someone opens a
    workspace through mcpbridge once. The apple-docs MCP needs a technology-selection step that was not completed.
    SDK header doc comments are quoted instead and tagged [SDK-verified].
  - **[web/unverified]**: forum posts, third-party sources.
- Scope split: Section A covers APIs that are **new or changed in 26.x/27.x** (the brief). Section B covers
  **pre-existing APIs** that the 27.2 probes showed to be relevant or mis-used. They are kept separate on purpose.

## Ranked summary (expected payoff for quality / resolution / fps / latency)

| # | Item | New? | Touches | Expected payoff | Risk |
|---|---|---|---|---|---|
| 1 | `nw_tcp_set_max_pacing_rate` / `NWProtocolTCP.Metadata.setMaximumPacingRateBytesPerSecond` | **27.0** | `SessionManager.m` Wi-Fi TCP scheduler (`kWirelessTCPScheduler*`, lines 122-147), `WirelessTransport.m` media send | Moves Wi-Fi burst spreading into the kernel. Could replace the user-space sleep scheduler that the "sticky completion-guard clamps" problem lives in. Main win: Wi-Fi frame-pacing tails and fps | Medium. The cap is a ceiling only (min with cwnd/RTT). It needs a rate controller to choose the cap |
| 2 | The low-latency (LL) HEVC session rejects keys we set; the LL encoder silently drops frames when over budget | probe on 27 (behavior; whether it changed in 27 is unknown) | `HEVCEncoder.m` `_createSessionWithWidth…` (lines 133-176), `_hevcOutputCallback` (≈548) | Correctness and visibility. `MaxFrameDelayCount` and the `Quality` path are no-ops under LL. Dropped frames are invisible to the fps metrics | Low (logging plus removing dead settings) |
| 3 | Feed VT a native YUV format: SCStream `pixelFormat = '420v'` for the HEVC path, and iPad decoder output `420v` with a YUV→RGB shader | pre-existing | `ScreenCapture.m` (353, 576), `HEVCDecoder.swift` (27), `MetalRenderer.swift` / `Shaders.metal` | The LL encoder does not list BGRA as a native input, so VT converts BGRA→YUV internally on every frame. Indicative ~1.5-2 ms encode latency per frame at 2752×2064 (see caveats). Also less memory bandwidth on both ends | Low-medium. The LZ4/USB path needs BGRA, so the format depends on the codec. Re-check the `showMouseClicks` note (BGRA-only) |
| 4 | Non-LL "consistent quality" rate control: `kVTCompressionPropertyKey_ConstantQualityFactor` (27), `VariableBitRate`/`VBV*` (26), presets (26/27) | **26/27** | `HEVCEncoder.m` session setup | Possible text-quality win at equal or lower bitrate. All of these are **incompatible with LL**, so this is an LL vs non-LL trade that needs E2E measurement | Medium-high: non-LL may buffer or reorder. Must pin `AllowFrameReordering=false` and a short VBV |
| 5 | HEVC 4:4:4 10-bit (RExt) and 4:2:2 hardware encode on M1 Max, non-LL only, from SCStream `xf44` | pre-existing (verified on 27.2) | `ScreenCapture.m` pixelFormat, `HEVCEncoder.m` ProfileLevel, `HEVCDecoder.swift` | Removes 4:2:0 chroma fringing on colored text and UI. The biggest available visual-quality lever for desktop content | **Gated:** iPad M4 hardware decode of HEVC 4:4:4 / 4:2:2 is **not verified**. Higher bitrate. Non-LL only |
| 6 | macOS 27 "Remote Desktop" TCC category separate from Screen Recording | 27 (unverified) | `ScreenCapture.m` 276-288 (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`) | Risk item: the preflight may report "no access" when only the new category is granted | Unknown until tested on 27.2 |
| 7 | USB NCM discovery: interface-scoped DNS-SD | no new API in 26/27 | iPad `USBNetworkTransport.swift` (330-490), Mac `USBNetworkTransport.m` | Fixes "first USB launch has no peer address" without Wi-Fi bootstrap. Better USB availability, which means a higher-res, LZ4/120 fps path more often | Medium: on-device behavior not verified |
| 8 | iPadOS 26 windowing geometry callback, iOS 27 `systemPrefersReducedResourceUsage` | **26/27** | iPad `SessionManager.swift` viewport report, `MetalRenderer.swift` | Keeps the viewport-matched encode correct when the window is resized. Gives a sanctioned hint for dropping fps or bitrate | Low |
| 9 | `nw_path_get_link_quality` (26), Swift `NetworkConnection.onPathUpdate` (27), Swift `DTLS` (27) | **26/27** | Wi-Fi start-up bitrate seed; iPad path-change handling | Small: a better initial Wi-Fi operating point, and a path-update hook that the transport review found missing | Low |
| 10 | VT low-latency super-resolution / frame interpolation (26, limits API 27) | **26/27** | iPad decode→render | **Not usable at our sizes** (probe: max 1280 px source at 1.5×, 1920×1080 for interpolation, on M1 Max) | n/a |
| 11 | Metal 4 (`MTL4CommandQueue`), `CAMetalLayer.residencySet` (26), `CALayer.preferredDynamicRange` (26) | **26** | `MetalRenderer.swift` | Negligible for a one-quad renderer. Only relevant for an HDR future | Low |
| 12 | ScreenCaptureKit 26/27 additions | **26/27** | `ScreenCapture.m` | No new latency, queue-depth or resolution knobs. `isCapturing` (27) is a small state-check convenience | none |
| 13 | Input: no new Pencil/GCMouse/GCKeyboard/pointer-lock APIs for iPadOS in 26/27. 17.5 APIs are available | — | Phase 3 | Planning only | — |

Detailed notes follow, in rank order.

---

## A. New or changed in 26.x / 27.x

### A1. TCP pacing cap: `nw_tcp_set_max_pacing_rate` (rank 1)

- **API** [SDK-verified]: `int nw_tcp_set_max_pacing_rate(nw_protocol_metadata_t metadata, uint64_t max_pacing_rate)`,
  `API_AVAILABLE(anyappleos(27.0))`, `Network.framework/Headers/tcp_options.h:450`. Swift (iOS 27 swiftinterface):
  `NWProtocolTCP.Metadata.setMaximumPacingRateBytesPerSecond(_: UInt64?)`, `@available(anyAppleOS 27.0, *)`.
- **Semantics** (header doc): it caps TCP pacing. The on-wire rate is `min(cap, cwnd/sRTT)`, so the cap can never
  raise throughput. `0` or `UINT64_MAX` disables it. Values below 12,500 B/s are clamped up. It can be changed at
  any time on an established connection, and each call replaces the previous value.
- **Getting the metadata from C**: the header comment mentions `nw_connection_access_established_protocol_metadata`,
  but **that function is not in the 27.2 `connection.h`**. Use
  `nw_connection_copy_protocol_metadata(conn, nw_protocol_copy_tcp_definition())` (`connection.h:688`) after READY.
  [SDK-verified]
- **Our code**: the Mac Wi-Fi media path is HEVC over TCP+TLS. The burst problem is handled in user space by the
  `kWirelessTCPScheduler*` spacing and sleep machinery (`SessionManager.m:122-147`, the sends via `nw_connection_send`
  in `WirelessTransport.m:470/533/570`). Memory notes the current Wi-Fi stutter root as "sticky completion-guard
  derived scheduler clamps" in that scheduler.
- **What it buys**: the kernel spreads each frame's packets at a set rate (e.g. 1.2-1.5× the encoder's target
  bitrate) without app sleeps. That removes AP queue bursts without blocking the send queue, and could retire most of
  the clamp logic. The expected effect is a smaller Wi-Fi frame-interval p99 and fewer stutters. Latency cost: one
  frame of size S at pacing rate R takes S/R on the wire. A 300 KB keyframe at 25 MB/s takes 12 ms, about the same as
  what the app-level scheduler spends today.
- **Risk**: the cap is static per call. It needs an owner (the encoder bitrate controller) to set it, and it should be
  re-set on bitrate changes. Not tested on device. Not available on USB (and not needed there). Note that the TCP
  media path also stacks TLS records, so pacing is applied to TLS-framed bytes.

### A2. VideoToolbox rate-control additions (rank 4)

All [SDK-verified] in `VTCompressionProperties.h`, and the "compatible with LL?" column is [probe: M1 Max, 27.2]:

| Key | Availability | What | LL session (`hevc.rtvc`) | Non-LL (`ave.hevc`) |
|---|---|---|---|---|
| `kVTCompressionPropertyKey_ConstantQualityFactor` | macOS/iOS **27.0** | Target constant *visual* quality 0-1, designed to work with or without bitrate limits (unlike `Quality`, which pins QP) | **-12900 (not supported)** | accepted |
| `kVTCompressionPropertyKey_VariableBitRate` | **26.0** | VBR target. Header: incompatible with AverageBitRate, CBR, DataRateLimits, **and EnableLowLatencyRateControl** | -12900 | accepted |
| `kVTCompressionPropertyKey_VBVMaxBitRate` / `VBVBufferDuration` / `VBVInitialDelayPercentage` | **26.0** | VBV model. Default buffer 2.5 s and 90 % initial delay. The header warns a larger VBV "may introduce delay" | -12900 | accepted |
| `kVTCompressionPropertyKey_SupportedPresetDictionaries`, `kVTCompressionPreset_{HighQuality,Balanced,HighSpeed,VideoConferencing}` | **26.0** | Encoder-suggested settings | LL returns only `VideoConferencing = {AverageBitRate≈12.5M, EnableLTR=0, RealTime=1}` | Balanced/HighQuality/HighSpeed/ConsistentQuality. All use frame reordering and lookahead (4-16 frames), so none is usable as-is |
| `kVTCompressionPreset_ConsistentQuality` | **27.0** | `ConstantQualityFactor=0.5, LookAheadFrames=8, VBVBufferDuration=4 s` (probe) | n/a | listed |

- **Our code**: `HEVCEncoder.m:110-176` always creates an LL session (`EnableLowLatencyRateControl=YES`) and uses
  `AverageBitRate` (USB 100 Mbps, Wi-Fi `kWirelessHEVCBitrate`).
- **What it could buy**: a non-LL session with `RealTime=YES`, `AllowFrameReordering=NO`,
  `SuggestedLookAheadFrameCount=0` (accepted on non-LL, macOS 15+), `ConstantQualityFactor≈0.6-0.8`,
  `VBVMaxBitRate` = link budget and `VBVBufferDuration` ≈ 1-2 frames. That could hold text sharp during scrolling,
  where LL's average-bitrate controller currently starves frames. This is a hypothesis. **Measure g2g and frame
  sizes in E2E before adopting.** The non-LL path also lost `MaxFrameDelayCount` on this hardware (see B1), so its
  buffering cannot be pinned by that key.
- **Risk**: non-LL loses LL's guarantees (infinite GOP, no lookahead, temporal layers) and the LL frame-drop
  behavior. VBV underflow could show up as latency.

### A3. macOS 27 "Remote Desktop" privacy category (rank 6) [web/unverified]

- One developer-forums thread ([841530](https://developer.apple.com/forums/thread/841530)) reports a new **"Remote
  Desktop"** entry in Privacy & Security on macOS 27, separate from "Screen & System Audio Recording". The TCC service
  is `kTCCServiceRemoteDesktop`. The two are reported as **independent grants**, and
  **`CGPreflightScreenCaptureAccess()` reports only the Screen Recording grant**. An Apple DTS engineer replied that
  there is no API that returns the state of that privilege. The thread also mentions the
  `com.apple.developer.persistent-content-capture` entitlement (VNC-style apps, 14.4+, request form) without
  confirming that it governs the new category.
- Not found in the SDK headers (no symbol). Nothing found on what it gates beyond ScreenCaptureKit, and nothing on
  CGEvent posting.
- **Our code**: `ScreenCapture.m:276-288` gates on `CGPreflightScreenCaptureAccess()` and falls back to
  `CGRequestScreenCaptureAccess()`. If macOS 27 routes this agent into the Remote Desktop category, the preflight
  could return NO while capture works, or the reverse. Under the zero-ask workflow, verify with logging on the first
  27.2 E2E run: log preflight, request, and whether `SCShareableContent` succeeds.
- Related forum reports (unverified): `CGWindowListCreateImage` returns gray images on 27 betas
  ([849969](https://developer.apple.com/forums/thread/849969)). We don't use it.

### A4. iPadOS 26/27 scene and resource hints (rank 8) [SDK-verified]

- `-[UIWindowSceneDelegate windowScene:didUpdateEffectiveGeometry:]`, iOS **26.0** (`UIWindowScene.h:95`). With
  iPadOS 26 windowing, the app can be resized at any time. Our design is viewport-matched encoding
  (VIEWPORT_REPORT once after handshake), so a resize must re-send the viewport report, and the Mac must
  `updateConfiguration` SCStream and recreate the encoder. Check `iPadOS/App/SessionManager.swift`. Not reviewed
  here in detail. Info.plist has no `UIRequiresFullScreen`. Deployment target is iOS 17.0.
- `prefersInterfaceOrientationLocked` / `setNeedsUpdateOfPrefersInterfaceOrientationLocked`, iOS **26.0**
  (`UIViewController.h:756-759`). Locks orientation during a session, so the encode geometry doesn't flip.
- `UIApplication.systemPrefersReducedResourceUsage` plus a DidChange notification and a trait, iOS **27.0**
  (`UIApplication.h:185, 596`). A sanctioned signal to step down fps or bitrate (send a request to the Mac)
  instead of letting thermal throttling cause stutter.
- `-[UIWindowScene displayLinkWithTarget:selector:]`, iOS **27.0**: a scene-bound `CADisplayLink`. We use
  `CAMetalDisplayLink` (unchanged since iOS 17; `CAMetalDisplayLink.h` has no 26/27 additions), so no action.

### A5. Network.framework smaller additions (rank 9) [SDK-verified]

- `nw_path_get_link_quality(nw_path_t)` → `nw_link_quality_{unknown,minimal,moderate,good}`, 26.0 (`path.h:383`),
  Swift `NWPath.linkQuality`. The header says to use it "to tune initial values", not to gate connections. Use: seed
  `_wifiAdaptiveTargetBitrate` / fps at Wi-Fi session start (`SessionManager.m` ≈2705).
- `nw_path_is_ultra_constrained` / `nw_parameters_set_allow_ultra_constrained`, 26.0. Not relevant (satellite-class
  links).
- Swift `NetworkConnection` (26.0, structured-concurrency API), plus in **27.0**: `onPathUpdate`,
  `onViabilityUpdate`, `onBetterPathUpdate` for multiplex/QUIC connections, the `DTLS` protocol struct, and
  `NWProtocolFramer.Instance.prependApplicationProtocolIgnoringReady`. The iPad uses `NWConnection` (not
  `NetworkConnection`). Classic `NWConnection.pathUpdateHandler` already exists. The transport review (07) noted
  that neither side installs path-update handling. That is a gap in our use of existing API, not a new feature.
- **Not found**: any 26/27 addition to QUIC options (`quic_options.h` has no 26/27 markers), L4S/ECN (the
  `nw_ip_ecn_flag_*` metadata API is old), multipath (nothing new), or TLS (`SecProtocolOptions.h` /
  `SecProtocolMetadata.h` have no 26/27 markers).
- Wi-Fi Aware (`nw_error_domain_wifi_aware`, 26.0, `NWEndpoint.wifiAware`) is iOS-only; see 00-SYNTHESIS. Not a
  Mac path.

### A6. VT low-latency super-resolution / frame interpolation (rank 10)

- [SDK-verified] `VTLowLatencySuperResolutionScalerConfiguration` and `VTLowLatencyFrameInterpolationConfiguration`
  (macOS/iOS 26.0). In 27.0 they gain `supportedScaleFactors`, `maximumDimensionForSpatialScaleFactor:` and
  `maximumPixelCountForSpatialScaleFactor:`.
- [probe: M1 Max, 27.2, **Mac limits, not iPad**]: super-res source max 1280×1280 at 1.5×, 960 at 2×, 480 at 4×.
  `supportedScaleFactorsForFrameWidth:1376 frameHeight:1032` is empty. Frame interpolation (temporal only) max
  source 1920×1080. 2× spatial+temporal max 640.
- Verdict: cannot upscale a capped Wi-Fi encode (e.g. 1376×1032) to 2752×2064 or interpolate a full-res desktop.
  Re-check the limits on the iPad M4 with the same class methods before ruling it out. Interpolation also adds at
  least a half-frame of latency by design.

### A7. Metal / Core Animation (rank 11) [SDK-verified]

- Metal 4 (`MTL4CommandQueue` etc., iOS/macOS 26.0). `CAMetalLayer.residencySet` (26.0) exists for MTL4 residency.
  Our renderer (`MetalRenderer.swift`) is one textured quad per frame on a classic `MTLCommandQueue`. No
  measurable latency gain is expected from MTL4.
- `CALayer.preferredDynamicRange` / `CADynamicRange*` and `contentsHeadroom` (26.0). `wantsExtendedDynamicRangeContent`
  is now `API_DEPRECATED("Use preferredDynamicRange instead", macos(14.0, 26.0), ios(17.0, 26.0))`. We don't use EDR
  (layer is `bgra8Unorm`, Display P3), so nothing breaks. Only relevant if HDR capture is pursued.

### A8. ScreenCaptureKit 26/27 (rank 12) [SDK-verified]

- New in 27.0: `SCStream.isCapturing`, `SCStreamFrameInfoVideoOrientation`, `SCClipBufferingOutput`,
  `SCRecordingEditor`, `SCContentSharingPicker.available`, error codes `SCStreamErrorInsufficientStorage (-3822)`
  and `SCStreamErrorNotSupported (-3823)`. ScreenCaptureKit also now exists on **iOS 27** (SCStream marked
  `ios(27.0)`). That is irrelevant here (iPad isn't captured), and forum posts say it needs a
  `com.apple.developer.screen-recording` entitlement ([856067](https://developer.apple.com/forums/thread/856067),
  unverified).
- New in 26.0: `SCScreenshotConfiguration` / `SCScreenshotOutput` (screenshots only), and preset
  `SCStreamConfigurationPresetCaptureHDRRecordingPreservedSDRHDR10`.
- **Unchanged since 12.3-15.2**: `queueDepth`, `minimumFrameInterval`, `captureResolution`, `pixelFormat`,
  `showsCursor`, `captureDynamicRange` (15.0), `streamDidBecomeActive/Inactive` (15.2). **Not found**: any new
  lower-latency, IOSurface-delivery or frame-pacing knob for SCStream in 26 or 27.

### A9. Input for Phase 3 (rank 13) [SDK-verified]

- No iPadOS 26/27 additions in `UIPencilInteraction.h`, `UITouch.h`, `UIHoverGestureRecognizer.h`,
  `UIPointerLockState.h`. All Pencil Pro APIs are iOS **17.5**: `UIPencilInteraction` squeeze/tap with phases,
  `preferredSqueezeAction`, `prefersHoverToolPreview`, `UITouch.rollAngle` (barrel roll),
  `UIHoverGestureRecognizer.rollAngle`. Pointer lock: `UIViewController.prefersPointerLocked` (iOS 14).
- GameController: only `GCEventInteraction.receivesEventsInView` (iOS 26.0) and visionOS stylus additions. No
  GCMouse/GCKeyboard changes found.
- macOS CoreGraphics: **no 26/27 changes** in `CGEvent*.h` / `CGRemoteOperation.h` (no tablet-event additions found).

---

## B. Pre-existing APIs that matter on 27.2 (probe findings)

### B1. LL HEVC session: keys we set are silently rejected (rank 2) [probe: M1 Max, 27.2]

Creating `kCMVideoCodecType_HEVC` with `kVTVideoEncoderSpecification_EnableLowLatencyRateControl=YES` at 2752×2064
selects encoder **`com.apple.videotoolbox.videoencoder.hevc.rtvc`**. Without LL it selects `…ave.hevc`
(`UsingHardwareAcceleratedVideoEncoder=1`). `VTSessionSetProperty` results:

| Key | LL (`hevc.rtvc`) | non-LL (`ave.hevc`) | Our code |
|---|---|---|---|
| `MaxFrameDelayCount = 0` | **-12900** | **-12900** | set at `HEVCEncoder.m:143`, result unchecked. The comment claims it removes ~16 ms. On 27.2/M1 Max it does nothing in either mode |
| `Quality` | **-12900** | ok | set when `quality > 0` (`HEVCEncoder.m:153`). Production passes 0 today, but the "quality-based was tried" history (`SessionManager.m:2690`) could not have applied under LL |
| `PrioritizeEncodingSpeedOverQuality` | **-12900** | ok | not set. Note the SDK header's own "ultra-low-latency" recipe recommends it, but the LL encoder rejects it here |
| `OutputBitDepth = 10` | -12900 (LL is 8-bit only) | ok | — |
| `SpatialAdaptiveQPLevel` (15.0) | -12900 (header: must be disabled under LL) | ok | — |
| `SuggestedLookAheadFrameCount` (15.0) | -12900 | ok | — |
| `MaximumRealTimeFrameRate` (15.0) | -12900 | ok | — |
| `AverageBitRate`, `DataRateLimits`, `ExpectedFrameRate`, `AllowFrameReordering=NO`, `MaxKeyFrameIntervalDuration`, `ColorPrimaries` | ok | ok | — |
| `EnableLTR`, `ReferenceBufferCount`, `BaseLayerFrameRateFraction` | ok | -12900 | — |
| `MinAllowedFrameQP`, `MaxAllowedFrameQP` | ok | ok | — |
| `SupportsBaseFrameQP` | true | — | — |

- Whether these rejections are **new in 27** cannot be told from here (no pre-27 baseline was captured). Treat it as
  "true on the hardware and OS we ship on".
- **LL frame dropping**: in a synthetic high-entropy run at 120 fps and 100 Mbps, the LL encoder returned
  `status == noErr` with a **NULL sample buffer** for most frames (only 32-43 of 120 produced output for
  420v/444v/x420 input). `_hevcOutputCallback` (`HEVCEncoder.m` ≈548) treats NULL as "informational" and returns
  silently, so encoder drops never show up in METRICS. Cheap fix: count `infoFlags & kVTEncodeInfo_FrameDropped`
  and NULL buffers and log them per second. That bears directly on the fps and frame-pacing metrics.
- The LL supported-property dictionary also lists `NumberOfSubFrameSections`, `NumberOfSlices`,
  `RequestedMaxEncoderLatency`, `PeriodicRefreshMode`, `EnableFrameDropping`, `ThroughputMode`, `QualityMode`.
  **These are private, undocumented keys** with no public constants. Don't build on them. Public sub-frame or slice
  output: **not found**.
- Also present for loss recovery (pre-existing, 12.0, LL-accepted): `EnableLTR` +
  `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens` / `ForceLTRRefresh` and
  `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`. The iPad acks received LTR frames, and loss recovery
  then refreshes from an acked LTR instead of a full IDR. That would cut the 100 KB+ keyframe bursts that the
  `MaxKeyFrameIntervalDuration=300` comment cites as a Wi-Fi problem. It needs a protocol message.

### B2. Native YUV input instead of BGRA (rank 3) [probe: M1 Max, 27.2] + [SDK-verified]

- `VideoEncoderPixelBufferAttributes` for the **LL** session lists 420v/420f, x420/xf20, 444v/444f, x444/xf44, L008/L010
  and lossless-compressed `&8v0/&8f0/&xf4/&xv4/&xf0`. **It does not list BGRA**, so a BGRA buffer is converted
  inside VT before encoding. The non-LL list doesn't include BGRA either.
- SCStream supports `'420v'`, `'420f'`, `'x420'`, `'xf44'`, `'l10r'`, `'RGhA'`, `'BGRA'`
  (`SCStream.h:243-251`). We set `kCVPixelFormatType_32BGRA` at `ScreenCapture.m:353` and `:576` ("RD-CAP-06:
  BGRA throughout"). BGRA is right for the LZ4/USB path. For the HEVC path, `420v` (or `420f`) hands the encoder
  its native format and SCStream does the conversion in its compositor pass.
- Indicative numbers, synthetic content, **non-LL rows only** (LL rows dropped frames and are not comparable):
  2752×2064 at 120 fps PTS, mean submit→output 15.7 ms (BGRA) vs 13.9 ms (420v), 120/120 frames each. Treat this as
  "~1-2 ms per frame, worth an E2E A/B", not as a measured win. The synthetic `fill()` ran between submits, so
  the encoder was never saturated.
- iPad side: `HEVCDecoder.swift:27` asks the decoder for `kCVPixelFormatType_32BGRA`, which makes VT convert after
  decode. Requesting `420v` (bi-planar) and sampling Y and CbCr textures in `Shaders.metal` (two
  `CVMetalTextureCacheCreateTextureFromImage` calls, one matrix in the fragment shader) removes that pass. Expected:
  a small decode→present latency cut and less bandwidth on the M4. Not measured.
- `showMouseClicks` "currently applies when pixelFormat is set to BGRA" (`SCStream.h:277`). We don't use it.

### B3. HEVC 4:4:4 / 4:2:2 hardware encode (rank 5) [probe: M1 Max, 27.2]

Non-LL `ave.hevc`, `RequireHardwareAcceleratedVideoEncoder=YES`, 2752×2064, output `hvcC` parsed:

| Input | ProfileLevel | chroma_format_idc | bit depth |
|---|---|---|---|
| `xf44` (what SCStream can deliver) | **unset** | **3 (4:4:4)** | 10 |
| `xf44` | `HEVC_Main_AutoLevel` (what `HEVCEncoder.m:135` sets) | 1 (4:2:0) | 8 |
| `xf44` | `HEVC_Main10_AutoLevel` | 1 | 10 |
| `xf44` | `HEVC_Main42210_AutoLevel` | 2 (4:2:2) | 10 |
| BGRA | `HEVC_Main42210_AutoLevel` | 2 (4:2:2) | 10 |
| any | LL session | always 1 (4:2:0), 8-bit | — |

- There is **no public `kVTProfileLevel_HEVC_*444*` constant** [SDK-verified]. 4:4:4 comes from leaving the profile
  unset with 4:4:4 input.
- **What it buys**: full-resolution chroma. Colored text, syntax highlighting and thin colored UI lines stop
  smearing. For a desktop stream that is the largest quality step left after resolution.
- **Gates**: (1) iPad M4 hardware decode of HEVC RExt 4:4:4 10-bit and 4:2:2 10-bit is **not verified**. It needs an
  on-device check (decode one frame and see whether `VTDecompressionSessionCreate` succeeds with hardware, and how
  fast). (2) Non-LL only, so it inherits the A2 trade-offs. (3) Bitrate rises (379 KB vs 218 KB per synthetic frame,
  4:4:4 vs 4:2:0 8-bit).

### B4. Codecs not available on this Mac [probe: M1 Max, 27.2]

- AV1 encode: **no encoder** (`VTCompressionSessionCreate` returns -12908 non-LL and -12902 LL). Don't plan around
  AV1 on this Mac.
- ProRes hardware encoders exist (`appleproreshw.422/422hq/422lt/422proxy/4444/4444xq`), but ProRes bitrates
  (hundreds of Mbps at this resolution) are not realistic even on USB, and the iPad would need ProRes decode.
- H.264 LL exists (`avc1`). Not useful vs HEVC.

### B5. USB NCM discovery (rank 7)

- **No 26/27 additions** to `dns_sd.h` (no new availability markers; `_DNS_SD_H 3111040045`) or to Network.framework
  interface APIs [SDK-verified]. `NWInterface` still has **no public initializer** (only `name`, `index`, `type` from
  a path or endpoint) [SDK-verified].
- Existing ways to discover the Mac only over the USB link (none verified on device):
  1. `DNSServiceBrowse` / `DNSServiceResolve` / `DNSServiceGetAddrInfo` with `interfaceIndex = if_nametoindex(<NCM
     ifname from getifaddrs>)`. The Mac registers with `DNSServiceRegister` on its NCM interface index (or on all
     interfaces). This is the most direct fit for our getifaddrs-based detection.
  2. Unscoped `NWBrowser` for `_keydrd._tcp` with `includePeerToPeer` **off**. Each result endpoint
     `.service(name:type:domain:interface:)` carries the `NWInterface` it was seen on. Pick the one whose
     `interface?.name` equals the NCM ifname, and connect with that endpoint. The browser already exists in
     `WirelessTransport.swift:279-282`, but it is suspended during an active session (per review 07).
- Both sides currently scan **only `AF_INET`** (169.254/16) (`iPadOS/Transport/USBNetworkTransport.swift:357,489`,
  `macOS/Transport/USBNetworkTransport.m:340`). IPv6 link-local (`fe80::%ifname`) is always present on an NCM link
  and is what mDNS will often resolve to. Scoped resolution handles the zone (`%ifindex`) correctly.
- Requirements already in place: `NSLocalNetworkUsageDescription` and `NSBonjourServices = _keydrd._tcp` in the
  iPad Info.plist. No multicast entitlement is needed for Bonjour.
- [web/unverified] A Linux patch (May 2026, verified on macOS 26.5) says Apple Silicon Macs expose CDC-NCM over USB-C
  "the same protocol Apple already ships on iPhone and iPad"
  ([lkml](https://lkml.iu.edu/2605.2/08132.html)). Nothing iPadOS-27-specific was found on USB networking or Wi-Fi.

### B6. Deprecations and breakage risk on 27.x

- `OSAtomicIncrement32Barrier` / `OSAtomicDecrement32Barrier` / `OSAtomicAdd32Barrier`
  (`ScreenCapture.m:9,1401-1431`; `SessionManager.m:1140-1364`): deprecated with
  `OSATOMIC_BARRIER_DEPRECATED_REPLACE_WITH(atomic_fetch_add)` (`libkern/OSAtomicDeprecated.h:181`). They are
  **still present and not removed** in the 27.2 SDK. Warnings only. `HEVCEncoder.m` already uses `<stdatomic.h>`.
  Low-risk mechanical migration.
- `CALayer.wantsExtendedDynamicRangeContent` deprecated in 26 (not used by us).
- `MTL4CommandQueueErrorDeviceRemoved` deprecated in 27 (not used).
- `MaxFrameDelayCount` rejected (B1): a silent behavior gap, not a build break.
- Screen-recording TCC (A3): the most likely real-world break on 27.x, unverified.
- Not found: any 26/27 deprecation of `SCStream` APIs we use, `CAMetalDisplayLink`, `VTDecompressionSession`,
  `nw_*` C APIs, or `getifaddrs`.

---

## Suggested order of experiments (each needs an E2E A/B; nothing here is measured end to end)

1. Instrumentation only (no behavior change): log the `VTSessionSetProperty` status for every key; count
   encoder-dropped frames (NULL buffer / `kVTEncodeInfo_FrameDropped`); log the SCK/TCC preflight result on 27.2.
   Then run the canonical Wi-Fi E2E on 27.2 to get a baseline. None exists since 2026-05-08.
2. Wi-Fi: `nw_tcp_set_max_pacing_rate` on the media TCP connection, with the user-space scheduler spacing relaxed.
   Compare p99 frame interval and stutter counts.
3. HEVC path: SCStream `420v` and iPad decoder `420v` with a shader-side conversion.
4. Quality branch (USB first): non-LL session with `ConstantQualityFactor` + short VBV + no reordering, then the
   4:4:4 variant with `xf44` capture **only after** an iPad 4:4:4 decode check.
5. USB bootstrap via interface-scoped DNS-SD.

## Sources

- SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/{MacOSX,iPhoneOS}.platform/Developer/SDKs/*27.2.sdk`
  (VideoToolbox, ScreenCaptureKit, Network (C headers and iOS swiftinterface), QuartzCore, Metal, UIKit,
  GameController, CoreGraphics, Security, `usr/include/dns_sd.h`, `libkern/OSAtomicDeprecated.h`).
- Probes (scratch, not in the repo): `/private/tmp/claude-501/-Users-user-Documents-projects-keyd/98c9a4d6-825e-4836-9f77-239f36476808/scratchpad/vtprobe/`
  `probe.m`/`out.txt` (encoder list, supported keys, presets), `probe2.m`/`out2.txt` (LL vs non-LL key acceptance,
  pixel formats), `probe3.m`/`out3.txt` (synthetic encode run: chroma, drops; latency indicative only),
  `probe4.m` (VT low-latency SR/FI limits), `probe5.m` (xf44 → 4:4:4 / 4:2:2 by profile). They ran outside the
  Bash sandbox, because inside it VT cannot reach the hardware encoders.
- Web: [Apple forums 841530 — macOS 27 "Remote Desktop" TCC](https://developer.apple.com/forums/thread/841530);
  [849969 — CGWindowListCreateImage on 27](https://developer.apple.com/forums/thread/849969);
  [856067 — ScreenCaptureKit on iOS 27 entitlement](https://developer.apple.com/forums/thread/856067);
  [dotnet/macios PR 26208 — binds `nw_tcp_set_max_pacing_rate`, Xcode 27.0 b3](https://github.com/dotnet/macios/pull/26208);
  [LKML cdc_ncm Apple Mac USB-C quirk](https://lkml.iu.edu/2605.2/08132.html).
- Not found: WWDC26 session pages or 27.x release notes covering VideoToolbox, ScreenCaptureKit or Network
  changes (searches returned only WWDC21/25 material).
