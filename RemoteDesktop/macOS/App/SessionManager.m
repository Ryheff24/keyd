#import "SessionManager.h"
#import "ScreenCapture.h"
#import "FrameCompressor.h"
#import "HEVCEncoder.h"
#import "USBNetworkTransport.h"
#import "WirelessTransport.h"
#import "UDPChunker.h"
#import "PairingManager.h"
#import "InputInjector.h"
#import "InputTestHarness.h"
#import "protocol.h"

#import <os/log.h>
#import <os/lock.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <limits.h>
#include <unistd.h>

/* NSWindow subclass that closes on Escape key */
@interface QRWindow : NSWindow
@end
@implementation QRWindow
- (void)cancelOperation:(id)sender { [self close]; }
@end

@interface StressPatternView : NSView
@property (nonatomic, assign) uint64_t frameIndex;
@end

@implementation StressPatternView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGFloat scale = self.window.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0.0) scale = 1.0;

    CGContextSaveGState(ctx);
    CGContextScaleCTM(ctx, 1.0 / scale, 1.0 / scale);
    KeydRenderStressScene(ctx,
                          CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale),
                          self.frameIndex);
    CGContextRestoreGState(ctx);
}
@end

static os_log_t sLog;

/* Reconnection backoff intervals (seconds) */
static const NSTimeInterval kReconnectIntervals[] = { 0.5, 1.0, 2.0, 4.0, 8.0 };
static const int kReconnectMaxAttempts = 5;

/* Eco mode constants */
static const int kEcoWidth  = 1920;
static const int kEcoHeight = 1080;
static const int kEcoFPS    = 30;
static const int kEcoBitrate = 8000000; /* 8 Mbps */
/* Wireless capture/encode rate. Default 60; `-wireless-fps N` (30..120) overrides it per launch
 * for measurement (the E2E source video is 120 fps, so 60 caps AWDL at half the goal). */
static int WirelessMaxFPSSetting(void) {
    static int value = 60;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:@"wireless-fps"];
        if (n >= 30 && n <= 120) value = (int)n;
    });
    return value;
}
#define kWirelessHEVCFPS (WirelessMaxFPSSetting())
static const int kWirelessHEVCBitrate = 10000000; /* 10 Mbps — reasonable WiFi LAN starting point */
/* AWDL target (WiFiRateControl T on AWDL). Run a470989 on AWDL: target 10 Mbps, actual ~7 Mbps
 * (16 KB/frame at 56 fps), visibly soft; big frames moved at p10 27 / p50 59 Mb/s. 20 Mbps keeps a
 * frame's air time (~12 ms at 27 Mb/s) under the 16.7 ms interval. Infrastructure keeps 10: its
 * 512 TU receive holds already cap it (ddfd000 at 20-30 Mbps fell to 29 fps).
 * 2026-11-16 trial: 30 Mbps. Encode bench (prores test movie, busy part): worst-decile luma PSNR
 * 37 dB at 20 Mbps vs 43 dB at 30; encode time unchanged; frame p99 238 -> 283 KB. */
static const int kAWDLHEVCBitrate = 30000000;
static const int kWirelessAdaptiveMinFPS = 30;
static const int kWirelessAdaptiveMidFPS = 52;
#define kWirelessAdaptiveMaxFPS (WirelessMaxFPSSetting())
static const int kWirelessAdaptiveMinBitrate = 5000000;  /* 5 Mbps floor — readable text at 2496x1620 */
static const int kWirelessAdaptiveMaxBitrate = 30000000; /* 30 Mbps ceiling — LAN WiFi can handle this */
static const int kWirelessAdaptiveBitrateStepDown = 1500000; /* 1.5 Mbps — proportional to new range */
static const int kWirelessAdaptiveBitrateStepUp = 500000;    /* 500 kbps — reach 30 Mbps in ~40 healthy seconds */
static const uint64_t kWirelessAdaptiveDownshiftCooldownMs = 1200;
static const uint64_t kWirelessAdaptiveRecoveryHoldMs = 5200;
static const uint64_t kWirelessAdaptiveFastRecoveryHoldMs = 1800;
static const int kWirelessAdaptiveFPSStepUp = 2;
static const int kWirelessAdaptiveFPSStepDownSevereSoft = 6;
static const int kWirelessAdaptiveUpshiftHealthyStreak = 10;
static const int kWirelessAdaptiveFastUpshiftHealthyStreak = 3;
static const int kWirelessAdaptiveMildCongestionStreak = 4;
static const int kWirelessAdaptiveSevereEscalationStreak = 3;
static const int kWirelessAdaptiveMaxUpshiftFPSDelta = 2;
static const int kWirelessAdaptiveFastMaxUpshiftFPSDelta = 4;
static const int kWirelessAdaptiveMaxUpshiftBitrateDelta = 500000;  /* match step size */
static const int kWirelessAdaptiveMaxDownshiftFPSDelta = 6;
static const int kWirelessAdaptiveMaxDownshiftBitrateDelta = 3000000; /* fast downshift on congestion */
/* Burst-density guardrails: oversized HEVC frames create long-tail TCP completion
 * spikes and downstream starvation windows even with low average bitrate.
 * Scaled for 30 Mbps ceiling — at 60fps, average frame is ~62 KB. */
static const int32_t kWirelessBurstTailFrameBytes = 500 * 1024;
static const int32_t kWirelessBurstSevereFrameBytes = 1000 * 1024;
static const double kWirelessBurstTailDensityRatio = 8.0;
static const double kWirelessBurstSevereDensityRatio = 12.0;
static const int32_t kWirelessBurstTailFrameCountThreshold = 3;
static const int32_t kWirelessBurstSevereFrameCountThreshold = 1;
static const uint32_t kWirelessMaxEncodeWidth = 2496;
static const uint32_t kWirelessMaxEncodeHeight = 1620;
/* AWDL encode cap. Native size (2752x2064 cap, run 2dfcccb, 2026-11-16) removed the iPad's ~1.1x
 * upscale but HEVC encode went to ~16-17 ms a frame (over the 16.7 ms interval at 60 fps):
 * pipeline median 32 -> 41 ms, g2g 53 -> 62 ms vs 4cc1c70, fps unchanged. Kept at 2496x1620 until
 * encode time drops (the hardware encoder rejects PrioritizeEncodingSpeedOverQuality). */
static const uint32_t kAWDLMaxEncodeWidth = 2496;
static const uint32_t kAWDLMaxEncodeHeight = 1620;
/* Keep wireless media on the established TLS/TCP stream. This removes the
 * paced-DTLS chunk backlog that was inflating tail latency/jitter on Wi-Fi
 * and keeps reconnect/rotation behavior aligned to a single transport socket. */
static const BOOL kWirelessUseTCPMedia = YES;
static const NSUInteger kWirelessLargeFrameChunkThreshold = 320;
static const NSUInteger kWirelessMaxQueuedChunks = 384;
static const NSUInteger kWirelessMildCongestionChunkThreshold = 128;
static const NSUInteger kWirelessSevereCongestionChunkThreshold = 224;
static const uint64_t kWirelessMildCongestedFrameIntervalUs = 16667;  /* ~60fps cadence */
static const uint64_t kWirelessSevereCongestedFrameIntervalUs = 20000;/* stronger smoothing */
static const uint64_t kWirelessPacingToleranceUs = 1500;         /* tolerate source timestamp jitter around cadence */
/* Maximum in-flight TCP sends for Wi-Fi media path.
 * Bounds kernel queue depth to avoid stale-frame tail latency and jitter. */
static const int32_t kMaxMediaSendsInFlightWiFi = 3;
/* Wi-Fi ack gate (tla/WiFiSendLoop.tla AckGate). A send completion only means the kernel took the
 * bytes (run 8148018: completion p50 1 ms after submit, iPad last byte p90 161 ms after completion),
 * so the in-flight count above never sees the socket queue. Once the iPad acknowledges frames
 * (KEYDRD_INPUT_FRAME_ACK), a capture is encoded only while sent-but-unacked frames < this.
 * The gate caps throughput at depth / ack RTT: at 3, run b95e17d's slow windows (RTT p50 ~99 ms
 * during link holds) were held to ~30 fps. TLAPS (WiFiSendLoopProofs) covers any depth. */
/* `-wifi-ack-gate N` (1..32) overrides the depth per launch for measurement. The gate counts frames,
 * so at 120 fps the same depth covers half the time. */
static int32_t WiFiAckGateFramesSetting(void) {
    static int32_t value = 5;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:@"wifi-ack-gate"];
        if (n >= 1 && n <= 32) value = (int32_t)n;
    });
    return value;
}
#define kWiFiAckGateFrames (WiFiAckGateFramesSetting())
/* Rate under the ack gate (tla/WiFiRateControl.tla). Gate holds are pacing, not congestion: the
 * frame rate stays at kWirelessAdaptiveMaxFPS and the bitrate steps toward the fixed
 * kWirelessHEVCBitrate; the gate skips captures the link cannot take. A bitrate following
 * ack-measured delivery was tried (run ddfd000) and rejected: after a link hold queued frames
 * arrive at radio burst speed, samples read 40-460 Mb/s, and 20-30 Mbps frames cost fps. The
 * delivery samples (frames of at least kWiFiAckSampleMinBytes, iPad-clock spans) stay as a log
 * diagnostic only. */
static const uint32_t kWiFiAckSampleMinBytes = 24 * 1024;
static const int32_t kWiFiAckRateStepUp = 2000000;
/* Completion latency above this indicates kernel/network backlog in Wi-Fi TCP path. */
static const uint64_t kWirelessTCPSlowCompletionThresholdMs = 25;
/* The post-encode drop with its keyframe request and the in-flight stall reset are gone
 * (tla/WiFiSendLoop.tla NoPostDrop, NoBlindReset). The adaptive controller still reads the
 * last stall-recovery time, which now stays 0. */
static const uint64_t kWirelessTCPPostRecoveryAdaptiveHoldMs = 2600;
/* Burst-window send scheduler shaping for Wi-Fi TCP media path.
 * Spaces clustered enqueue bursts to reduce completion tail spikes without
 * lowering fidelity, resolution, or steady-state frame cadence. */
static const uint64_t kWirelessTCPSchedulerBurstWindowUs = 12000;
static const int32_t kWirelessTCPSchedulerBurstWindowTailThreshold = 3;
static const uint64_t kWirelessTCPSchedulerBaseSpacingUs = 800;
static const uint64_t kWirelessTCPSchedulerTailSpacingUs = 1400;
static const uint64_t kWirelessTCPSchedulerSevereSpacingUs = 2200;
/* Escalate scheduler spacing when 1s perf window shows completion spikes and
 * pre-encode drop pressure; this targets stuttery starvation tails where the
 * default burst-window spacing never engages (delay metrics stay at zero). */
static const uint64_t kWirelessTCPSchedulerRecoveryModerateSpacingUs = 4500;
static const uint64_t kWirelessTCPSchedulerRecoverySevereSpacingUs = 8500;
/* Completion-latency guard:
 * recovery spacing can remain ineffective when submit gaps are already above
 * 4.5-8.5ms while kernel completion latency is still 30-80ms. In that case,
 * apply a stronger temporary spacing so in-flight sends drain before the
 * pre-encode backpressure gate trips. */
static const uint64_t kWirelessTCPSchedulerCompletionGuardModerateSpacingUs = 14000;
static const uint64_t kWirelessTCPSchedulerCompletionGuardSevereSpacingUs = 24000;
/* Completion-aware dynamic floor: when completion tails rise, derive a guard
 * target from observed completion latency so scheduler spacing can actually
 * keep in-flight depth below pre-encode drop pressure. */
static const uint64_t kWirelessTCPSchedulerCompletionGuardSafetyUs = 1200;
/* Allow deeper (bounded) scheduler sleeps when completion-derived guard shows
 * severe tail pressure; avoids truncating required recovery spacing. */
static const uint64_t kWirelessTCPSchedulerMaxSleepUs = 20000;
static const uint64_t kWirelessTCPSchedulerDerivedSleepCapModerateUs = 32000;
static const uint64_t kWirelessTCPSchedulerDerivedSleepCapSevereUs = 45000;
/* Drop stale captured frames before HEVC encode under transient Wi-Fi load.
 * This bounds frame age entering the pipeline to reduce p95/p99 spikes. */
static const uint64_t kWirelessPreEncodeStaleDropBaseMs = 95;
static const uint64_t kWirelessPreEncodeStaleDropCongestedMs = 72;
static const uint64_t kWirelessPreEncodeStaleDropSevereMs = 54;
static const uint64_t kWirelessPreEncodeStaleDropAbsoluteMs = 250;
/* Require a clean stale-free window before any recovery upshift. */
static const uint64_t kWirelessAdaptivePostStaleUpshiftHoldMs = 4200;

static uint64_t keydrd_host_time_us(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000000.0);
}

/* ---- Frame timeline, Mac half ("FT-M" lines) ----
 * One record per Wi-Fi TCP media frame, keyed by capture ts_us so it joins the
 * iPad's "FT-I" lines (iPadOS Protocol.swift FrameTimeline). Diagnostic only: it
 * locates where a Wi-Fi stall starts (capture/encode, scheduler, local stack, link).
 * Records are batched 8 per os_log line so per-frame logging stays off the send path.
 * Entry: seq,tsUs,bytes,flags,encOutUs,+submit,+done,inFlight,outcome
 *   encOutUs = entry to the send path (encoder output), offsets in us from encOutUs,
 *   +done = -1 when never submitted; outcome S=sent F=failed D=backpressure-drop
 *   X=completion after a stall-recovery generation change. */
typedef struct {
    uint16_t seq;
    uint8_t  flags;
    char     outcome;
    uint32_t bytes;
    int32_t  inFlight;
    uint64_t tsUs;
    uint64_t encOutUs;
    uint64_t submitUs;
    uint64_t doneUs;
} FTMacRecord;

enum { kFTMacBatch = 8 };
static os_unfair_lock sFTMacLock = OS_UNFAIR_LOCK_INIT;
static FTMacRecord sFTMacBuf[kFTMacBatch];
static int sFTMacCount = 0;
static uint32_t sFTMacLine = 0;

static void ft_mac_record(FTMacRecord rec) {
    FTMacRecord batch[kFTMacBatch];
    int n = 0;
    uint32_t line = 0;
    os_unfair_lock_lock(&sFTMacLock);
    sFTMacBuf[sFTMacCount++] = rec;
    if (sFTMacCount == kFTMacBatch) {
        memcpy(batch, sFTMacBuf, sizeof(batch));
        n = sFTMacCount;
        sFTMacCount = 0;
        line = ++sFTMacLine;
    }
    os_unfair_lock_unlock(&sFTMacLock);
    if (n == 0) return;

    char buf[1024];
    size_t off = 0;
    for (int i = 0; i < n && off < sizeof(buf); i++) {
        const FTMacRecord *r = &batch[i];
        long long sub = r->submitUs ? (long long)(r->submitUs - r->encOutUs) : -1;
        long long done = (r->doneUs && r->submitUs) ? (long long)(r->doneUs - r->encOutUs) : -1;
        int w = snprintf(buf + off, sizeof(buf) - off, "%u,%llu,%u,%u,%llu,%lld,%lld,%d,%c;",
                         r->seq, (unsigned long long)r->tsUs, r->bytes, r->flags,
                         (unsigned long long)r->encOutUs, sub, done, r->inFlight, r->outcome);
        if (w < 0) break;
        off += (size_t)w;
    }
    os_log(sLog, "FT-M line=%u n=%d %{public}s", line, n, buf);
}

/* tla/SessionLanes.tla: how long a handler held the queue it ran on. Logged at >= 2 ms so a
 * run shows which session work could delay pointer/key messages queued behind it. */
static void lane_report(const char *lane, const char *what, int type, uint64_t startUs) {
    uint64_t d = keydrd_host_time_us() - startUs;
    if (d >= 2000) {
        os_log(sLog, "LANE-BLOCK lane=%{public}s what=%{public}s type=0x%02x ms=%.1f",
               lane, what, type, (double)d / 1000.0);
    }
}

/* tla/SessionLanes.tla RT set: messages handled inline on the transport queue. Each is
 * O(1) and touches no session state: pointer/key go to the injector's own queue, probes
 * and clock sync echo at once, keepalive is a no-op, test control drives the test window,
 * a Wi-Fi frame ack moves the ack gate under its own lock (tla/WiFiSendLoop.tla).
 * Everything else is forwarded, in arrival order, to the session queue. */
static BOOL session_lane_is_realtime(uint8_t type) {
    if ([InputInjector isInputMessageType:type]) return YES;
    switch (type) {
        case KEYDRD_INPUT_LATENCY_PROBE:
        case KEYDRD_INPUT_CLOCK_SYNC_REQ:
        case KEYDRD_INPUT_KEEPALIVE:
        case KEYDRD_INPUT_TEST_CONTROL:
        case KEYDRD_INPUT_FRAME_ACK:
            return YES;
        default:
            return NO;
    }
}

static void keydrd_limit_size(uint32_t sourceWidth, uint32_t sourceHeight,
                              uint32_t maxWidth, uint32_t maxHeight,
                              uint32_t *outWidth, uint32_t *outHeight) {
    if (sourceWidth == 0 || sourceHeight == 0 || maxWidth == 0 || maxHeight == 0) {
        if (outWidth) *outWidth = sourceWidth;
        if (outHeight) *outHeight = sourceHeight;
        return;
    }

    double widthScale = (double)maxWidth / (double)sourceWidth;
    double heightScale = (double)maxHeight / (double)sourceHeight;
    double scale = MIN(1.0, MIN(widthScale, heightScale));

    uint32_t limitedWidth = (uint32_t)llround((double)sourceWidth * scale);
    uint32_t limitedHeight = (uint32_t)llround((double)sourceHeight * scale);

    if (limitedWidth > 1 && (limitedWidth & 1u) != 0) limitedWidth--;
    if (limitedHeight > 1 && (limitedHeight & 1u) != 0) limitedHeight--;

    if (outWidth) *outWidth = MAX(limitedWidth, 2u);
    if (outHeight) *outHeight = MAX(limitedHeight, 2u);
}

/* Maximum number of TCP media sends in-flight before dropping frames.
 * NWConnection.send completion fires when kernel accepts data, so this
 * bounds the kernel TCP send buffer depth. At 2 in-flight, one frame
 * is being transmitted while the next waits — keeps latency bounded
 * without sacrificing throughput on fast links. */
/* Allow 5 concurrent TCP sends to pipeline USB NCM transfers.
 * TB4 (USB 3.2 Gen 2) has 10 Gbps bandwidth. At 3-4MB per frame,
 * each send takes <5ms. 5 in-flight keeps the pipeline fully saturated
 * for 120fps at maximum quality without backpressure drops. */
static const int32_t kMaxMediaSendsInFlightUSB = 5;
/* LZ4 gate (tla/DeltaSync.tla, Cap): do not compress a new frame while this many USB media
 * sends are in flight. Compressed deltas are never dropped (that desynchronized the iPad's
 * XOR reference: 11,000 drops and a garbled picture on 2026-11-15). Fewer frames queued in
 * the kernel also bounds latency: 5 x 2 MB frames at ~60 MB/s was ~170 ms of queue. */
static const int32_t kUSBLZ4GateInFlight = 2;

@interface SessionManager ()

@property (nonatomic, assign, readwrite) SessionState sessionState;
@property (nonatomic, assign, readwrite) TransportState transportState;

/* Pipeline components */
@property (nonatomic, strong) ScreenCapture *capture;
@property (nonatomic, strong) HEVCEncoder *hevcEncoder;
@property (nonatomic, strong) USBNetworkTransport *usbTransport;
@property (nonatomic, strong) WirelessTransport *wirelessTransport;
@property (nonatomic, strong) PairingManager *pairing;
/* iPad pointer/keyboard -> CGEvents (tla/InputPath.tla) */
@property (nonatomic, strong) InputInjector *inputInjector;
/* Test mode only: agent-owned window that observes injected input (E2E). */
@property (nonatomic, strong, nullable) InputTestHarness *inputTestHarness;
/* tla/SessionLanes.tla: one serial session queue S owns the session FSM, handshake,
 * encoder/capture start, viewport and mode change. Transport queues only route. */
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
/* Owned by S. Set when a Wi-Fi session is up and capture waits for the media channel. */
@property (nonatomic, assign) BOOL awaitingMedia;

/* Compression state (pure C struct) */
@property (nonatomic, assign) FrameCompressorState compressorState;
@property (nonatomic, assign) BOOL compressorInitialized;

/* Reconnection */
@property (nonatomic, assign) int reconnectAttempt;
@property (nonatomic, strong, nullable) NSTimer *reconnectTimer;

/* Permission polling */
@property (nonatomic, strong, nullable) NSTimer *permissionTimer;

/* Current encode mode */
@property (nonatomic, assign) BOOL isEcoMode;

/* Display info */
@property (nonatomic, assign) uint32_t captureWidth;
@property (nonatomic, assign) uint32_t captureHeight;
@property (nonatomic, assign) float captureScale;

/* Viewport: iPad reports its viewport dims after handshake.
 * Encoder + capture start only after viewport is known. */
@property (nonatomic, assign) uint32_t viewportWidth;
@property (nonatomic, assign) uint32_t viewportHeight;
@property (nonatomic, assign) BOOL viewportReceived;

/* Resolution matching: stored original display mode for revert on disconnect */
@property (nonatomic, assign) CGDisplayModeRef storedDisplayMode;
@property (nonatomic, assign) BOOL resolutionChanged;
@property (nonatomic, copy, nullable) NSString *testCaptureFilePath;
@property (nonatomic, assign) BOOL testCaptureStressMode;

/* Latency probe */
@property (nonatomic, strong, nullable) NSTimer *latencyProbeTimer;
@property (nonatomic, strong, nullable) NSTimer *wirelessPerformanceTimer;

/* Send backpressure: track in-flight TCP media sends.
 * When > kMaxTcpSendsInFlight, drop new frames to prevent queue buildup. */
@property (nonatomic, assign) volatile int32_t tcpMediaSendsInFlight;
@property (nonatomic, assign) volatile int32_t wifiTCPMediaSendsInFlight;
@property (atomic, assign) uint64_t wirelessLastEncodeSubmitUs;
@property (nonatomic, assign) volatile int32_t wifiPerfEncodedFrames;
@property (nonatomic, assign) volatile int32_t wifiPerfEncodedBytes;
@property (nonatomic, assign) volatile int32_t wifiPerfKeyframes;
@property (nonatomic, assign) volatile int32_t wifiPerfMaxFrameBytes;
@property (nonatomic, assign) volatile int32_t wifiPerfPreEncodeDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfQueueDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPFallbacks;
@property (nonatomic, assign) volatile int32_t wifiPerfPeakQueuedChunks;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSendDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPInFlightPeak;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSlowCompletions;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPMaxCompletionMs;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPDropKeyframeRequests;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPDropKeyframeSuppressed;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPStallRecoveries;
@property (atomic, assign) uint64_t wifiLastTCPDropKeyframeRequestUs;
@property (atomic, assign) uint64_t wifiTCPLastCompletionUs;
@property (atomic, assign) uint64_t wifiTCPInFlightSaturatedSinceUs;
@property (atomic, assign) uint64_t wifiTCPLastStallRecoveryUs;
@property (atomic, assign) uint64_t wifiTCPStallLastLogUs;
@property (atomic, assign) uint32_t wifiTCPSendGeneration;
/* Test-mode bandwidth probe state; touched only on the Wi-Fi transport queue. */
@property (nonatomic, strong) NSData *bwProbeChunk;
@property (nonatomic, assign) uint64_t bwProbeStartUs;
@property (nonatomic, assign) uint64_t bwProbeEndUs;
@property (nonatomic, assign) uint64_t bwProbeSentBytes;
@property (nonatomic, assign) int bwProbeInFlight;
@property (nonatomic, assign) BOOL bwProbeActive;
@property (atomic, assign) uint64_t wifiTCPSchedulerWindowStartUs;
@property (atomic, assign) uint64_t wifiTCPSchedulerLastSubmitUs;
@property (nonatomic, assign) volatile int32_t wifiTCPSchedulerWindowSendCount;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveDownshifts;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveUpshifts;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveHolds;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveFloorGuards;
@property (nonatomic, assign) volatile int32_t wifiPerfPreEncodeStaleDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfPreEncodeStaleMaxAgeMs;
@property (nonatomic, assign) volatile int32_t wifiPerfPreEncodeAgeSamples;
@property (nonatomic, assign) volatile int32_t wifiPerfPreEncodeAgeTotalMs;
@property (nonatomic, assign) volatile int32_t wifiPerfBurstTailFrames;
@property (nonatomic, assign) volatile int32_t wifiPerfBurstSevereFrames;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSchedulerDelays;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSchedulerDelayMaxUs;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSchedulerBurstWindows;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSchedulerBurstSends;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSchedulerDelayTotalUs;
@property (nonatomic, assign) int32_t wifiAdaptiveTargetFPS;
@property (nonatomic, assign) int32_t wifiAdaptiveTargetBitrate;
@property (nonatomic, assign) int32_t wifiAdaptiveAppliedFPS;
@property (nonatomic, assign) int32_t wifiAdaptiveAppliedBitrate;
@property (atomic, assign) uint64_t wifiAdaptiveLastChangeUs;
@property (atomic, assign) uint64_t wifiAdaptiveLastStaleDropUs;
@property (nonatomic, assign) int32_t wifiAdaptiveHealthyStreak;
@property (nonatomic, assign) int32_t wifiAdaptiveMildCongestionStreak;
@property (nonatomic, assign) int32_t wifiAdaptiveSevereCongestionStreak;

/* QR code display window */
@property (nonatomic, strong, nullable) NSWindow *qrWindow;
@property (nonatomic, strong, nullable) NSWindow *stressWindow;
@property (nonatomic, strong, nullable) NSTimer *stressWindowTimer;

- (void)sendMediaFrameHeaderToiPad:(const MediaFrameHeader *)header
                           payload:(const void *)payload
                     payloadLength:(size_t)payloadLen;
- (void)resetWiFiAdaptiveControlState;
- (void)evaluateWiFiAdaptiveRateControl;
- (void)evaluateWiFiAckRateControlNowUs:(uint64_t)nowUs;
- (void)applyWiFiAdaptiveRateTargetsIfNeededWithReason:(NSString *)reason nowUs:(uint64_t)nowUs;

@end

@implementation SessionManager {
    /* Wi-Fi ack gate (tla/WiFiSendLoop.tla AckGate), guarded by _wifiAckLock. */
    os_unfair_lock _wifiAckLock;
    uint32_t _sessionWirelessEpoch;   // tla/Lifecycle.tla RestartOnNewConn: epoch the session was started on
    BOOL _wifiAckActive;          /* an ack arrived on this connection: gate on unacked frames */
    BOOL _wifiAckHasSent;
    uint16_t _wifiAckLastSentSeq;
    uint16_t _wifiAckLastAckedSeq;
    uint64_t _wifiAckSendUs[256]; /* send time by seq & 0xFF, for ack RTT */
    uint32_t _wifiAckBytes[256];  /* frame bytes by seq & 0xFF, for delivery-rate samples */
    uint64_t _wifiAckLastAckMacUs;   /* Mac time the previous accepted ack arrived */
    uint64_t _wifiAckLastIpadUs;     /* iPad time stamped on the previous accepted ack */
    int32_t _wifiPerfAckRateSamples;
    uint64_t _wifiPerfAckDeliveryMaxBps;
    /* per 1 s perf window, under _wifiAckLock */
    int32_t _wifiPerfAcks;
    int32_t _wifiPerfAckStale;
    int32_t _wifiPerfAckGateHolds;
    int32_t _wifiPerfAckUnackedPeak;
    int32_t _wifiPerfAckRttSamples;
    uint64_t _wifiPerfAckRttTotalUs;
    uint64_t _wifiPerfAckRttMaxUs;

    /* tla/FrameLoop.tla (Design). Every log line tagged "FL <Action>" names the model step it is.
     * One send gate, under _flLock, at each transport submit (USB x2, Wi-Fi), held together with
     * the submit so the gate's decision and the wire order agree (the model's Send is atomic):
     *   HsConn:     a frame for a route (transport, connection epoch) that has not had this
     *               session's handshake gets one first, tagged with a fresh epoch, on that very
     *               connection; the iPad takes media only from the connection of the newest epoch.
     *   KeyOnBreak: after a handshake, a loss, a codec change or an iPad request, deltas are held
     *               (never sent) until a keyframe goes out.
     *   IdleKey:    while a key is owed and the source is idle, the last frame is re-emitted.
     *   EpochMonotone: epochs only grow, across agent relaunches too (wall clock, persisted). */
    os_unfair_lock _flLock;
    BOOL _flHsCached;                 /* sendSessionHandshake built the handshake below */
    SessionHandshakeMessage _flHs;
    uint64_t _flRouteKey;             /* (route << 32) | connection epoch the last handshake went on */
    uint32_t _flEpoch;                /* epoch of the last handshake sent */
    BOOL _flNeedKey;                  /* KeyOnBreak: hold deltas until a keyframe is sent */
    const char *_flNeedReason;
    uint64_t _flNeedSinceUs;
    uint64_t _flLastKeyReqUs;
    uint64_t _flLastReemitUs;
    uint64_t _flLastFrameUs;          /* last frame offered to the gate (source not idle) */
    uint32_t _flHeld;                 /* deltas held since the key became owed */
    int _flLastCodec;                 /* -1 none yet, 0 LZ4, 1 HEVC */
    uint32_t _flEncDropSeen;
    int32_t _flLossPending;           /* losses noted lock-free (completions may run inside the gate) */
    dispatch_source_t _flIdleTimer;
}

- (instancetype)initWithTestMode:(BOOL)testMode
                  automationMode:(BOOL)automationMode
                       wiredOnly:(BOOL)wiredOnly
                    wirelessOnly:(BOOL)wirelessOnly {
    return [self initWithTestMode:testMode
                   automationMode:automationMode
                        wiredOnly:wiredOnly
                     wirelessOnly:wirelessOnly
              testCaptureFilePath:nil
            testCaptureStressMode:NO];
}

- (instancetype)initWithTestMode:(BOOL)testMode
                  automationMode:(BOOL)automationMode
                       wiredOnly:(BOOL)wiredOnly
                    wirelessOnly:(BOOL)wirelessOnly
             testCaptureFilePath:(NSString *)testCaptureFilePath
           testCaptureStressMode:(BOOL)testCaptureStressMode {
    self = [super init];
    if (self) {
        sLog = os_log_create("com.ryheff.keyd.remote.agent", "SessionManager");
        _flLock = OS_UNFAIR_LOCK_INIT;  /* tla/FrameLoop.tla send gate */
        _flLastCodec = -1;
        _testMode = testMode;
        _automationMode = automationMode;
        _wiredOnly = wiredOnly;
        _wirelessOnly = wirelessOnly;
        _testCaptureFilePath = [testCaptureFilePath copy];
        _testCaptureStressMode = testCaptureStressMode;
        _sessionState = SESSION_STOPPED;
        _transportState = TRANSPORT_IDLE;
        _compressorInitialized = NO;
        _isEcoMode = NO;
        _reconnectAttempt = 0;
        _storedDisplayMode = NULL;
        _resolutionChanged = NO;
        _captureScale = 2.0f;

        /* Create pipeline components */
        _capture = [[ScreenCapture alloc] init];
        _capture.testCaptureFilePath = _testCaptureFilePath;
        _capture.testCaptureStressMode = _testCaptureStressMode;
        _hevcEncoder = [[HEVCEncoder alloc] init];
        _usbTransport = [[USBNetworkTransport alloc] init];
        _wirelessTransport = [[WirelessTransport alloc] init];
        _pairing = [[PairingManager alloc] init];
        _inputInjector = [[InputInjector alloc] init];
        _sessionQueue = dispatch_queue_create("com.ryheff.keyd.remote.agent.session",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
        _wifiAdaptiveTargetBitrate = kWirelessHEVCBitrate;
        _wifiAdaptiveAppliedFPS = 0;
        _wifiAdaptiveAppliedBitrate = 0;
        _wifiAdaptiveLastChangeUs = 0;
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak = 0;
    }
    return self;
}

- (void)dealloc {
    if (_storedDisplayMode) {
        CGDisplayModeRelease(_storedDisplayMode);
        _storedDisplayMode = NULL;
    }
}

#pragma mark - Lifecycle

- (void)start {
    /* Identity first, before permissions: with no Secure Enclave identity the agent can never
     * serve, and the menu bar must say so right away (fail closed, tla/KeyCustody.tla). */
    [_pairing ensureTLSIdentity];
    os_log(sLog, "Session start: Secure Enclave identity %{public}s",
           _pairing.tlsIdentity ? "ready" : "UNAVAILABLE");
    if (!_pairing.tlsIdentity) {
        [self failClosedNoIdentity];
        return;
    }

    os_log(sLog, "Session starting -- checking permissions");
    [self transitionTo:SESSION_AWAITING_PERMISSIONS];

    if (_testMode) {
        /* Don't block the test run on permissions, but do raise the system Accessibility prompt:
         * without it CGEventPost drops every input event and the input E2E tests fail. */
        if (!AXIsProcessTrusted()) {
            NSDictionary *axOpts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
            BOOL ax = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)axOpts);
            os_log_error(sLog, "Test mode: Accessibility not granted -- system prompt shown (trusted now=%{public}d); input events will be dropped until granted", ax);
        }
        os_log(sLog, "Test mode -- skipping permission checks");
        [self onPermissionsGranted];
        return;
    }

    [self checkPermissions];
}

- (void)stop {
    os_log(sLog, "Session stopping");
    /* InputPath StopRelease: nothing stays pressed after the agent stops. */
    [_inputInjector releaseAllSync:"agent-stop"];
    [self.reconnectTimer invalidate];
    self.reconnectTimer = nil;
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
    [self.latencyProbeTimer invalidate];
    self.latencyProbeTimer = nil;
    [self stopWirelessPerformanceTimer];
    [self.stressWindowTimer invalidate];
    self.stressWindowTimer = nil;
    [self.stressWindow orderOut:nil];
    self.stressWindow = nil;

    [_capture stopCapture];
    [_hevcEncoder stop];
    [_usbTransport stopMonitoring];
    [_wirelessTransport stopAdvertising];

    if (_compressorInitialized) {
        FrameCompressorState state = _compressorState;
        frame_compressor_destroy(&state);
        _compressorState = state;
        _compressorInitialized = NO;
    }

    /* Revert resolution if changed */
    [self revertDisplayMode];

    [self transitionTo:SESSION_STOPPED];
}

#pragma mark - Permission Gating

- (void)checkPermissions {
    /* Check Screen Recording (RD-AGENT-04) */
    BOOL screenGranted = CGPreflightScreenCaptureAccess();
    if (!screenGranted) {
        CGRequestScreenCaptureAccess();
    }

    /* Check Accessibility (RD-AGENT-05) */
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL accessibilityGranted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

    /* Notify UI of initial permission state */
    if (self.onPermissionStatusChanged) {
        self.onPermissionStatusChanged(screenGranted, accessibilityGranted);
    }

    if (screenGranted && accessibilityGranted) {
        os_log(sLog, "Both permissions already granted");
        [self onPermissionsGranted];
        return;
    }

    os_log(sLog, "Waiting for permissions -- Screen Recording: %{public}s, Accessibility: %{public}s",
           screenGranted ? "granted" : "pending",
           accessibilityGranted ? "granted" : "pending");

    /* Poll every 3 seconds until both granted */
    __weak SessionManager *weakSelf = self;
    _permissionTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                      repeats:YES
                                                        block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }

        BOOL screen = CGPreflightScreenCaptureAccess();
        BOOL accessibility = AXIsProcessTrustedWithOptions(NULL);

        os_log(sLog, "Permission poll: Screen Recording=%{public}s, Accessibility=%{public}s",
               screen ? "granted" : "pending",
               accessibility ? "granted" : "pending");

        /* Update the menu bar UI on every poll */
        if (strongSelf.onPermissionStatusChanged) {
            strongSelf.onPermissionStatusChanged(screen, accessibility);
        }

        if (screen && accessibility) {
            os_log(sLog, "Both permissions now granted");
            [timer invalidate];
            strongSelf.permissionTimer = nil;
            [strongSelf onPermissionsGranted];
        }
    }];
}

/* Fail closed (owner decision 2026-11-15, tla/KeyCustody.tla): no identity, no pairing, no
 * listeners, no fallback. Shown in the menu bar, not only in the log. */
- (void)failClosedNoIdentity {
    os_log_fault(sLog, "Session not started: Secure Enclave TLS identity unavailable (check signing: keychain-access-groups + provisioning profile)");
    [self transitionTo:SESSION_STOPPED];
    if (self.onIdentityUnavailable) self.onIdentityUnavailable();
}

- (void)onPermissionsGranted {
    /* Ensure TLS identity exists */
    if (!_pairing.tlsIdentity) [_pairing ensureTLSIdentity];
    if (!_pairing.tlsIdentity) {
        [self failClosedNoIdentity];
        return;
    }

    /* Set TLS identity on transports */
    _usbTransport.tlsIdentity = _pairing.tlsIdentity;
    _wirelessTransport.tlsIdentity = _pairing.tlsIdentity;

    if (_testMode) {
        /* Test mode always re-pairs: iPad auto-pair needs the pairing listener. */
        os_log(sLog, "Test mode -- forcing fresh pairing");
        [_pairing resetPairing];
        [self transitionTo:SESSION_AWAITING_PAIRING];
    } else if (_pairing.isPaired) {
        os_log(sLog, "Already paired -- proceeding to connect");
        [_qrWindow close];
        _qrWindow = nil;
        [self transitionTo:SESSION_CONNECTING];
        [self startTransportMonitoring];
    } else {
        os_log(sLog, "Not yet paired -- awaiting QR pairing");
        [self transitionTo:SESSION_AWAITING_PAIRING];
    }
}

#pragma mark - Pairing

- (void)showPairingQR {
    /* Reset pairing state for fresh QR pairing */
    [_pairing resetPairing];

    NSString *payload = [_pairing generateQRPayload];
    if (!payload) {
        os_log_error(sLog, "Failed to generate QR payload -- TLS identity missing?");
        return;
    }

    os_log(sLog, "QR pairing payload generated (length=%lu)", (unsigned long)payload.length);
    os_log_debug(sLog, "QR payload: %{public}@", payload);

    /* In test mode, write the QR payload to a file for the iPad to read
     * instead of requiring a physical QR scan. */
    if (_testMode) {
        NSError *writeError = nil;
        [payload writeToFile:@"/tmp/keydrd-test-qr.json"
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:&writeError];
        if (writeError) {
            os_log_error(sLog, "Test mode: failed to write QR payload to file: %{public}@",
                         writeError.localizedDescription);
        } else {
            os_log(sLog, "Test mode: QR payload written to /tmp/keydrd-test-qr.json");
        }
    }

    /* Wire pairing completion callback before starting listener (with or without QR UI). */
    __weak SessionManager *weakSelf = self;
    _pairing.onPairingComplete = ^{
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        os_log(sLog, "Pairing complete -- closing QR window and starting transport");
        [strongSelf.qrWindow close];
        strongSelf.qrWindow = nil;
        [strongSelf transitionTo:SESSION_CONNECTING];
        [strongSelf startTransportMonitoring];
    };

    if (_testMode && _automationMode) {
        os_log(sLog, "Test mode: QR window suppressed (--automation-mode)");
        [_pairing startPairingListener];
        return;
    }

    /* Generate QR code image using CIFilter */
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    CIFilter *qrFilter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [qrFilter setValue:payloadData forKey:@"inputMessage"];
    [qrFilter setValue:@"M" forKey:@"inputCorrectionLevel"];

    CIImage *ciImage = qrFilter.outputImage;
    if (!ciImage) {
        os_log_error(sLog, "CIQRCodeGenerator produced nil image");
        return;
    }

    /* Scale QR to small display size (each module -> 3px) */
    CGFloat scale = 3.0;
    CIImage *scaled = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
    NSImage *qrImage = [[NSImage alloc] initWithSize:rep.size];
    [qrImage addRepresentation:rep];

    CGFloat imageSize = rep.size.width;
    CGFloat padding = 12;
    CGFloat labelHeight = 28;
    CGFloat windowWidth = imageSize + padding * 2;
    CGFloat windowHeight = imageSize + padding * 2 + labelHeight;

    /* Close existing QR window if open */
    [_qrWindow close];

    NSRect frame = NSMakeRect(0, 0, windowWidth, windowHeight);
    _qrWindow = [[QRWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    _qrWindow.title = @"Scan with iPad";
    _qrWindow.level = NSFloatingWindowLevel;
    _qrWindow.releasedWhenClosed = NO;

    NSView *contentView = _qrWindow.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = NSColor.whiteColor.CGColor;

    /* QR image view */
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:
        NSMakeRect(padding, labelHeight + padding / 2, imageSize, imageSize)];
    imageView.image = qrImage;
    imageView.imageScaling = NSImageScaleNone;
    [contentView addSubview:imageView];

    /* Label */
    NSTextField *label = [NSTextField labelWithString:@"Scan with iPad"];
    label.frame = NSMakeRect(0, 4, windowWidth, 20);
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = NSColor.secondaryLabelColor;
    [contentView addSubview:label];

    [_qrWindow center];
    [_qrWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* Start TLS listener so iPad can connect after scanning */
    [_pairing startPairingListener];
}

- (void)resetPairing {
    os_log(sLog, "Resetting pairing");
    [self stop];
    [_pairing resetPairing];
    [self transitionTo:SESSION_AWAITING_PAIRING];
}

#pragma mark - Transport

- (void)startTransportMonitoring {
    __weak SessionManager *weakSelf = self;

    /* USB NCM: when TCP input connection is accepted, send handshake.
     * The interface appears before any iPad connection arrives. The handshake
     * must wait until the TCP channel is ready (not just interface detected). */
    _usbTransport.onInputConnectionReady = ^{
        SessionManager *outer = weakSelf;
        if (!outer) return;
        [outer onSession:"usb-input-ready" type:0 block:^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf->_transportState != TRANSPORT_USB_NCM) {
                [strongSelf handleTransportEvent:TRANSPORT_EVT_WIRED_APPEARED];
            } else {
                os_log(sLog, "USB NCM TCP input ready — sending handshake (hevcActive=%d eco=%d)",
                       strongSelf->_hevcEncoder.isActive, strongSelf->_isEcoMode);
                /* tla/TransportAgreement.tla RouteResync: the codec is the route's. The FSM can
                 * already read USB_NCM while the session ran on wireless (interface appear sets
                 * the label, TA-asbuilt-labels), so WIRED_APPEARED's LZ4 effect never fires and
                 * HEVC went out over USB (seen 2026-11-16 after an iPad relaunch). A new USB
                 * connection starts lossless; the iPad asks for eco again if it wants it. */
                if (strongSelf->_hevcEncoder.isActive) {
                    os_log(sLog, "RouteResync: USB input ready with HEVC active -> LZ4");
                    [strongSelf switchToLZ4Mode];
                }
                /* tla/DeltaSync.tla KeyOnConnect: frames compressed before this connection
                 * (seen: the switch keyframe sent over AWDL) never reach it in order. */
                [strongSelf->_capture requestLZ4Keyframe];
                [strongSelf onTransportConnected];
            }
        }];
    };

    _usbTransport.onInputConnectionLost = ^{
        SessionManager *outer = weakSelf;
        if (!outer) return;
        [outer onSession:"usb-input-lost" type:0 block:^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_awaitingMedia = NO;
            [strongSelf handleTransportEvent:TRANSPORT_EVT_DISCONNECTED];
        }];
    };

    /* USB NCM interface monitoring */
    _usbTransport.onInterfaceChanged = ^(BOOL appeared, nw_interface_t _Nullable interface) {
        SessionManager *outer = weakSelf;
        if (!outer) return;
        [outer onSession:appeared ? "usb-if-up" : "usb-if-down" type:0 block:^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleTransportEvent:appeared ? TRANSPORT_EVT_WIRED_APPEARED
                                                      : TRANSPORT_EVT_WIRED_DISAPPEARED];
        }];
    };

    /* InputPath ReleaseOnLoss: any input connection ending releases every held key/button. */
    InputInjector *injector = _inputInjector;
    _usbTransport.onInputStreamEnded = ^{ [injector inputStreamEnded:"usb"]; };
    _wirelessTransport.onInputStreamEnded = ^{ [injector inputStreamEnded:"wireless"]; };

    /* USB transport input receive callback */
    _usbTransport.onInputReceived = ^(const void *data, size_t length) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf routeInputFromTransport:data length:length lane:"usb-T"];
    };

    /* Wireless connection monitoring */
    _wirelessTransport.onConnectionChanged = ^(BOOL connected, BOOL isAWDL) {
        SessionManager *outer = weakSelf;
        if (!outer) return;
        [outer onSession:connected ? "connection-up" : "connection-down" type:0 block:^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (connected) {
                [strongSelf handleTransportEvent:isAWDL ? TRANSPORT_EVT_AWDL_AVAILABLE
                                                        : TRANSPORT_EVT_WIFI_AVAILABLE];
            } else {
                strongSelf->_awaitingMedia = NO;
                [strongSelf handleTransportEvent:isAWDL ? TRANSPORT_EVT_AWDL_UNAVAILABLE
                                                        : TRANSPORT_EVT_WIFI_UNAVAILABLE];
            }
        }];
    };

    /* Registered once, never cleared. Forwards to S, where the fresh check decides. */
    _wirelessTransport.onMediaChannelReady = ^{
        SessionManager *outer = weakSelf;
        if (!outer) return;
        [outer onSession:"media-ready" type:0 block:^{
            [weakSelf mediaChannelReadyOnSession];
        }];
    };

    /* Wireless transport input receive callback */
    _wirelessTransport.onInputReceived = ^(const void *data, size_t length) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf routeInputFromTransport:data length:length lane:"wifi-T"];
    };

    /* Start USB NCM first (primary transport).
     * Always start WiFi advertising after a delay. USB NCM listeners bind to
     * a specific interface, and WiFi binds to :: with SO_REUSEADDR — no conflict.
     * WiFi advertising must always be active so the iPad can:
     *   1. Discover the Mac via Bonjour (_keydrd._tcp)
     *   2. Fall back to WiFi if USB disconnects
     *   3. Run WiFi rotation tests during E2E suite */
    if (!_wirelessOnly) {
        [_usbTransport startMonitoring];
    } else {
        os_log(sLog, "Wireless-only mode — USB monitoring disabled");
    }

    if (!_wiredOnly) {
        __weak SessionManager *weakSelf2 = weakSelf;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SessionManager *self2 = weakSelf2;
            if (!self2) return;
            if (self2->_wirelessTransport.isConnected) {
                os_log(sLog,
                       "Skipping delayed WiFi advertising start: wireless session already active (state=%{public}s transport=%{public}s)",
                       [self2 sessionStateName:self2->_sessionState], transport_state_name(self2->_transportState));
                return;
            }
            if (self2->_wirelessOnly) {
                os_log(sLog, "Wireless-only mode — starting WiFi advertising");
            } else if (self2->_usbTransport.isConnected) {
                os_log(sLog, "USB NCM connected — starting WiFi advertising anyway (fallback + Bonjour)");
            } else {
                os_log(sLog, "USB NCM not connected after 3s — starting WiFi advertising");
            }
            [self2->_wirelessTransport startAdvertising];
        });
    } else {
        os_log(sLog, "Wired-only mode — WiFi/AWDL advertising disabled");
    }
}

/* Run block on the session queue S, logging any wait or run of 2 ms or more. */
- (void)onSession:(const char *)what type:(int)type block:(dispatch_block_t)block {
    uint64_t enqUs = keydrd_host_time_us();
    dispatch_async(_sessionQueue, ^{
        lane_report("S-wait", what, type, enqUs);
        uint64_t t0 = keydrd_host_time_us();
        block();
        lane_report("S", what, type, t0);
    });
}

/* Called on a transport queue T for every framed message from the iPad. */
- (void)routeInputFromTransport:(const void *)data length:(size_t)length lane:(const char *)lane {
    if (length < sizeof(InputEventHeader)) return;
    uint8_t type = ((const InputEventHeader *)data)->type;
    uint64_t t0 = keydrd_host_time_us();
    if (session_lane_is_realtime(type)) {
        [self handleReceivedInputEvent:data length:length];
        lane_report(lane, "input", type, t0);
        return;
    }
    /* SilenceDeadline sees every message on T, not when S gets to it. */
    [_inputInjector noteActivity];
    /* The transport reuses its receive buffer after this returns: copy before the hop. */
    NSData *copy = [NSData dataWithBytes:data length:length];
    __weak SessionManager *weakSelf = self;
    [self onSession:"input" type:type block:^{
        SessionManager *s = weakSelf;
        if (!s) return;
        [s handleReceivedInputEvent:copy.bytes length:copy.length];
    }];
    lane_report(lane, "input-forward", type, t0);
}

/* On S. Forwarded media-ready: start capture only if this session still waits for it and
 * the media channel is still ready now (SessionLanes Once + FreshCheck). */
- (void)mediaChannelReadyOnSession {
    BOOL ready = _wirelessTransport.mediaChannelReady;
    BOOL wifi = _wirelessTransport.isConnected && !_usbTransport.isConnected;
    if (_awaitingMedia && ready && wifi) {
        _awaitingMedia = NO;
        os_log(sLog, "Media channel ready -- starting capture now");
        [self _beginCapture];
    } else {
        os_log(sLog, "Media channel ready ignored (awaitingMedia=%{public}d mediaReadyNow=%{public}d wifiOnly=%{public}d)",
               _awaitingMedia, ready, wifi);
    }
}

- (void)handleTransportEvent:(TransportEvent)event {
    os_log(sLog, "Transport event: %{public}s (current state: %{public}s)",
           transport_event_name(event), transport_state_name(_transportState));

    /* Tell iPad the Mac's USB NCM link-local IP whenever USB NCM appears.
     * The iPad needs this to connect over USB — the QR pairing host is the
     * WiFi IP which can't be reached over the USB NCM interface. Send over
     * whatever transport is currently alive (WiFi or USB input). */
    if (event == TRANSPORT_EVT_WIRED_APPEARED) {
        [self sendPeerAddressUpdate];
    }

    TransportTransition transition = transport_fsm_transition(_transportState, event);
    _transportState = transition.next_state;

    os_log(sLog, "Transitioned to: %{public}s (%d effects)",
           transport_state_name(_transportState), transition.effect_count);

    /* Execute side effects */
    for (int i = 0; i < transition.effect_count; i++) {
        [self executeEffect:transition.effects[i]];
    }

    /* Notify StatusBarController */
    if (self.onTransportStateChanged) {
        self.onTransportStateChanged(_transportState);
    }

    /* Immediate fallback: when transitioning to DISCONNECTED during active streaming,
     * check if the alternate transport is still connected and switch directly.
     * This avoids the reconnect/backoff cycle and keeps streaming + capture alive. */
    if (_transportState == TRANSPORT_DISCONNECTED && _sessionState == SESSION_STREAMING) {
        if (_wirelessTransport.isConnected) {
            BOOL awdl = _wirelessTransport.isAWDL;
            os_log(sLog, "Immediate wireless fallback — wireless still connected (AWDL=%d), switching directly", awdl);
            /* The session continues on the wireless connection that is already current (Lifecycle
             * v1 covers wireless only; USB fallback is version 2): adopt its epoch so it is not
             * mistaken for a new connection. */
            _sessionWirelessEpoch = _wirelessTransport.inputConnectionEpoch;
            [self handleTransportEvent:awdl ? TRANSPORT_EVT_AWDL_AVAILABLE : TRANSPORT_EVT_WIFI_AVAILABLE];
            return;
        }
        if (_usbTransport.isConnected) {
            os_log(sLog, "Immediate USB fallback — USB still connected, switching directly");
            [self handleTransportEvent:TRANSPORT_EVT_WIRED_APPEARED];
            return;
        }
        [self startReconnection];
    } else if (_transportState != TRANSPORT_IDLE && _transportState != TRANSPORT_DISCONNECTED) {
        uint32_t wirelessEpoch = _wirelessTransport.inputConnectionEpoch;
        if (_sessionState == SESSION_STREAMING &&
            (_transportState == TRANSPORT_WIFI || _transportState == TRANSPORT_AWDL) &&
            _wirelessTransport.isConnected && wirelessEpoch != _sessionWirelessEpoch) {
            /* tla/Lifecycle.tla RestartOnNewConn: a new wireless connection became current while
             * STREAMING (iPad relaunched, or replaced its connection). As built this branch was
             * skipped: no handshake reached the new connection and the ack gate kept counting the
             * old one, so the iPad sat in connecting (pid 98733). Restart the session on it. */
            os_log(sLog, "LC Restart reason=new-connection epoch=%u sessionEpoch=%u", wirelessEpoch, _sessionWirelessEpoch);
            [self onTransportConnected];
        } else if (_sessionState == SESSION_CONNECTING || _sessionState == SESSION_RECONNECTING) {
            /* Only fire onTransportConnected if a transport actually has an active TCP connection.
             * USB NCM detects the interface before iPad connects — the handshake must wait
             * for onInputConnectionReady. WiFi fires onConnectionChanged only after TCP is ready. */
            if (_usbTransport.isConnected || _wirelessTransport.isConnected) {
                _reconnectAttempt = 0;
                [_reconnectTimer invalidate];
                _reconnectTimer = nil;
                [self onTransportConnected];
            } else {
                os_log(sLog, "Transport state changed but no active TCP connection yet — waiting");
            }
        }
    }
}

- (void)executeEffect:(TransportEffect)effect {
    os_log(sLog, "Executing effect: %{public}s", transport_effect_name(effect));

    switch (effect) {
        case EFFECT_SWITCH_ENCODE_LZ4:
            [self switchToLZ4Mode];
            break;
        case EFFECT_SWITCH_ENCODE_HEVC:
            [self switchToHEVCMode];
            break;
        case EFFECT_NOTIFY_TRANSPORT_CHANGE:
            [self sendTransportChangeNotification];
            break;
        case EFFECT_BIND_USB_NCM:
        case EFFECT_CONNECT_WIFI:
        case EFFECT_CONNECT_AWDL:
        case EFFECT_DISCONNECT_CURRENT:
        case EFFECT_NONE:
            /* Transport modules handle their own binding/connecting */
            break;
    }
}

#pragma mark - Encode Mode Switching

- (void)switchToLZ4Mode {
    os_log(sLog, "Switching to LZ4 mode (lossless, <1ms encode — wired USB only)");
    _isEcoMode = NO;
    [_hevcEncoder stop];

    /* Capture resolution will be set to viewport dims when iPad sends viewport report.
     * If viewport already known (reconnect), resize now. */
    if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        /* Wi-Fi HEVC lowered the capture rate (kWirelessHEVCFPS / adaptive); USB LZ4 runs at the
         * capture default of 120 (seen 2026-11-15: USB stuck at 60 fps after a Wi-Fi round trip). */
        _capture.captureFPS = 120;
        os_log(sLog, "LZ4: resizing capture to viewport %ux%u @%ufps", _viewportWidth, _viewportHeight,
               _capture.captureFPS);
        [_capture updateCaptureResolution:_viewportWidth height:_viewportHeight];
        _captureWidth = _viewportWidth;
        _captureHeight = _viewportHeight;
        [self sendGeometryUpdate];
    }

    /* Reconfigure capture for LZ4 compression (clears onPixelBuffer so LZ4 path runs) */
    [self configureFrameDelivery];

    if (self.onModeChanged) {
        self.onModeChanged(NO);
    }
}

- (void)switchToHEVCMode {
    os_log(sLog, "Switching to HEVC mode (encoder deferred until iPad viewport report)");
    [self wifiAckResetWithReason:"hevc-mode"];

    if (_compressorInitialized) {
        FrameCompressorState state = _compressorState;
        frame_compressor_destroy(&state);
        _compressorState = state;
        _compressorInitialized = NO;
    }

    /* Ensure display dimensions are available for the handshake.
     * Encoder does NOT start here — it starts when iPad sends viewport dims. */
    if (_captureWidth == 0 || _captureHeight == 0) {
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(mainDisplay);
        if (mode) {
            _captureWidth = (uint32_t)CGDisplayModeGetPixelWidth(mode);
            _captureHeight = (uint32_t)CGDisplayModeGetPixelHeight(mode);
            size_t logicalWidth = CGDisplayModeGetWidth(mode);
            _captureScale = (logicalWidth > 0) ? (float)_captureWidth / (float)logicalWidth : 2.0f;
            CGDisplayModeRelease(mode);
            os_log(sLog, "HEVC: resolved display dimensions %ux%u @%.1fx",
                   _captureWidth, _captureHeight, _captureScale);
        }
    }

    /* If viewport already known (reconnect), start encoder immediately */
    if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        [self _startEncoderAtViewportResolution];
    } else {
        os_log(sLog, "HEVC encoder deferred — waiting for iPad viewport report");
    }

    /* Reconfigure frame delivery for HEVC */
    [self configureFrameDelivery];

    if (self.onModeChanged) {
        self.onModeChanged(YES);
    }
}

- (void)sendTransportChangeNotification {
    /* Send mode_change InputEventHeader to iPad via TCP */
    InputEventHeader header;
    header.type = KEYDRD_INPUT_MODE_CHANGE;
    header.ts_us = [self currentTimestampUs];

    [self sendInputEventToiPad:&header length:sizeof(header)];
}

#pragma mark - Streaming

- (void)onTransportConnected {
    os_log(sLog, "Transport connected -- sending handshake (state=%{public}s transport=%{public}s usbConnected=%{public}d wifiConnected=%{public}d viewportReceived=%{public}d viewport=%ux%u hevcActive=%{public}d)",
           [self sessionStateName:_sessionState],
           transport_state_name(_transportState),
           _usbTransport.isConnected, _wirelessTransport.isConnected,
           _viewportReceived, _viewportWidth, _viewportHeight,
           _hevcEncoder.isActive);
    _awaitingMedia = NO;
    _tcpMediaSendsInFlight = 0;
    _wifiTCPMediaSendsInFlight = 0;
    _wifiTCPLastCompletionUs = 0;
    _wifiTCPInFlightSaturatedSinceUs = 0;
    _wifiTCPLastStallRecoveryUs = 0;
    _wifiTCPStallLastLogUs = 0;
    _wifiTCPSchedulerWindowStartUs = 0;
    _wifiTCPSchedulerLastSubmitUs = 0;
    _wifiTCPSchedulerWindowSendCount = 0;
    _wifiTCPSendGeneration += 1;
    [self wifiAckResetWithReason:"transport-connected"];
    _sessionWirelessEpoch = _wirelessTransport.inputConnectionEpoch;
    os_log(sLog, "LC Restart session=%u (handshake, gate reset, encoder restart)", _sessionWirelessEpoch);
    _wirelessLastEncodeSubmitUs = 0;
    [self resetWiFiAdaptiveControlState];
    [self stopWirelessPerformanceTimer];
    [self transitionTo:SESSION_STREAMING];

    /* Send session handshake (also sets _captureWidth/_captureHeight) */
    [self sendSessionHandshake];

    /* HEVC encoder starts when iPad sends viewport report (after receiving this handshake).
     * Only needed for WiFi/AWDL — USB uses LZ4 (no HEVC encoder). */
    if (_usbTransport.isConnected) {
        os_log(sLog, "USB LZ4 mode — no HEVC encoder needed, capture at native %ux%u",
               _captureWidth, _captureHeight);
    } else if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        [self _startEncoderAtViewportResolution];
    } else {
        os_log(sLog, "HEVC encoder deferred — waiting for iPad viewport report after handshake");
    }

    /* Set up frame delivery */
    [self configureFrameDelivery];

    /* For wireless: defer capture until DTLS media channel is ready.
     * HEVC frames are sent via UDP/DTLS — sending before the media
     * connection is established just drops frames silently. */
    if (_wirelessTransport.isConnected && !_usbTransport.isConnected) {
        if (_wirelessTransport.mediaChannelReady) {
            os_log(sLog, "Media channel already ready -- starting capture now");
            [self _beginCapture];
        } else {
            _awaitingMedia = YES;
            os_log(sLog, "Capture deferred until media channel ready");
        }
    } else if (_usbTransport.isConnected && !_hevcEncoder.isActive) {
        /* USB LZ4 mode: defer capture until viewport report arrives.
         * Starting now would capture at 3600x2338 (handshake res), then resize
         * when viewport arrives — but transitional frames at the old size crash
         * the iPad LZ4 decompressor (buffer sized for new dims, frame is old size).
         * Capture starts in handleViewportReport after resize + geometry update. */
        if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
            /* Viewport already known (reconnect) — start immediately at viewport res */
            os_log(sLog, "USB LZ4: viewport known (%ux%u), starting capture now",
                   _viewportWidth, _viewportHeight);
            [self _beginCapture];
        } else {
            os_log(sLog, "USB LZ4: deferring capture until viewport report (avoids size mismatch crash)");
        }
    } else {
        /* USB HEVC or other: start capture immediately */
        [self _beginCapture];
    }

    /* Start latency probe timer (every 1 second) */
    [self startLatencyProbeTimer];
    [self startWirelessPerformanceTimerIfNeeded];
}

- (void)_beginCapture {
    [_capture startCapture];

    /* In explicit real-capture mode, show the same stress scene that synthetic mode
     * renders directly. This isolates ScreenCaptureKit as the primary variable. */
    if (_testMode && _testCaptureFilePath.length == 0 && !_testCaptureStressMode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CGDirectDisplayID capturedDisplay = CGMainDisplayID();
            NSScreen *screen = nil;
            for (NSScreen *s in [NSScreen screens]) {
                NSDictionary *desc = [s deviceDescription];
                NSNumber *screenNumber = desc[@"NSScreenNumber"];
                if (screenNumber && [screenNumber unsignedIntValue] == capturedDisplay) {
                    screen = s;
                    break;
                }
            }
            if (!screen) screen = [NSScreen mainScreen];
            [self.stressWindowTimer invalidate];
            self.stressWindowTimer = nil;
            [self.stressWindow orderOut:nil];

            NSWindow *stressWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                                                 styleMask:NSWindowStyleMaskBorderless
                                                                   backing:NSBackingStoreBuffered
                                                                     defer:NO];
            stressWindow.level = NSFloatingWindowLevel + 1;
            stressWindow.opaque = YES;
            stressWindow.backgroundColor = NSColor.blackColor;
            stressWindow.ignoresMouseEvents = YES;
            stressWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

            StressPatternView *patternView = [[StressPatternView alloc] initWithFrame:stressWindow.contentView.bounds];
            patternView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            stressWindow.contentView = patternView;

            self.stressWindow = stressWindow;
            [stressWindow orderFront:nil];
            os_log(sLog, "Test mode: real-capture stress window active at %.0fx%.0f",
                   screen.frame.size.width, screen.frame.size.height);

            __weak SessionManager *weakSelf = self;
            self.stressWindowTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/120.0 repeats:YES block:^(NSTimer *timer) {
                SessionManager *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) {
                    [timer invalidate];
                    return;
                }
                StressPatternView *view = (StressPatternView *)strongSelf.stressWindow.contentView;
                if (![view isKindOfClass:[StressPatternView class]]) {
                    return;
                }
                view.frameIndex += 1;
                if (view.frameIndex < 10 || view.frameIndex % 120 == 0) {
                    CGFloat scale = strongSelf.stressWindow.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
                    if (scale <= 0.0) scale = 1.0;
                    size_t pixelWidth = (size_t)llround(view.bounds.size.width * scale);
                    size_t pixelHeight = (size_t)llround(view.bounds.size.height * scale);
                    uint64_t sig = KeydStressSceneSignature(CGSizeMake(pixelWidth, pixelHeight), view.frameIndex);
                    uint32_t sceneCRC = KeydStressSceneCRC(pixelWidth, pixelHeight, view.frameIndex);
                    os_log(sLog, "FRAME-CHECK source real-capture frame=%llu sig=%{public}016llx scene_crc=%08x size=%zux%zu scale=%.2f",
                           view.frameIndex, sig, sceneCRC, pixelWidth, pixelHeight, scale);
                }
                [view setNeedsDisplay:YES];
            }];
        });
    } else if (_testMode && (_testCaptureFilePath.length > 0 || _testCaptureStressMode)) {
        if (_testCaptureStressMode) {
            os_log(sLog, "Test mode: using procedural full-frame stress capture");
        } else {
            os_log(sLog, "Test mode: using synthetic capture frames from %{public}@",
                   _testCaptureFilePath);
        }
    }
}

- (void)sendSessionHandshake {
    /* Get display geometry from primary display via CoreGraphics */
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    _captureWidth = (uint32_t)CGDisplayPixelsWide(mainDisplay);
    _captureHeight = (uint32_t)CGDisplayPixelsHigh(mainDisplay);

    /* Calculate scale factor from display mode */
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(mainDisplay);
    if (mode) {
        size_t modeWidth = CGDisplayModeGetPixelWidth(mode);
        size_t logicalWidth = CGDisplayModeGetWidth(mode);
        _captureScale = (logicalWidth > 0) ? (float)modeWidth / (float)logicalWidth : 2.0f;

        /* Use pixel dimensions for capture */
        _captureWidth = (uint32_t)modeWidth;
        _captureHeight = (uint32_t)CGDisplayModeGetPixelHeight(mode);
        CGDisplayModeRelease(mode);
    }

    SessionHandshakeMessage handshake = {
        .magic = KEYDRD_MAGIC,
        .msg_type = KEYDRD_MSG_SESSION_HANDSHAKE,
        .display_width = _captureWidth,
        .display_height = _captureHeight,
        .scale_factor = _captureScale,
        .aspect_ratio = (float)(_captureWidth) / (float)(_captureHeight),
        .capabilities = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE,
        .max_fps = 120,
        .agent_version = 1,
        .reserved = 0   /* FrameLoop epoch, set per send */
    };

    /* tla/FrameLoop.tla HsConn: every session handshake carries a fresh epoch, goes on the
     * connection media will use, and owes a keyframe. If no connection is current, the next
     * frame's gate sends it (route key cleared). */
    uint64_t flNowUs = keydrd_host_time_us();
    os_unfair_lock_lock(&_flLock);
    _flHs = handshake;
    _flHsCached = YES;
    uint32_t flConn = 0;
    FLRoute flRoute = [self flCurrentRouteEpoch:&flConn];
    if (![self flSendHandshakeLockedOnRoute:flRoute epoch:flConn reason:"session" nowUs:flNowUs]) {
        _flRouteKey = 0;
        [self flNeedKeyLocked:"handshake-unsent" nowUs:flNowUs];
        os_log(sLog, "FL MacHsDeferred route=%{public}s conn=%u (sent by the next frame's gate)",
               fl_route_name(flRoute), flConn);
    }
    _flLastKeyReqUs = flNowUs;
    os_unfair_lock_unlock(&_flLock);
    [self flRequestKeyframe:"handshake"];
    [self flStartIdleTimerIfNeeded];

    os_log(sLog, "Sent session handshake: %ux%u @%.1fx, aspect=%.4f",
           _captureWidth, _captureHeight, _captureScale, handshake.aspect_ratio);

    if (self.onResolutionChanged) {
        self.onResolutionChanged(_captureWidth, _captureHeight);
    }
}

- (void)configureFrameDelivery {
    __weak SessionManager *weakSelf = self;

    /* LZ4 gate: skip compressing while the USB sender is saturated (DeltaSync GateBeforeCompress). */
    _capture.shouldCompressFrame = ^BOOL(void) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return NO;
        /* tla/DeltaSync.tla GateBeforeCompress + T4: LZ4 is USB-only. With no USB connection
         * (the ~0.3 s between USB NCM appearing and its TLS input READY, and the unplug window
         * before HEVC) compressed frames went out over AWDL, where the iPad drops them (seen:
         * 26 deltas + a 3 MB keyframe on one replug). Skip them; the reference does not move and
         * the keyframe requested on connect resyncs. */
        if (!strongSelf->_usbTransport.isConnected) {
            static uint32_t gateNoUSB = 0;
            if ((gateNoUSB++ % 120) == 0) os_log(sLog, "LZ4 compress skipped: no USB connection (count=%u)", gateNoUSB);
            return NO;
        }
        int32_t inFlight = __atomic_load_n(&strongSelf->_tcpMediaSendsInFlight, __ATOMIC_ACQUIRE);
        return inFlight < kUSBLZ4GateInFlight;
    };

    /* LZ4 compressed frame callback (wired/USB mode) */
    _capture.onFrame = ^(CompressOutput *output) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.sessionState != SESSION_STREAMING) {
            /* Compressed (the LZ4 reference moved) but never sent: KeyOnBreak loss. */
            [strongSelf flNoteLoss:"lz4-not-streaming" seq:output->header.seq];
            return;
        }

        if (strongSelf->_hevcEncoder.isActive) {
            /* HEVC mode: frames sent via onEncodedFrame callback instead. Not a loss for the
             * FrameLoop gate: this LZ4 chain is abandoned, and resuming LZ4 is a codec change,
             * which owes a keyframe at the gate. */
            return;
        }

        /* LZ4 mode: prepend MediaFrameHeader + send via active transport */
        /* Log frame sizes for debugging bandwidth issues */
        static int lz4SendCount = 0;
        if (lz4SendCount < 10 || lz4SendCount % 200 == 0) {
            BOOL isKey = (output->header.flags & KEYDRD_FLAG_KEYFRAME) != 0;
            os_log(sLog, "LZ4 frame #%d: %zu bytes compressed (%s), seq=%u",
                   lz4SendCount, output->compressed_size,
                   isKey ? "KEYFRAME" : "delta",
                   output->header.seq);
        }
        lz4SendCount++;
        [strongSelf sendMediaFrameHeaderToiPad:&output->header
                                       payload:output->buf
                                 payloadLength:output->compressed_size];
    };

    /* Raw pixel buffer callback — feeds HEVC encoder when active.
     * CRITICAL: only set this when HEVC is active. ScreenCapture.didOutputSampleBuffer
     * checks `if (self.onPixelBuffer)` — if non-nil, it skips LZ4 compression entirely.
     * Setting a block that just returns early still prevents LZ4 from running. */
    if (_hevcEncoder.isActive) {
        _capture.onPixelBuffer = ^(CVPixelBufferRef pixelBuffer, CMTime timestamp, uint64_t captureTimestampUs) {
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;
            if (!strongSelf->_hevcEncoder.isActive) return;

            if (strongSelf->_wirelessTransport.isConnected &&
                !strongSelf->_usbTransport.isConnected) {
                if (kWirelessUseTCPMedia) {
                    int32_t tcpInFlightNow = strongSelf->_wifiTCPMediaSendsInFlight;
                    uint64_t nowUs = keydrd_host_time_us();
                    uint64_t frameAgeMs = 0;
                    BOOL frameAgeValid = NO;
                    if (captureTimestampUs > 0 && nowUs > captureTimestampUs) {
                        frameAgeMs = (nowUs - captureTimestampUs) / 1000;
                        frameAgeValid = YES;
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeAgeSamples);
                        OSAtomicAdd32Barrier((int32_t)MIN(frameAgeMs, (uint64_t)INT32_MAX), &strongSelf->_wifiPerfPreEncodeAgeTotalMs);
                        int32_t frameAgeClamp = (int32_t)MIN(frameAgeMs, (uint64_t)INT32_MAX);
                        if (frameAgeClamp > strongSelf->_wifiPerfPreEncodeStaleMaxAgeMs) {
                            strongSelf->_wifiPerfPreEncodeStaleMaxAgeMs = frameAgeClamp;
                        }
                    }
                    uint64_t staleDropThresholdMs = kWirelessPreEncodeStaleDropBaseMs;
                    if (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi ||
                        strongSelf->_wifiPerfTCPSlowCompletions > 0 ||
                        strongSelf->_wifiPerfTCPMaxCompletionMs >= (int32_t)kWirelessTCPSlowCompletionThresholdMs) {
                        staleDropThresholdMs = kWirelessPreEncodeStaleDropCongestedMs;
                    }
                    if (tcpInFlightNow > kMaxMediaSendsInFlightWiFi ||
                        strongSelf->_wifiPerfTCPMaxCompletionMs >= 40 ||
                        strongSelf->_wifiPerfPreEncodeDrops >= 2) {
                        staleDropThresholdMs = kWirelessPreEncodeStaleDropSevereMs;
                    }
                    if (frameAgeValid &&
                        (frameAgeMs >= staleDropThresholdMs || frameAgeMs >= kWirelessPreEncodeStaleDropAbsoluteMs)) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeDrops);
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeStaleDrops);
                        strongSelf.wifiAdaptiveLastStaleDropUs = nowUs;
                        static int wifiStalePreEncodeDropCount = 0;
                        wifiStalePreEncodeDropCount++;
                        if (frameAgeMs >= kWirelessPreEncodeStaleDropAbsoluteMs ||
                            wifiStalePreEncodeDropCount <= 10 || wifiStalePreEncodeDropCount % 80 == 0) {
                            os_log(sLog, "WiFi pre-encode drop: reason=stale-age age=%llums threshold=%llums absThreshold=%llums inFlight=%d slow=%d maxCompletion=%dms totalDropped=%d sampled=%{public}s",
                                   frameAgeMs, staleDropThresholdMs, kWirelessPreEncodeStaleDropAbsoluteMs,
                                   tcpInFlightNow, strongSelf->_wifiPerfTCPSlowCompletions, strongSelf->_wifiPerfTCPMaxCompletionMs,
                                   wifiStalePreEncodeDropCount,
                                   (frameAgeMs >= kWirelessPreEncodeStaleDropAbsoluteMs) ? "forced" : "sampled");
                        }
                        return;
                    }
                    /* No stall reset (tla/WiFiSendLoop.tla NoBlindReset): the count falls only when
                     * frames leave. With acks the gate counts frames the iPad has not received
                     * (AckGate); before the first ack, the kernel in-flight count. */
                    /* tla/Lifecycle.tla CountOnSend: encode only while a ready current connection
                     * exists (degraded control path or a candidate not yet READY): a frame that
                     * cannot be queued must never enter the gate count. */
                    if (!strongSelf->_wirelessTransport.hasReadyInputConnection) {
                        static int lcNoControlHolds = 0;
                        lcNoControlHolds++;
                        if (lcNoControlHolds <= 5 || lcNoControlHolds % 100 == 0) {
                            os_log(sLog, "LC MacEncodeHold reason=no-ready-connection count=%d", lcNoControlHolds);
                        }
                        return;
                    }
                    int32_t ackUnacked = [strongSelf wifiAckUnackedFrames];
                    BOOL gateClosed = ackUnacked >= 0 ? (ackUnacked >= kWiFiAckGateFrames)
                                                      : (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi);
                    if (gateClosed) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeDrops);
                        static int wifiTCPPreEncodeDropCount = 0;
                        wifiTCPPreEncodeDropCount++;
                        if (wifiTCPPreEncodeDropCount <= 10 || wifiTCPPreEncodeDropCount % 100 == 0) {
                            os_log(sLog, "WiFi pre-encode drop: reason=%{public}s unacked=%d ackLimit=%d inFlight=%d limit=%d totalDropped=%d",
                                   ackUnacked >= 0 ? "ack-gate" : "tcp-backpressure",
                                   ackUnacked, kWiFiAckGateFrames,
                                   tcpInFlightNow, kMaxMediaSendsInFlightWiFi, wifiTCPPreEncodeDropCount);
                        }
                        if (ackUnacked >= 0) {
                            [strongSelf wifiAckNoteGateHold];
                        }
                        return;
                    }
                    static int wifiTCPPreEncodeAdmitCount = 0;
                    wifiTCPPreEncodeAdmitCount++;
                    if (wifiTCPPreEncodeAdmitCount <= 10 || wifiTCPPreEncodeAdmitCount % 200 == 0) {
                        os_log(sLog, "WiFi pre-encode admit: reason=%{public}s unacked=%d inFlight=%d limit=%d age=%llums staleThreshold=%llums",
                               ackUnacked >= 0 ? "ack-gate-clear" : "tcp-backpressure-clear",
                               ackUnacked, tcpInFlightNow, kMaxMediaSendsInFlightWiFi,
                               frameAgeValid ? frameAgeMs : 0, staleDropThresholdMs);
                    }
                    strongSelf.wirelessLastEncodeSubmitUs = 0;
                } else {
                NSUInteger queuedChunks = strongSelf->_wirelessTransport.queuedMediaChunkCount;
                uint64_t minIntervalUs = 0;
                const char *congestionReason = "none";
                if (queuedChunks > kWirelessSevereCongestionChunkThreshold) {
                    minIntervalUs = kWirelessSevereCongestedFrameIntervalUs;
                    congestionReason = "severe";
                } else if (queuedChunks > kWirelessMildCongestionChunkThreshold) {
                    minIntervalUs = kWirelessMildCongestedFrameIntervalUs;
                    congestionReason = "mild";
                }
                if (minIntervalUs > 0) {
                    uint64_t submitTimeUs = captureTimestampUs > 0 ? captureTimestampUs : keydrd_host_time_us();
                    uint64_t nextSubmitUs = strongSelf.wirelessLastEncodeSubmitUs;
                    if (nextSubmitUs > 0 &&
                        submitTimeUs + kWirelessPacingToleranceUs < nextSubmitUs) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeDrops);
                        static int wifiPreEncodeDropCount = 0;
                        wifiPreEncodeDropCount++;
                        if (wifiPreEncodeDropCount <= 10 || wifiPreEncodeDropCount % 100 == 0) {
                            os_log(sLog, "WiFi pre-encode drop: reason=%{public}s queued=%lu minInterval=%lluus delta=%lluus totalDropped=%d",
                                   congestionReason, (unsigned long)queuedChunks, minIntervalUs,
                                   nextSubmitUs > submitTimeUs ? nextSubmitUs - submitTimeUs : 0,
                                   wifiPreEncodeDropCount);
                        }
                        return;
                    }
                    uint64_t scheduledSubmitUs = nextSubmitUs > submitTimeUs ? nextSubmitUs : submitTimeUs;
                    strongSelf.wirelessLastEncodeSubmitUs = scheduledSubmitUs + minIntervalUs;
                    static int wifiPreEncodeAdmitCount = 0;
                    wifiPreEncodeAdmitCount++;
                    if (wifiPreEncodeAdmitCount <= 10 || wifiPreEncodeAdmitCount % 200 == 0) {
                        os_log(sLog, "WiFi pre-encode admit: reason=%{public}s queued=%lu scheduleDelay=%lluus",
                               congestionReason, (unsigned long)queuedChunks,
                               scheduledSubmitUs > submitTimeUs ? scheduledSubmitUs - submitTimeUs : 0);
                    }
                } else {
                    strongSelf.wirelessLastEncodeSubmitUs = 0;
                }
                }
            }

            [strongSelf->_hevcEncoder encodePixelBuffer:pixelBuffer timestamp:timestamp captureTimestampUs:captureTimestampUs];
        };
    } else {
        /* LZ4 mode: clear onPixelBuffer so ScreenCapture falls through to LZ4 compression */
        _capture.onPixelBuffer = nil;
    }

    /* HEVC encoder output callback */
    _hevcEncoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.sessionState != SESSION_STREAMING) {
            [strongSelf flNoteLoss:"hevc-not-streaming" seq:header.seq];  /* encoded, never sent */
            return;
        }

        static int hevcSentCount = 0;
        if (hevcSentCount < 3) {
            os_log(sLog, "HEVC onEncodedFrame: seq=%u len=%zu flags=0x%02x, sending via UDP chunks",
                   header.seq, len, header.flags);
        }
        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfEncodedFrames);
        OSAtomicAdd32Barrier((int32_t)MIN(len, (size_t)INT32_MAX), &strongSelf->_wifiPerfEncodedBytes);
        if ((header.flags & KEYDRD_FLAG_KEYFRAME) != 0) {
            OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfKeyframes);
        }
        if ((int32_t)len > strongSelf->_wifiPerfMaxFrameBytes) {
            strongSelf->_wifiPerfMaxFrameBytes = (int32_t)MIN(len, (size_t)INT32_MAX);
        }
        int32_t frameBytes = (int32_t)MIN(len, (size_t)INT32_MAX);
        if (frameBytes >= kWirelessBurstTailFrameBytes) {
            OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfBurstTailFrames);
        }
        if (frameBytes >= kWirelessBurstSevereFrameBytes) {
            OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfBurstSevereFrames);
        }

        /* Pipeline latency probe: capture → TCP send */
        if (header.ts_us > 0) {
            uint64_t nowUs = (uint64_t)(CACurrentMediaTime() * 1000000.0);
            uint64_t sendElapsedMs = (nowUs - header.ts_us) / 1000;
            if (hevcSentCount < 10 || hevcSentCount % 100 == 0) {
                os_log(sLog, "LATENCY-PROBE tcp-send: %llu ms since capture (seq=%u, %zu bytes)",
                       sendElapsedMs, header.seq, len);
            }
        }

        hevcSentCount++;

        [strongSelf sendMediaFrameHeaderToiPad:&header
                                       payload:data
                                 payloadLength:len];
    };
}

#pragma mark - Transport Send Helpers

#pragma mark - FrameLoop send gate (tla/FrameLoop.tla)

typedef NS_ENUM(uint32_t, FLRoute) { FLRouteNone = 0, FLRouteUSB = 1, FLRouteWiFi = 2 };

static const char *fl_route_name(uint32_t r) {
    return r == FLRouteUSB ? "usb" : (r == FLRouteWiFi ? "wifi" : "none");
}

static NSString * const kFLLastEpochDefaultsKey = @"FLLastHandshakeEpoch";

/* EpochMonotone: larger than the previous epoch, than the last one persisted (an earlier agent
 * run) and than 16 per wall-clock second since 2023-11-14 (in case the defaults were lost).
 * Assumption (FrameLoop.tla F6): the wall clock does not step back across relaunches by more
 * than the persisted value covers. Wraps in 2032. */
- (uint32_t)flNextEpochLocked {
    uint64_t t = (uint64_t)time(NULL);
    uint64_t clockEpoch = t > 1700000000ULL ? (t - 1700000000ULL) * 16ULL : 0;
    uint64_t persisted = (uint64_t)[[NSUserDefaults standardUserDefaults] integerForKey:kFLLastEpochDefaultsKey];
    uint64_t e = (uint64_t)_flEpoch + 1;
    if (persisted + 1 > e) e = persisted + 1;
    if (clockEpoch > e) e = clockEpoch;
    if (e > UINT32_MAX) e = UINT32_MAX;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)e forKey:kFLLastEpochDefaultsKey];
    return (uint32_t)e;
}

/* Where media goes now, the same choice sendInputEventToiPad and the submit sites make. */
- (FLRoute)flCurrentRouteEpoch:(uint32_t *)outEpoch {
    if (_usbTransport.isConnected) {
        *outEpoch = _usbTransport.inputConnectionEpoch;
        return FLRouteUSB;
    }
    if (_wirelessTransport.isConnected && _wirelessTransport.hasReadyInputConnection) {
        *outEpoch = _wirelessTransport.inputConnectionEpoch;
        return FLRouteWiFi;
    }
    *outEpoch = 0;
    return FLRouteNone;
}

/* A frame that will never reach the iPad (any send failure, any post-encode drop): the next
 * frame must be a keyframe. Lock-free: transport completions can run synchronously inside the
 * gate; the gate absorbs the count before its next decision. */
- (void)flNoteLoss:(const char *)reason seq:(uint32_t)seq {
    int32_t n = OSAtomicIncrement32Barrier(&_flLossPending);
    static int32_t lossLogs = 0;
    int32_t c = OSAtomicIncrement32Barrier(&lossLogs);
    if (c <= 50 || c % 100 == 0) {
        os_log(sLog, "FL MacLoss reason=%{public}s seq=%u pending=%d total=%d", reason, seq, n, c);
    }
}

- (void)flNeedKeyLocked:(const char *)reason nowUs:(uint64_t)nowUs {
    if (_flNeedKey) return;
    _flNeedKey = YES;
    _flNeedReason = reason;
    _flNeedSinceUs = nowUs;
    _flHeld = 0;
    _flLastKeyReqUs = 0;  /* request at once */
    os_log(sLog, "FL MacNeedKey reason=%{public}s ep=%u route=%{public}s",
           reason, _flEpoch, fl_route_name((uint32_t)(_flRouteKey >> 32)));
}

/* Both codecs: the inactive one ignores it (HEVC) or starts with a key anyway (LZ4 resume). */
- (void)flRequestKeyframe:(const char *)reason {
    [_hevcEncoder requestKeyframe];
    [_capture requestLZ4Keyframe];
    static int32_t reqLogs = 0;
    int32_t c = OSAtomicIncrement32Barrier(&reqLogs);
    if (c <= 50 || c % 50 == 0) {
        os_log(sLog, "FL MacKeyReq reason=%{public}s hevcActive=%{public}d count=%d",
               reason, _hevcEncoder.isActive, c);
    }
}

/* HsConn: this session's handshake, with a fresh epoch, on the connection `epoch` names.
 * NO if that connection is no longer current (nothing sent). */
- (BOOL)flSendHandshakeLockedOnRoute:(FLRoute)route epoch:(uint32_t)connEpoch
                               reason:(const char *)reason nowUs:(uint64_t)nowUs {
    if (!_flHsCached || route == FLRouteNone || connEpoch == 0) return NO;
    SessionHandshakeMessage hs = _flHs;
    uint32_t ep = [self flNextEpochLocked];
    hs.reserved = ep;
    BOOL sent = (route == FLRouteUSB)
        ? [_usbTransport sendInputEvent:&hs length:sizeof(hs) onEpoch:connEpoch]
        : [_wirelessTransport sendInputEvent:&hs length:sizeof(hs) onEpoch:connEpoch];
    if (!sent) {
        os_log(sLog, "FL MacHsUnsent route=%{public}s conn=%u reason=%{public}s (connection no longer current)",
               fl_route_name(route), connEpoch, reason);
        return NO;
    }
    uint64_t oldKey = _flRouteKey;
    _flEpoch = ep;
    _flRouteKey = ((uint64_t)route << 32) | connEpoch;
    os_log(sLog, "FL MacHs ep=%u route=%{public}s conn=%u prevRoute=%{public}s prevConn=%u reason=%{public}s %ux%u",
           ep, fl_route_name(route), connEpoch, fl_route_name((uint32_t)(oldKey >> 32)),
           (uint32_t)(oldKey & 0xFFFFFFFFu), reason, hs.display_width, hs.display_height);
    _flNeedKey = NO;  /* re-arm so the log names the handshake */
    [self flNeedKeyLocked:"handshake" nowUs:nowUs];
    return YES;
}

/* The gate (under _flLock, held through the submit). YES: submit this frame on (route, epoch)
 * now. NO: drop it (it was never sent; for deltas the key is owed). *requestKey: ask the
 * encoders for a keyframe after unlocking. */
- (BOOL)flAdmitLocked:(const MediaFrameHeader *)h route:(FLRoute)route epoch:(uint32_t)connEpoch
           requestKey:(BOOL *)requestKey {
    uint64_t nowUs = keydrd_host_time_us();
    BOOL isKey = (h->flags & KEYDRD_FLAG_KEYFRAME) != 0;
    int codec = (h->flags & KEYDRD_FLAG_HEVC) ? 1 : 0;
    _flLastFrameUs = nowUs;

    int32_t losses = __atomic_exchange_n(&_flLossPending, 0, __ATOMIC_ACQ_REL);
    if (losses > 0) [self flNeedKeyLocked:"loss" nowUs:nowUs];
    uint32_t encDrops = _hevcEncoder.droppedOutputCount;
    if (encDrops != _flEncDropSeen) {
        _flEncDropSeen = encDrops;
        [self flNeedKeyLocked:"encoder-drop" nowUs:nowUs];
    }

    BOOL admit = YES;
    const char *hold = NULL;
    if (!_flHsCached || route == FLRouteNone || connEpoch == 0) {
        hold = !_flHsCached ? "no-handshake" : "no-connection";
        [self flNeedKeyLocked:hold nowUs:nowUs];
        admit = NO;
    } else if ((((uint64_t)route << 32) | connEpoch) != _flRouteKey &&
               ![self flSendHandshakeLockedOnRoute:route epoch:connEpoch reason:"route" nowUs:nowUs]) {
        hold = "handshake-unsent";
        [self flNeedKeyLocked:hold nowUs:nowUs];
        admit = NO;
    }
    if (admit) {
        if (codec != _flLastCodec) {
            if (_flLastCodec >= 0) [self flNeedKeyLocked:"codec" nowUs:nowUs];
            _flLastCodec = codec;
        }
        if (_flNeedKey && !isKey) {
            hold = "delta";
            admit = NO;
        }
    }

    if (!admit) {
        _flHeld++;
        if (_flHeld <= 3 || _flHeld % 60 == 0) {
            os_log(sLog, "FL MacHoldDelta seq=%u key=%{public}d codec=%{public}s hold=%{public}s need=%{public}s held=%u sinceMs=%llu ep=%u",
                   h->seq, isKey, codec ? "hevc" : "lz4", hold, _flNeedReason ?: "-", _flHeld,
                   (nowUs - _flNeedSinceUs) / 1000, _flEpoch);
        }
    } else if (isKey && _flNeedKey) {
        os_log(sLog, "FL MacKey seq=%u codec=%{public}s ep=%u route=%{public}s need=%{public}s held=%u waitMs=%llu",
               h->seq, codec ? "hevc" : "lz4", _flEpoch, fl_route_name(route), _flNeedReason ?: "-",
               _flHeld, (nowUs - _flNeedSinceUs) / 1000);
        _flNeedKey = NO;
        _flNeedReason = NULL;
        _flHeld = 0;
    }
    if (_flNeedKey && nowUs - _flLastKeyReqUs >= 100000) {
        _flLastKeyReqUs = nowUs;
        *requestKey = YES;
    }
    return admit;
}

/* IdleKey: while a key is owed and no frame has reached the gate for a while (static screen:
 * SCStream sends only idle frames), re-deliver the last frame through the active path. */
- (void)flStartIdleTimerIfNeeded {
    if (_flIdleTimer) return;
    _flIdleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(_flIdleTimer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak SessionManager *weakSelf = self;
    dispatch_source_set_event_handler(_flIdleTimer, ^{
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;
        uint64_t nowUs = keydrd_host_time_us();
        BOOL reemit = NO;
        uint64_t sinceMs = 0, idleMs = 0;
        os_unfair_lock_lock(&strongSelf->_flLock);
        if (strongSelf->_flNeedKey && strongSelf->_flHsCached &&
            nowUs - strongSelf->_flNeedSinceUs >= 150000 &&
            nowUs - strongSelf->_flLastFrameUs >= 100000 &&
            nowUs - strongSelf->_flLastReemitUs >= 150000) {
            strongSelf->_flLastReemitUs = nowUs;
            strongSelf->_flLastKeyReqUs = nowUs;
            sinceMs = (nowUs - strongSelf->_flNeedSinceUs) / 1000;
            idleMs = (nowUs - strongSelf->_flLastFrameUs) / 1000;
            reemit = YES;
        }
        os_unfair_lock_unlock(&strongSelf->_flLock);
        if (!reemit) return;
        os_log(sLog, "FL MacIdleKey sinceMs=%llu idleMs=%llu", sinceMs, idleMs);
        [strongSelf flRequestKeyframe:"idle"];
        [strongSelf->_capture reemitLastFrame];
    });
    dispatch_resume(_flIdleTimer);
}

- (void)sendMediaFrameToiPad:(const void *)data length:(size_t)len {
    if (len < sizeof(MediaFrameHeader)) return;

    const MediaFrameHeader *originalHeader = (const MediaFrameHeader *)data;
    const void *payload = (const uint8_t *)data + sizeof(MediaFrameHeader);
    size_t payloadLen = len - sizeof(MediaFrameHeader);

    if (_usbTransport.isConnected) {
        /* No frame size cap: LZ4 delta compression makes dropping frames
         * catastrophic — the iPad's delta reference desynchronizes and ALL
         * subsequent frames render as garbage until the next keyframe.
         * TCP backpressure (max 2 in-flight sends) is the only safe gate
         * because it fires rarely enough to avoid visible corruption. */

        /* USB NCM: media frames via TCP with length-prefix framing + backpressure.
         * TCP with TCP_NODELAY gives 0% loss at 1ms transport RTT.
         *
         * Backpressure: track in-flight TCP sends. If too many are queued
         * in the kernel buffer, drop this frame — the next frame will carry
         * fresher content anyway. This prevents multi-second queue buildup
         * that causes stale-timestamp latency inflation. */
        os_unfair_lock_lock(&_flLock);
        uint32_t flConn = _usbTransport.inputConnectionEpoch;
        BOOL flRequestKey = NO;
        if (![self flAdmitLocked:originalHeader route:FLRouteUSB epoch:flConn requestKey:&flRequestKey]) {
            os_unfair_lock_unlock(&_flLock);
            if (flRequestKey) [self flRequestKeyframe:"hold"];
            return;
        }
        int32_t inFlight = OSAtomicIncrement32Barrier(&_tcpMediaSendsInFlight);
        if (inFlight <= 5 || inFlight % 10 == 0) {
            os_log(sLog, "USB send queued: seq=%u inFlight=%d bytes=%zu", originalHeader->seq, inFlight, len);
        }
        if (inFlight > kMaxMediaSendsInFlightUSB) {
            /* Never drop a compressed frame (DeltaSync NoCorruption). The LZ4 gate before
             * compression keeps this unreachable; if it fires, send anyway and say so. */
            static int overLimitCount = 0;
            overLimitCount++;
            if (overLimitCount <= 10 || overLimitCount % 500 == 0) {
                os_log_error(sLog, "USB send over in-flight limit (gate missed): seq=%u inFlight=%d total=%d — sending, not dropping",
                             originalHeader->seq, inFlight, overLimitCount);
            }
        }

        __weak SessionManager *weakSelf = self;
        const uint32_t sentSeq = originalHeader->seq; /* copy: header memory is gone by completion */
        [_usbTransport sendMediaViaTCP:data length:len onEpoch:flConn completion:^(BOOL success) {
            SessionManager *strongSelf = weakSelf;
            if (strongSelf) {
                int32_t left = OSAtomicDecrement32Barrier(&strongSelf->_tcpMediaSendsInFlight);
                if (!success || left < 2) {
                    os_log(sLog, "USB send completion: seq=%u success=%{public}s inFlightNow=%d",
                           sentSeq, success ? "yes" : "no", left);
                }
                if (!success) [strongSelf flNoteLoss:"usb-send" seq:sentSeq];
            }
        }];
        os_unfair_lock_unlock(&_flLock);
        if (flRequestKey) [self flRequestKeyframe:"pending"];
    } else if (_wirelessTransport.isConnected) {
        if (kWirelessUseTCPMedia) {
            /* WiFi media is now kept on the established TLS/TCP stream.
             * The paced DTLS chunk path still works, but on this workload it
             * was the dominant source of burst loss, recovery freezes, and the
             * reconnect cascade near the end of the long-run test. */
            static int wifiTCPMediaLogCount = 0;
            if (wifiTCPMediaLogCount < 10 || wifiTCPMediaLogCount % 200 == 0) {
                os_log(sLog, "WiFi media via TCP: seq=%u bytes=%zu",
                       originalHeader->seq, payloadLen);
            }
            wifiTCPMediaLogCount++;
            uint32_t seq = originalHeader->seq;
            uint64_t enqueueUs = keydrd_host_time_us();
            FTMacRecord ftRec = {
                .seq = originalHeader->seq, .flags = originalHeader->flags, .outcome = 'S',
                .bytes = (uint32_t)len, .inFlight = 0, .tsUs = originalHeader->ts_us,
                .encOutUs = enqueueUs, .submitUs = 0, .doneUs = 0,
            };
            uint32_t sendGeneration = self.wifiTCPSendGeneration;
            uint64_t schedulerWindowStartUs = self.wifiTCPSchedulerWindowStartUs;
            if (schedulerWindowStartUs == 0 ||
                enqueueUs <= schedulerWindowStartUs ||
                enqueueUs - schedulerWindowStartUs > kWirelessTCPSchedulerBurstWindowUs) {
                self.wifiTCPSchedulerWindowStartUs = enqueueUs;
                _wifiTCPSchedulerWindowSendCount = 0;
                schedulerWindowStartUs = enqueueUs;
            }
            int32_t burstWindowSendCount = OSAtomicIncrement32Barrier(&_wifiTCPSchedulerWindowSendCount);
            BOOL burstWindowTail = burstWindowSendCount >= kWirelessTCPSchedulerBurstWindowTailThreshold;
            if (burstWindowSendCount == kWirelessTCPSchedulerBurstWindowTailThreshold) {
                OSAtomicIncrement32Barrier(&_wifiPerfTCPSchedulerBurstWindows);
            }
            if (burstWindowTail) {
                OSAtomicIncrement32Barrier(&_wifiPerfTCPSchedulerBurstSends);
            }
            int32_t inFlightBefore = _wifiTCPMediaSendsInFlight;
            /* Under the ack gate the gate paces; the completion-driven sleeps below only add
             * latency (tla/WiFiSendLoop.tla header), so they are skipped. */
            BOOL ackGateActive = [self wifiAckUnackedFrames] >= 0;
            uint64_t schedulerSpacingUs = 0;
            const char *schedulerReason = "none";
            if (ackGateActive) {
                schedulerReason = "ack-gate";
            } else if (inFlightBefore >= 2 || payloadLen >= kWirelessBurstSevereFrameBytes) {
                schedulerSpacingUs = kWirelessTCPSchedulerSevereSpacingUs;
                schedulerReason = inFlightBefore >= 2 ? "inflight-severe" : "payload-severe";
            } else if (burstWindowTail) {
                schedulerSpacingUs = kWirelessTCPSchedulerTailSpacingUs;
                schedulerReason = "burst-window-tail";
            } else if (inFlightBefore >= 1 || payloadLen >= kWirelessBurstTailFrameBytes) {
                schedulerSpacingUs = kWirelessTCPSchedulerBaseSpacingUs;
                schedulerReason = inFlightBefore >= 1 ? "inflight-base" : "payload-tail";
            }
            uint64_t baseSchedulerSpacingUs = schedulerSpacingUs;
            int32_t recentPreDrops = _wifiPerfPreEncodeDrops;
            int32_t recentSlowCompletions = _wifiPerfTCPSlowCompletions;
            int32_t recentMaxCompletionMs = _wifiPerfTCPMaxCompletionMs;
            uint64_t recoverySpacingUs = 0;
            const char *recoveryReason = "none";
            if (recentPreDrops >= 3 || recentMaxCompletionMs >= 120) {
                recoverySpacingUs = kWirelessTCPSchedulerRecoverySevereSpacingUs;
                recoveryReason = "recovery-severe";
            } else if (recentPreDrops > 0 ||
                       recentSlowCompletions >= 2 ||
                       recentMaxCompletionMs >= 45) {
                recoverySpacingUs = kWirelessTCPSchedulerRecoveryModerateSpacingUs;
                recoveryReason = "recovery-moderate";
            }
            if (!ackGateActive && recoverySpacingUs > 0) {
                static int wifiTCPSchedulerRecoveryDecisionCount = 0;
                wifiTCPSchedulerRecoveryDecisionCount++;
                if (recoverySpacingUs > schedulerSpacingUs) {
                    schedulerSpacingUs = recoverySpacingUs;
                    schedulerReason = recoveryReason;
                    if (wifiTCPSchedulerRecoveryDecisionCount <= 30 ||
                        wifiTCPSchedulerRecoveryDecisionCount % 120 == 0) {
                        os_log(sLog, "WiFi TCP scheduler recovery decision: branch=apply seq=%u inFlightBefore=%d preDrop=%d slow=%d maxCompletion=%dms baseTarget=%lluus recoveryTarget=%lluus reason=%{public}s sampled=%{public}s count=%d",
                               seq, inFlightBefore, recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                               baseSchedulerSpacingUs, recoverySpacingUs, recoveryReason,
                               (recentPreDrops >= 8 || recentMaxCompletionMs >= 180) ? "forced" : "sampled",
                               wifiTCPSchedulerRecoveryDecisionCount);
                    }
                } else if (wifiTCPSchedulerRecoveryDecisionCount <= 30 ||
                           wifiTCPSchedulerRecoveryDecisionCount % 120 == 0) {
                    os_log(sLog, "WiFi TCP scheduler recovery decision: branch=hold seq=%u inFlightBefore=%d preDrop=%d slow=%d maxCompletion=%dms baseTarget=%lluus recoveryTarget=%lluus reason=%{public}s sampled=%{public}s count=%d",
                           seq, inFlightBefore, recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                           baseSchedulerSpacingUs, recoverySpacingUs, schedulerReason,
                           (recentPreDrops >= 8 || recentMaxCompletionMs >= 180) ? "forced" : "sampled",
                           wifiTCPSchedulerRecoveryDecisionCount);
                }
            }
            uint64_t completionGuardSpacingUs = 0;
            const char *completionGuardReason = "none";
            BOOL completionGuardEligible = !ackGateActive && (inFlightBefore >= 1) &&
                                           (recentSlowCompletions > 0 || recentPreDrops > 0 || recentMaxCompletionMs >= 35);
            uint64_t completionDerivedSpacingUs = 0;
            BOOL completionDerivedGuardApplied = NO;
            if (completionGuardEligible) {
                if (recentPreDrops >= 2 || recentMaxCompletionMs >= 60) {
                    completionGuardSpacingUs = kWirelessTCPSchedulerCompletionGuardSevereSpacingUs;
                    completionGuardReason = "completion-guard-severe";
                } else if (recentPreDrops > 0 || recentSlowCompletions >= 1 || recentMaxCompletionMs >= 35) {
                    completionGuardSpacingUs = kWirelessTCPSchedulerCompletionGuardModerateSpacingUs;
                    completionGuardReason = "completion-guard-moderate";
                }
                if (recentMaxCompletionMs > 0) {
                    completionDerivedSpacingUs =
                        ((uint64_t)recentMaxCompletionMs * 1000) / (uint64_t)kMaxMediaSendsInFlightWiFi +
                        kWirelessTCPSchedulerCompletionGuardSafetyUs;
                    static int wifiTCPSchedulerCompletionDerivedLogCount = 0;
                    wifiTCPSchedulerCompletionDerivedLogCount++;
                    if (completionDerivedSpacingUs > completionGuardSpacingUs) {
                        if (wifiTCPSchedulerCompletionDerivedLogCount <= 40 ||
                            wifiTCPSchedulerCompletionDerivedLogCount % 100 == 0) {
                            os_log(sLog, "WiFi TCP scheduler completion guard derived: branch=apply seq=%u inFlightBefore=%d payload=%zu preDrop=%d slow=%d maxCompletion=%dms guardTarget=%lluus derivedTarget=%lluus reason=completion-guard-derived sampled=%{public}s count=%d",
                                   seq, inFlightBefore, payloadLen, recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                                   completionGuardSpacingUs, completionDerivedSpacingUs,
                                   (recentMaxCompletionMs >= 70) ? "forced" : "sampled",
                                   wifiTCPSchedulerCompletionDerivedLogCount);
                        }
                        completionGuardSpacingUs = completionDerivedSpacingUs;
                        completionGuardReason = "completion-guard-derived";
                        completionDerivedGuardApplied = YES;
                    } else if (wifiTCPSchedulerCompletionDerivedLogCount <= 40 ||
                               wifiTCPSchedulerCompletionDerivedLogCount % 100 == 0) {
                        os_log(sLog, "WiFi TCP scheduler completion guard derived: branch=hold seq=%u inFlightBefore=%d payload=%zu preDrop=%d slow=%d maxCompletion=%dms guardTarget=%lluus derivedTarget=%lluus reason=%{public}s sampled=%{public}s count=%d",
                               seq, inFlightBefore, payloadLen, recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                               completionGuardSpacingUs, completionDerivedSpacingUs, completionGuardReason,
                               (recentMaxCompletionMs >= 70) ? "forced" : "sampled",
                               wifiTCPSchedulerCompletionDerivedLogCount);
                    }
                }
                if (completionGuardSpacingUs > 0) {
                    static int wifiTCPSchedulerCompletionGuardDecisionCount = 0;
                    wifiTCPSchedulerCompletionGuardDecisionCount++;
                    if (completionGuardSpacingUs > schedulerSpacingUs) {
                        schedulerSpacingUs = completionGuardSpacingUs;
                        schedulerReason = completionGuardReason;
                        if (wifiTCPSchedulerCompletionGuardDecisionCount <= 40 ||
                            wifiTCPSchedulerCompletionGuardDecisionCount % 100 == 0) {
                            os_log(sLog, "WiFi TCP scheduler completion guard: branch=apply seq=%u inFlightBefore=%d payload=%zu preDrop=%d slow=%d maxCompletion=%dms baseTarget=%lluus guardTarget=%lluus reason=%{public}s sampled=%{public}s count=%d",
                                   seq, inFlightBefore, payloadLen, recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                                   baseSchedulerSpacingUs, completionGuardSpacingUs, completionGuardReason,
                                   (recentPreDrops >= 3 || recentMaxCompletionMs >= 70) ? "forced" : "sampled",
                                   wifiTCPSchedulerCompletionGuardDecisionCount);
                        }
                    } else if (wifiTCPSchedulerCompletionGuardDecisionCount <= 40 ||
                               wifiTCPSchedulerCompletionGuardDecisionCount % 100 == 0) {
                        os_log(sLog, "WiFi TCP scheduler completion guard: branch=hold seq=%u inFlightBefore=%d payload=%zu preDrop=%d slow=%d maxCompletion=%dms baseTarget=%lluus guardTarget=%lluus reason=%{public}s sampled=%{public}s count=%d",
                               seq, inFlightBefore, payloadLen, recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                               schedulerSpacingUs, completionGuardSpacingUs, schedulerReason,
                               (recentPreDrops >= 3 || recentMaxCompletionMs >= 70) ? "forced" : "sampled",
                               wifiTCPSchedulerCompletionGuardDecisionCount);
                    }
                }
            }
            uint64_t schedulerDelayUs = 0;
            uint64_t schedulerObservedGapUs = 0;
            uint64_t lastSubmitUs = self.wifiTCPSchedulerLastSubmitUs;
            if (schedulerSpacingUs > 0 && lastSubmitUs > 0 && enqueueUs > lastSubmitUs) {
                schedulerObservedGapUs = enqueueUs - lastSubmitUs;
                if (schedulerObservedGapUs < schedulerSpacingUs) {
                    schedulerDelayUs = schedulerSpacingUs - schedulerObservedGapUs;
                    OSAtomicIncrement32Barrier(&_wifiPerfTCPSchedulerDelays);
                    OSAtomicAdd32Barrier((int32_t)MIN((uint64_t)INT32_MAX, schedulerDelayUs), &_wifiPerfTCPSchedulerDelayTotalUs);
                    if ((int32_t)schedulerDelayUs > _wifiPerfTCPSchedulerDelayMaxUs) {
                        _wifiPerfTCPSchedulerDelayMaxUs = (int32_t)MIN((uint64_t)INT32_MAX, schedulerDelayUs);
                    }
                    if (schedulerDelayUs >= 600 || burstWindowTail) {
                        static int wifiTCPSchedulerShapeLogCount = 0;
                        wifiTCPSchedulerShapeLogCount++;
                        if (wifiTCPSchedulerShapeLogCount <= 20 || wifiTCPSchedulerShapeLogCount % 100 == 0) {
                            os_log(sLog, "WiFi TCP scheduler shape: seq=%u payload=%zu inFlightBefore=%d burstWindowCount=%d tail=%{public}s gap=%lluus target=%lluus delay=%lluus reason=%{public}s sampled=%{public}s count=%d",
                                   seq, payloadLen, inFlightBefore, burstWindowSendCount,
                                   burstWindowTail ? "yes" : "no",
                                   schedulerObservedGapUs, schedulerSpacingUs, schedulerDelayUs, schedulerReason,
                                   schedulerDelayUs >= 1200 ? "forced" : "sampled",
                                   wifiTCPSchedulerShapeLogCount);
                        }
                    }
                    uint64_t appliedDelayUs = 0;
                    uint64_t schedulerSleepCapUs = kWirelessTCPSchedulerMaxSleepUs;
                    const char *schedulerSleepCapReason = "base-cap";
                    if (completionDerivedGuardApplied && recentMaxCompletionMs >= 70) {
                        if (recentMaxCompletionMs >= 110 || recentPreDrops >= 4) {
                            schedulerSleepCapUs = kWirelessTCPSchedulerDerivedSleepCapSevereUs;
                            schedulerSleepCapReason = "derived-severe";
                        } else {
                            schedulerSleepCapUs = kWirelessTCPSchedulerDerivedSleepCapModerateUs;
                            schedulerSleepCapReason = "derived-moderate";
                        }
                    }
                    static int wifiTCPSchedulerSleepCapDecisionCount = 0;
                    wifiTCPSchedulerSleepCapDecisionCount++;
                    if (completionDerivedGuardApplied &&
                        (wifiTCPSchedulerSleepCapDecisionCount <= 30 ||
                         wifiTCPSchedulerSleepCapDecisionCount % 100 == 0)) {
                        BOOL schedulerSleepCapRaised = (schedulerSleepCapUs > kWirelessTCPSchedulerMaxSleepUs);
                        os_log(sLog, "WiFi TCP scheduler sleep cap: branch=%{public}s seq=%u inFlightBefore=%d requested=%lluus baseCap=%lluus appliedCap=%lluus preDrop=%d slow=%d maxCompletion=%dms reason=%{public}s sampled=%{public}s count=%d",
                               schedulerSleepCapRaised ? "apply" : "hold",
                               seq, inFlightBefore, schedulerDelayUs,
                               kWirelessTCPSchedulerMaxSleepUs, schedulerSleepCapUs,
                               recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                               schedulerSleepCapReason,
                               (recentMaxCompletionMs >= 110 || recentPreDrops >= 4) ? "forced" : "sampled",
                               wifiTCPSchedulerSleepCapDecisionCount);
                    }
                    appliedDelayUs = MIN(schedulerSleepCapUs, schedulerDelayUs);
                    BOOL schedulerDelayClamped = (appliedDelayUs < schedulerDelayUs);
                    static int wifiTCPSchedulerSleepLogCount = 0;
                    wifiTCPSchedulerSleepLogCount++;
                    if (schedulerDelayClamped ||
                        wifiTCPSchedulerSleepLogCount <= 20 ||
                        wifiTCPSchedulerSleepLogCount % 120 == 0) {
                        os_log(sLog, "WiFi TCP scheduler sleep: branch=%{public}s seq=%u inFlightBefore=%d requested=%lluus applied=%lluus cap=%lluus preDrop=%d slow=%d maxCompletion=%dms reason=%{public}s sampled=%{public}s count=%d",
                               schedulerDelayClamped ? "clamped" : "unclamped",
                               seq, inFlightBefore,
                               schedulerDelayUs, appliedDelayUs, schedulerSleepCapUs,
                               recentPreDrops, recentSlowCompletions, recentMaxCompletionMs,
                               schedulerReason,
                               schedulerDelayClamped ? "forced" : "sampled",
                               wifiTCPSchedulerSleepLogCount);
                    }
                    usleep((useconds_t)appliedDelayUs);
                    enqueueUs = keydrd_host_time_us();
                }
            } else if (schedulerSpacingUs > 0 && lastSubmitUs > 0 && enqueueUs <= lastSubmitUs) {
                schedulerObservedGapUs = 0;
            }
            self.wifiTCPSchedulerLastSubmitUs = enqueueUs;
            /* FrameLoop gate after the scheduler sleeps, held through the submit. A delta held
             * here is never sent, so it never enters the ack gate count (the WiFiSendLoop
             * NoPostDrop exception: a frame the iPad would discard is not worth sending). */
            os_unfair_lock_lock(&_flLock);
            uint32_t flConn = _wirelessTransport.inputConnectionEpoch;
            BOOL flRequestKey = NO;
            if (![self flAdmitLocked:originalHeader route:FLRouteWiFi epoch:flConn requestKey:&flRequestKey]) {
                os_unfair_lock_unlock(&_flLock);
                if (flRequestKey) [self flRequestKeyframe:"hold"];
                return;
            }
            int32_t inFlight = OSAtomicIncrement32Barrier(&_wifiTCPMediaSendsInFlight);
            if (inFlight > _wifiPerfTCPInFlightPeak) {
                _wifiPerfTCPInFlightPeak = inFlight;
            }
            if (inFlight <= 5 || inFlight % 30 == 0) {
                os_log(sLog, "WiFi TCP send queued: seq=%u inFlight=%d bytes=%zu scheduler[delay=%lluus gap=%lluus target=%lluus reason=%{public}s burstCount=%d]",
                       seq, inFlight, len, schedulerDelayUs, schedulerObservedGapUs, schedulerSpacingUs,
                       schedulerReason, burstWindowSendCount);
            }
            /* No post-encode drop (tla/WiFiSendLoop.tla NoPostDrop): an encoded frame is always
             * sent, so the iPad never sees a seq gap, enters recovery, or asks for a keyframe.
             * The pre-encode gate bounds the queue. */
            [self wifiAckNoteSentSeq:(uint16_t)seq bytes:(uint32_t)len nowUs:keydrd_host_time_us()];
            __weak SessionManager *weakSelf = self;
            ftRec.inFlight = inFlight;
            ftRec.submitUs = keydrd_host_time_us();
            BOOL submitted = [_wirelessTransport sendMediaFrameViaTCP:data length:len onEpoch:flConn completion:^(BOOL success) {
                uint64_t doneUs = keydrd_host_time_us();
                FTMacRecord ftDone = ftRec;
                ftDone.doneUs = doneUs;
                ftDone.outcome = success ? 'S' : 'F';
                SessionManager *strongSelf = weakSelf;
                if (!strongSelf) return;
                uint32_t activeGeneration = strongSelf.wifiTCPSendGeneration;
                if (sendGeneration != activeGeneration) {
                    ftDone.outcome = 'X';
                }
                ft_mac_record(ftDone);
                if (sendGeneration != activeGeneration) {
                    static int wifiTCPStaleCompletionLogCount = 0;
                    wifiTCPStaleCompletionLogCount++;
                    if (!success || wifiTCPStaleCompletionLogCount <= 10 || wifiTCPStaleCompletionLogCount % 100 == 0) {
                        os_log(sLog, "WiFi TCP stale completion ignored: seq=%u success=%{public}s elapsed=%llums sendGen=%u activeGen=%u sampled=%{public}s sampleCount=%d",
                               seq, success ? "yes" : "no",
                               doneUs > enqueueUs ? (doneUs - enqueueUs) / 1000 : 0,
                               sendGeneration, activeGeneration,
                               success ? "sampled" : "forced",
                               wifiTCPStaleCompletionLogCount);
                    }
                    if (!success) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfTCPSendDrops);
                        [strongSelf flNoteLoss:"wifi-send-stale" seq:seq];
                    }
                    return;
                }
                int32_t left = OSAtomicDecrement32Barrier(&strongSelf->_wifiTCPMediaSendsInFlight);
                if (left < 0) {
                    os_log_error(sLog, "WiFi TCP in-flight underflow clamp: seq=%u success=%{public}s left=%d action=reset-to-zero",
                                 seq, success ? "yes" : "no", left);
                    strongSelf->_wifiTCPMediaSendsInFlight = 0;
                    left = 0;
                }
                strongSelf.wifiTCPLastCompletionUs = doneUs;
                if (left < kMaxMediaSendsInFlightWiFi) {
                    strongSelf.wifiTCPInFlightSaturatedSinceUs = 0;
                }
                uint64_t elapsedMs = doneUs > enqueueUs ? (doneUs - enqueueUs) / 1000 : 0;
                if ((int32_t)elapsedMs > strongSelf->_wifiPerfTCPMaxCompletionMs) {
                    strongSelf->_wifiPerfTCPMaxCompletionMs = (int32_t)MIN(elapsedMs, (uint64_t)INT32_MAX);
                }
                static int wifiTCPSlowCompletionLogCount = 0;
                static int wifiTCPCompletionLogCount = 0;
                if (elapsedMs >= kWirelessTCPSlowCompletionThresholdMs) {
                    OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfTCPSlowCompletions);
                    wifiTCPSlowCompletionLogCount++;
                    if (elapsedMs >= 45 || !success || wifiTCPSlowCompletionLogCount <= 10 || wifiTCPSlowCompletionLogCount % 25 == 0) {
                        os_log(sLog, "WiFi TCP send slow completion: seq=%u success=%{public}s elapsed=%llums inFlightNow=%d sampled=%{public}s sampleCount=%d",
                               seq, success ? "yes" : "no", elapsedMs, left,
                               (elapsedMs >= 45 || !success) ? "forced" : "sampled",
                               wifiTCPSlowCompletionLogCount);
                    }
                } else if (!success || left < 2) {
                    wifiTCPCompletionLogCount++;
                    if (!success || wifiTCPCompletionLogCount <= 10 || wifiTCPCompletionLogCount % 80 == 0) {
                        os_log(sLog, "WiFi TCP send completion: seq=%u success=%{public}s elapsed=%llums inFlightNow=%d sampled=%{public}s sampleCount=%d",
                               seq, success ? "yes" : "no", elapsedMs, left,
                               success ? "sampled" : "forced",
                               wifiTCPCompletionLogCount);
                    }
                }
                if (!success) {
                    OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfTCPSendDrops);
                    [strongSelf flNoteLoss:"wifi-send" seq:seq];
                }
            }];
            os_unfair_lock_unlock(&_flLock);
            if (flRequestKey) [self flRequestKeyframe:"pending"];
            if (!submitted) {
                /* tla/Lifecycle.tla CountOnSend: the current connection went away between the
                 * pre-encode check and here, so nothing was queued: take the frame back out of
                 * the gate count (as built it stayed counted and the gate shut for good). */
                [self wifiAckUnnoteSentSeq:(uint16_t)seq];
            }
            return;
        }

        /* WiFi: keep the whole stream on UDP when possible.
         * Mixing startup/keyframes across TCP and UDP created visible stalls.
         * Pre-encode pacing decides how much content we feed the encoder.
         * At send time, only guard against path mixing and UDP queue blow-ups. */
        WirelessTransport *transport = _wirelessTransport;
        size_t maxChunkPayload = KEYDRD_MTU_WIFI - sizeof(MediaFrameHeader);
        NSUInteger chunkCount = (payloadLen + maxChunkPayload - 1) / maxChunkPayload;
        NSUInteger queuedChunks = transport.queuedMediaChunkCount;
        if ((int32_t)queuedChunks > _wifiPerfPeakQueuedChunks) {
            _wifiPerfPeakQueuedChunks = (int32_t)queuedChunks;
        }

        if (chunkCount > kWirelessLargeFrameChunkThreshold) {
            OSAtomicIncrement32Barrier(&_wifiPerfQueueDrops);
            static int oversizedDropCount = 0;
            oversizedDropCount++;
            if (oversizedDropCount <= 10 || oversizedDropCount % 100 == 0) {
                os_log(sLog, "WiFi oversized-frame drop: seq=%u chunks=%lu bytes=%zu queued=%lu totalDropped=%d",
                       originalHeader->seq, (unsigned long)chunkCount, payloadLen,
                       (unsigned long)queuedChunks, oversizedDropCount);
            }
            [_hevcEncoder requestKeyframe];
            return;
        }

        if (queuedChunks + chunkCount > kWirelessMaxQueuedChunks) {
            OSAtomicIncrement32Barrier(&_wifiPerfQueueDrops);
            static int wifiQueueDropCount = 0;
            wifiQueueDropCount++;
            if (wifiQueueDropCount <= 10 || wifiQueueDropCount % 100 == 0) {
                os_log(sLog, "WiFi queue-overflow drop: seq=%u chunks=%lu queued=%lu totalDropped=%d",
                       originalHeader->seq, (unsigned long)chunkCount,
                       (unsigned long)queuedChunks, wifiQueueDropCount);
            }
            [_hevcEncoder requestKeyframe];
            return;
        }

        chunk_frame(payload, payloadLen, originalHeader->seq, KEYDRD_MTU_WIFI,
                    originalHeader, ^(const void *chunk, size_t chunkLen) {
            [transport sendMediaFrame:chunk length:chunkLen];
        });
    } else {
        [self flNoteLoss:"no-transport" seq:originalHeader->seq];
    }
}

- (void)sendMediaFrameHeaderToiPad:(const MediaFrameHeader *)header
                           payload:(const void *)payload
                     payloadLength:(size_t)payloadLen {
    if (!header || (!payload && payloadLen > 0)) {
        os_log_error(sLog, "USB send skipped: invalid header/payload args header=%{public}s payload=%{public}s payloadLen=%zu",
                     header ? "yes" : "no", payload ? "yes" : "no", payloadLen);
        return;
    }

    size_t totalLen = sizeof(MediaFrameHeader) + payloadLen;
    if (_usbTransport.isConnected) {
        os_unfair_lock_lock(&_flLock);
        uint32_t flConn = _usbTransport.inputConnectionEpoch;
        BOOL flRequestKey = NO;
        if (![self flAdmitLocked:header route:FLRouteUSB epoch:flConn requestKey:&flRequestKey]) {
            os_unfair_lock_unlock(&_flLock);
            if (flRequestKey) [self flRequestKeyframe:"hold"];
            return;
        }
        int32_t inFlight = OSAtomicIncrement32Barrier(&_tcpMediaSendsInFlight);
        if (inFlight <= 5 || inFlight % 10 == 0) {
            os_log(sLog, "USB split-send queued: seq=%u inFlight=%d bytes=%zu payload=%zu",
                   header->seq, inFlight, totalLen, payloadLen);
        }
        if (inFlight > kMaxMediaSendsInFlightUSB) {
            /* Never drop a compressed frame (DeltaSync NoCorruption); see the LZ4 gate. */
            static int splitOverLimitCount = 0;
            splitOverLimitCount++;
            if (splitOverLimitCount <= 10 || splitOverLimitCount % 500 == 0) {
                os_log_error(sLog, "USB split-send over in-flight limit (gate missed): seq=%u inFlight=%d total=%d — sending, not dropping",
                             header->seq, inFlight, splitOverLimitCount);
            }
        }

        __weak SessionManager *weakSelf = self;
        const uint32_t sentSeq = header->seq; /* copy: header memory is gone by completion */
        [_usbTransport sendMediaFrameWithHeader:header payload:payload payloadLength:payloadLen
                                        onEpoch:flConn completion:^(BOOL success) {
            SessionManager *strongSelf = weakSelf;
            if (strongSelf) {
                int32_t left = OSAtomicDecrement32Barrier(&strongSelf->_tcpMediaSendsInFlight);
                if (!success || left < 2) {
                    os_log(sLog, "USB split-send completion: seq=%u success=%{public}s inFlightNow=%d",
                           sentSeq, success ? "yes" : "no", left);
                }
                if (!success) [strongSelf flNoteLoss:"usb-send" seq:sentSeq];
            }
        }];
        os_unfair_lock_unlock(&_flLock);
        if (flRequestKey) [self flRequestKeyframe:"pending"];
        return;
    }

    size_t frameLen = sizeof(MediaFrameHeader) + payloadLen;
    uint8_t *packet = malloc(frameLen);
    if (!packet) {
        os_log_error(sLog, "Media send skipped: packet allocation failed seq=%u frameLen=%zu", header->seq, frameLen);
        return;
    }
    memcpy(packet, header, sizeof(MediaFrameHeader));
    if (payloadLen > 0) {
        memcpy(packet + sizeof(MediaFrameHeader), payload, payloadLen);
    }
    [self sendMediaFrameToiPad:packet length:frameLen];
    free(packet);
}

- (void)sendInputEventToiPad:(const void *)data length:(size_t)len {
    if (_usbTransport.isConnected) {
        [_usbTransport sendInputEvent:data length:len];
    } else if (_wirelessTransport.isConnected) {
        [_wirelessTransport sendInputEvent:data length:len];
    }
}

- (void)resetWirelessPerformanceWindow {
    _wifiPerfEncodedFrames = 0;
    _wifiPerfEncodedBytes = 0;
    _wifiPerfKeyframes = 0;
    _wifiPerfMaxFrameBytes = 0;
    _wifiPerfPreEncodeDrops = 0;
    _wifiPerfQueueDrops = 0;
    _wifiPerfTCPFallbacks = 0;
    _wifiPerfPeakQueuedChunks = 0;
    _wifiPerfTCPSendDrops = 0;
    _wifiPerfTCPInFlightPeak = 0;
    _wifiPerfTCPSlowCompletions = 0;
    _wifiPerfTCPMaxCompletionMs = 0;
    _wifiPerfTCPDropKeyframeRequests = 0;
    _wifiPerfTCPDropKeyframeSuppressed = 0;
    _wifiPerfTCPStallRecoveries = 0;
    _wifiPerfAdaptiveDownshifts = 0;
    _wifiPerfAdaptiveUpshifts = 0;
    _wifiPerfAdaptiveHolds = 0;
    _wifiPerfAdaptiveFloorGuards = 0;
    _wifiPerfPreEncodeStaleDrops = 0;
    _wifiPerfPreEncodeStaleMaxAgeMs = 0;
    _wifiPerfPreEncodeAgeSamples = 0;
    _wifiPerfPreEncodeAgeTotalMs = 0;
    _wifiPerfBurstTailFrames = 0;
    _wifiPerfBurstSevereFrames = 0;
    _wifiPerfTCPSchedulerDelays = 0;
    _wifiPerfTCPSchedulerDelayMaxUs = 0;
    _wifiPerfTCPSchedulerBurstWindows = 0;
    _wifiPerfTCPSchedulerBurstSends = 0;
    _wifiPerfTCPSchedulerDelayTotalUs = 0;
}

- (void)startWirelessPerformanceTimerIfNeeded {
    if (![NSThread isMainThread]) {
        __weak SessionManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf startWirelessPerformanceTimerIfNeeded];
        });
        return;
    }

    if (!_testMode || _wirelessPerformanceTimer != nil) {
        return;
    }

    [self resetWirelessPerformanceWindow];
    __weak SessionManager *weakSelf = self;
    _wirelessPerformanceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) {
            return;
        }
        if (!strongSelf->_wirelessTransport.isConnected || strongSelf->_usbTransport.isConnected) {
            return;
        }

        int32_t encodedFrames = strongSelf->_wifiPerfEncodedFrames;
        int32_t encodedBytes = strongSelf->_wifiPerfEncodedBytes;
        int32_t keyframes = strongSelf->_wifiPerfKeyframes;
        int32_t maxFrameBytes = strongSelf->_wifiPerfMaxFrameBytes;
        int32_t preDrops = strongSelf->_wifiPerfPreEncodeDrops;
        int32_t queueDrops = strongSelf->_wifiPerfQueueDrops;
        int32_t tcpFallbacks = strongSelf->_wifiPerfTCPFallbacks;
        int32_t tcpSendDrops = strongSelf->_wifiPerfTCPSendDrops;
        int32_t peakQueued = strongSelf->_wifiPerfPeakQueuedChunks;
        int32_t tcpInFlightPeak = strongSelf->_wifiPerfTCPInFlightPeak;
        int32_t tcpSlowCompletions = strongSelf->_wifiPerfTCPSlowCompletions;
        int32_t tcpMaxCompletionMs = strongSelf->_wifiPerfTCPMaxCompletionMs;
        int32_t tcpDropKeyReq = strongSelf->_wifiPerfTCPDropKeyframeRequests;
        int32_t tcpDropKeySupp = strongSelf->_wifiPerfTCPDropKeyframeSuppressed;
        int32_t tcpStallRecoveries = strongSelf->_wifiPerfTCPStallRecoveries;
        int32_t tcpInFlightNow = strongSelf->_wifiTCPMediaSendsInFlight;
        NSUInteger queuedNow = strongSelf->_wirelessTransport.queuedMediaChunkCount;
        double avgKB = encodedFrames > 0 ? ((double)encodedBytes / (double)encodedFrames) / 1024.0 : 0.0;
        const char *pacingMode = queuedNow >= 320 ? "congested" : (queuedNow <= 96 ? "fast" : "default");
        [strongSelf evaluateWiFiAdaptiveRateControl];
        int32_t adaptiveDown = strongSelf->_wifiPerfAdaptiveDownshifts;
        int32_t adaptiveUp = strongSelf->_wifiPerfAdaptiveUpshifts;
        int32_t adaptiveHold = strongSelf->_wifiPerfAdaptiveHolds;
        int32_t adaptiveFloor = strongSelf->_wifiPerfAdaptiveFloorGuards;
        int32_t stalePreDrops = strongSelf->_wifiPerfPreEncodeStaleDrops;
        int32_t staleMaxAgeMs = strongSelf->_wifiPerfPreEncodeStaleMaxAgeMs;
        int32_t ageSamples = strongSelf->_wifiPerfPreEncodeAgeSamples;
        int32_t ageTotalMs = strongSelf->_wifiPerfPreEncodeAgeTotalMs;
        int32_t burstTailFrames = strongSelf->_wifiPerfBurstTailFrames;
        int32_t burstSevereFrames = strongSelf->_wifiPerfBurstSevereFrames;
        int32_t schedulerDelays = strongSelf->_wifiPerfTCPSchedulerDelays;
        int32_t schedulerDelayMaxUs = strongSelf->_wifiPerfTCPSchedulerDelayMaxUs;
        int32_t schedulerBurstWindows = strongSelf->_wifiPerfTCPSchedulerBurstWindows;
        int32_t schedulerBurstSends = strongSelf->_wifiPerfTCPSchedulerBurstSends;
        int32_t schedulerDelayTotalUs = strongSelf->_wifiPerfTCPSchedulerDelayTotalUs;
        double schedulerDelayAvgUs = schedulerDelays > 0 ? (double)schedulerDelayTotalUs / (double)schedulerDelays : 0.0;
        double avgPreEncodeAgeMs = ageSamples > 0 ? (double)ageTotalMs / (double)ageSamples : 0.0;
        double burstDensityRatio = avgKB > 0.0 ? ((double)maxFrameBytes / 1024.0) / avgKB : 0.0;

        os_log(sLog, "WiFi perf 1s: encoded=%d keyframes=%d avg=%.1fKB max=%dKB burst[tail=%d severe=%d density=%.2fx] preDrop=%d stalePreDrop=%d preAgeAvg=%.1fms preAgeMax=%dms queueDrop=%d tcpFallback=%d tcpSendDrop=%d tcpInFlight=%d tcpInFlightPeak=%d tcpSlow=%d tcpMaxCompletion=%dms tcpDropKeyReq=%d tcpDropKeySupp=%d tcpStallRec=%d scheduler[delays=%d avg=%.0fus max=%dus burstWindows=%d burstSends=%d] adaptive[target=%dfps/%dMbps applied=%dfps/%dMbps down=%d up=%d hold=%d floor=%d healthyStreak=%d mildStreak=%d] queuedNow=%lu queuedPeak=%d pacing=%{public}s",
               encodedFrames, keyframes, avgKB, maxFrameBytes / 1024,
               burstTailFrames, burstSevereFrames, burstDensityRatio,
                preDrops, stalePreDrops, avgPreEncodeAgeMs, staleMaxAgeMs, queueDrops, tcpFallbacks, tcpSendDrops,
                tcpInFlightNow, tcpInFlightPeak, tcpSlowCompletions, tcpMaxCompletionMs,
               tcpDropKeyReq, tcpDropKeySupp, tcpStallRecoveries,
               schedulerDelays, schedulerDelayAvgUs, schedulerDelayMaxUs,
               schedulerBurstWindows, schedulerBurstSends,
               strongSelf->_wifiAdaptiveTargetFPS, strongSelf->_wifiAdaptiveTargetBitrate / 1000000,
               strongSelf->_wifiAdaptiveAppliedFPS, strongSelf->_wifiAdaptiveAppliedBitrate / 1000000,
               adaptiveDown, adaptiveUp, adaptiveHold, adaptiveFloor,
               strongSelf->_wifiAdaptiveHealthyStreak, strongSelf->_wifiAdaptiveMildCongestionStreak,
               (unsigned long)queuedNow, peakQueued, pacingMode);

        [strongSelf logAndResetWiFiAckWindow];
        [strongSelf resetWirelessPerformanceWindow];
    }];
}

- (void)logAndResetWiFiAckWindow {
    os_unfair_lock_lock(&_wifiAckLock);
    BOOL active = _wifiAckActive;
    int32_t unacked = (_wifiAckActive && _wifiAckHasSent)
        ? (int32_t)(uint16_t)(_wifiAckLastSentSeq - _wifiAckLastAckedSeq) : -1;
    int32_t acks = _wifiPerfAcks, stale = _wifiPerfAckStale, holds = _wifiPerfAckGateHolds;
    int32_t peak = _wifiPerfAckUnackedPeak, samples = _wifiPerfAckRttSamples;
    uint64_t total = _wifiPerfAckRttTotalUs, maxUs = _wifiPerfAckRttMaxUs;
    int32_t rateSamples = _wifiPerfAckRateSamples;
    uint64_t deliveryMaxBps = _wifiPerfAckDeliveryMaxBps;
    _wifiPerfAckRateSamples = 0; _wifiPerfAckDeliveryMaxBps = 0;
    _wifiPerfAcks = 0; _wifiPerfAckStale = 0; _wifiPerfAckGateHolds = 0;
    _wifiPerfAckUnackedPeak = 0; _wifiPerfAckRttSamples = 0;
    _wifiPerfAckRttTotalUs = 0; _wifiPerfAckRttMaxUs = 0;
    os_unfair_lock_unlock(&_wifiAckLock);
    os_log(sLog, "WiFi ack 1s: active=%d acks=%d stale=%d gateHolds=%d unackedNow=%d unackedPeak=%d rttAvg=%.1fms rttMax=%.1fms limit=%d delivery[samples=%d max=%.1fMbps]",
           active, acks, stale, holds, unacked, peak,
           samples > 0 ? (double)total / (double)samples / 1000.0 : 0.0,
           (double)maxUs / 1000.0, kWiFiAckGateFrames,
           rateSamples, (double)deliveryMaxBps / 1e6);
}

- (void)stopWirelessPerformanceTimer {
    if (![NSThread isMainThread]) {
        __weak SessionManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf stopWirelessPerformanceTimer];
        });
        return;
    }

    [_wirelessPerformanceTimer invalidate];
    _wirelessPerformanceTimer = nil;
    [self resetWirelessPerformanceWindow];
}

- (void)resetWiFiAdaptiveControlState {
    _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
    _wifiAdaptiveTargetBitrate = kWirelessHEVCBitrate;
    _wifiAdaptiveAppliedFPS = 0;
    _wifiAdaptiveAppliedBitrate = 0;
    _wifiAdaptiveLastChangeUs = 0;
    _wifiAdaptiveLastStaleDropUs = 0;
    _wifiAdaptiveHealthyStreak = 0;
    _wifiAdaptiveMildCongestionStreak = 0;
    _wifiAdaptiveSevereCongestionStreak = 0;
    os_log(sLog, "WiFi adaptive control reset: target=%dfps/%dMbps",
           _wifiAdaptiveTargetFPS, _wifiAdaptiveTargetBitrate / 1000000);
}

/* tla/WiFiRateControl.tla design: called once a second while the ack gate is active, before
 * the perf window resets. Gate holds do not count (IgnoreHolds): the bitrate steps toward the
 * fixed target T = kWirelessHEVCBitrate. FPS stays at max (KeepFps). */
/* The fixed rate target T for the current wireless link (AWDL or infrastructure). */
- (int32_t)wirelessTargetBitrate {
    return _wirelessTransport.isAWDL ? kAWDLHEVCBitrate : kWirelessHEVCBitrate;
}

- (void)evaluateWiFiAckRateControlNowUs:(uint64_t)nowUs {
    os_unfair_lock_lock(&_wifiAckLock);
    uint64_t deliveryMaxBps = _wifiPerfAckDeliveryMaxBps; /* diagnostic only */
    os_unfair_lock_unlock(&_wifiAckLock);

    int32_t prevBitrate = _wifiAdaptiveTargetBitrate;
    int32_t targetBitrate = prevBitrate;
    const int32_t T = [self wirelessTargetBitrate];
    const char *branch = "at-target";
    if (prevBitrate < T) {
        targetBitrate = MIN(T, prevBitrate + kWiFiAckRateStepUp);
        branch = "up";
    } else if (prevBitrate > T) {
        targetBitrate = MAX(T, prevBitrate - kWirelessAdaptiveMaxDownshiftBitrateDelta);
        branch = "down";
    }
    _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
    _wifiAdaptiveTargetBitrate = targetBitrate;
    _wifiAdaptiveHealthyStreak = 0;
    _wifiAdaptiveMildCongestionStreak = 0;
    _wifiAdaptiveSevereCongestionStreak = 0;
    os_log(sLog, "WiFi ack rate: branch=%{public}s target=%.1fMbps prev=%.1fMbps fps=%d applied=%dfps/%.1fMbps deliveryMax=%.1fMbps",
           branch, (double)targetBitrate / 1e6, (double)prevBitrate / 1e6,
           kWirelessAdaptiveMaxFPS, _wifiAdaptiveAppliedFPS, (double)_wifiAdaptiveAppliedBitrate / 1e6,
           (double)deliveryMaxBps / 1e6);
    [self applyWiFiAdaptiveRateTargetsIfNeededWithReason:@"ack-gate" nowUs:nowUs];
}

- (void)evaluateWiFiAdaptiveRateControl {
    if (_sessionState != SESSION_STREAMING || !_wirelessTransport.isConnected || _usbTransport.isConnected || !_hevcEncoder.isActive) {
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
        os_log(sLog, "WiFi adaptive hold: reason=inactive-path state=%{public}s wifi=%{public}d usb=%{public}d hevc=%{public}d",
               [self sessionStateName:_sessionState], _wirelessTransport.isConnected, _usbTransport.isConnected, _hevcEncoder.isActive);
        return;
    }

    uint64_t nowUs = keydrd_host_time_us();
    if ([self wifiAckUnackedFrames] >= 0) {
        [self evaluateWiFiAckRateControlNowUs:nowUs];
        return;
    }
    int32_t tcpInFlightNow = _wifiTCPMediaSendsInFlight;
    int32_t tcpSlowCompletions = _wifiPerfTCPSlowCompletions;
    int32_t tcpMaxCompletionMs = _wifiPerfTCPMaxCompletionMs;
    int32_t preDrops = _wifiPerfPreEncodeDrops;
    int32_t staleDrops = _wifiPerfPreEncodeStaleDrops;
    int32_t staleMaxAgeMs = _wifiPerfPreEncodeStaleMaxAgeMs;
    int32_t tcpSendDrops = _wifiPerfTCPSendDrops;
    int32_t queueDrops = _wifiPerfQueueDrops;
    int32_t encodedFrames = _wifiPerfEncodedFrames;
    int32_t encodedBytes = _wifiPerfEncodedBytes;
    int32_t maxFrameBytes = _wifiPerfMaxFrameBytes;
    int32_t burstTailFrames = _wifiPerfBurstTailFrames;
    int32_t burstSevereFrames = _wifiPerfBurstSevereFrames;
    double avgFrameBytes = encodedFrames > 0 ? (double)encodedBytes / (double)encodedFrames : 0.0;
    double burstDensityRatio = avgFrameBytes > 0.0 ? (double)maxFrameBytes / avgFrameBytes : 0.0;
    uint64_t lastStallRecoveryUs = _wifiTCPLastStallRecoveryUs;
    uint64_t sinceStallRecoveryMs = (lastStallRecoveryUs > 0 && nowUs > lastStallRecoveryUs)
    ? (nowUs - lastStallRecoveryUs) / 1000 : UINT64_MAX;
    uint64_t lastStaleDropUs = _wifiAdaptiveLastStaleDropUs;
    uint64_t sinceStaleDropMs = (lastStaleDropUs > 0 && nowUs > lastStaleDropUs)
    ? (nowUs - lastStaleDropUs) / 1000 : UINT64_MAX;
    int32_t prevFPS = _wifiAdaptiveTargetFPS;
    int32_t prevBitrate = _wifiAdaptiveTargetBitrate;
    int32_t targetFPS = prevFPS;
    int32_t targetBitrate = prevBitrate;
    NSString *reason = @"hold-stable";

    BOOL severeCongestion = (tcpSendDrops > 0) ||
                            (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi + 1) ||
                            (tcpMaxCompletionMs >= 52) ||
                            (preDrops >= 3) ||
                            (staleDrops >= 4) ||
                            (staleMaxAgeMs >= 200);
    BOOL burstTailRisk = (encodedFrames >= 24) &&
                         ((burstTailFrames >= kWirelessBurstTailFrameCountThreshold) ||
                          (burstDensityRatio >= kWirelessBurstTailDensityRatio && maxFrameBytes >= kWirelessBurstTailFrameBytes));
    BOOL burstSevereRisk = (encodedFrames >= 24) &&
                           ((burstSevereFrames >= kWirelessBurstSevereFrameCountThreshold) ||
                            (burstDensityRatio >= kWirelessBurstSevereDensityRatio && maxFrameBytes >= kWirelessBurstTailFrameBytes));
    if (burstSevereRisk) {
        BOOL burstEscalationTriggered =
        (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi) ||
        (tcpSlowCompletions >= 2) ||
        (tcpMaxCompletionMs >= 32) ||
        (tcpSendDrops > 0) ||
        (queueDrops > 0) ||
        (preDrops > 0) ||
        (staleDrops > 0);
        os_log(sLog, "WiFi adaptive burst escalation: branch=%{public}s severeRisk=%{public}s metrics[inFlight=%d slow=%d max=%dms sendDrop=%d queueDrop=%d preDrop=%d staleDrop=%d burstDensity=%.2fx maxFrameKB=%d] thresholds[inFlight>=%d slow>=%d max>=%dms]",
               burstEscalationTriggered ? "trigger" : "hold",
               burstSevereRisk ? "yes" : "no",
               tcpInFlightNow, tcpSlowCompletions, tcpMaxCompletionMs,
               tcpSendDrops, queueDrops, preDrops, staleDrops,
               burstDensityRatio, maxFrameBytes / 1024,
               kMaxMediaSendsInFlightWiFi, 2, 32);
        if (burstEscalationTriggered) {
            severeCongestion = YES;
        }
    }
    BOOL mildCongestion = !severeCongestion &&
                          ((tcpSlowCompletions >= 1) ||
                           (tcpMaxCompletionMs >= 24) ||
                              (preDrops > 0) ||
                              (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi));
    BOOL tailRiskCongestion = !severeCongestion &&
                              ((tcpSlowCompletions >= 2) ||
                               (tcpMaxCompletionMs >= 32) ||
                               (staleDrops > 0) ||
                               (staleMaxAgeMs >= 105) ||
                               burstTailRisk);
    BOOL healthy = !severeCongestion && !mildCongestion &&
                    tcpSendDrops == 0 && queueDrops == 0 && preDrops == 0 &&
                    staleDrops == 0 && staleMaxAgeMs < 55 &&
                    tcpSlowCompletions == 0 && tcpInFlightNow <= 1 && tcpMaxCompletionMs < 18;
    BOOL postStallHold = (sinceStallRecoveryMs != UINT64_MAX &&
                          sinceStallRecoveryMs < kWirelessTCPPostRecoveryAdaptiveHoldMs);
    BOOL postStaleHold = (sinceStaleDropMs != UINT64_MAX &&
                           sinceStaleDropMs < kWirelessAdaptivePostStaleUpshiftHoldMs);
    BOOL bitrateOvershootRisk = !severeCongestion &&
                                !tailRiskCongestion &&
                                !mildCongestion &&
                                (prevBitrate >= 4400000) &&
                                ((tcpSlowCompletions >= 1) ||
                                 (tcpMaxCompletionMs >= 22) ||
                                 (staleMaxAgeMs >= 70) ||
                                 burstTailRisk);

    static int wifiAdaptiveEvalCount = 0;
    wifiAdaptiveEvalCount++;
    if (wifiAdaptiveEvalCount <= 10 || wifiAdaptiveEvalCount % 30 == 0 ||
        severeCongestion || tailRiskCongestion || bitrateOvershootRisk || tcpSendDrops > 0) {
        os_log(sLog, "WiFi adaptive eval: severe=%{public}s mild=%{public}s tailRisk=%{public}s overshootRisk=%{public}s burstTail=%{public}s burstSevere=%{public}s healthy=%{public}s postStaleHold=%{public}s metrics[inFlight=%d slow=%d max=%dms preDrop=%d staleDrop=%d staleMaxAge=%dms sendDrop=%d queueDrop=%d burstTailFrames=%d burstSevereFrames=%d burstDensity=%.2fx maxFrameKB=%d avgFrameKB=%.1f prevTarget=%dfps/%dMbps] streaks[h=%d m=%d s=%d] sampled=%{public}s count=%d",
               severeCongestion ? "yes" : "no",
               mildCongestion ? "yes" : "no",
               tailRiskCongestion ? "yes" : "no",
               bitrateOvershootRisk ? "yes" : "no",
               burstTailRisk ? "yes" : "no",
               burstSevereRisk ? "yes" : "no",
               healthy ? "yes" : "no",
               postStaleHold ? "yes" : "no",
               tcpInFlightNow, tcpSlowCompletions, tcpMaxCompletionMs,
               preDrops, staleDrops, staleMaxAgeMs, tcpSendDrops, queueDrops,
               burstTailFrames, burstSevereFrames, burstDensityRatio,
               maxFrameBytes / 1024, avgFrameBytes / 1024.0,
               prevFPS, prevBitrate / 1000000,
               _wifiAdaptiveHealthyStreak, _wifiAdaptiveMildCongestionStreak, _wifiAdaptiveSevereCongestionStreak,
               (severeCongestion || tailRiskCongestion || bitrateOvershootRisk || tcpSendDrops > 0) ? "forced" : "sampled",
               wifiAdaptiveEvalCount);
    }

    if (severeCongestion) {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak += 1;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveDownshiftCooldownMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=severe-cooldown floor=%dfps target=%dfps/%dMbps sinceLast=%llums healthyStreak=%d mildStreak=%d severeStreak=%d",
                   kWirelessAdaptiveMinFPS, prevFPS, prevBitrate / 1000000, sinceMs,
                   _wifiAdaptiveHealthyStreak, _wifiAdaptiveMildCongestionStreak, _wifiAdaptiveSevereCongestionStreak);
            return;
        }
        if (_wifiAdaptiveSevereCongestionStreak >= kWirelessAdaptiveSevereEscalationStreak) {
            targetFPS = kWirelessAdaptiveMinFPS;
            reason = @"downshift-severe-hard";
        } else {
            targetFPS = MAX(kWirelessAdaptiveMidFPS, prevFPS - kWirelessAdaptiveFPSStepDownSevereSoft);
            reason = @"downshift-severe-soft";
        }
        int32_t severeStepDown = kWirelessAdaptiveBitrateStepDown + (burstSevereRisk ? 150000 : 0);
        targetBitrate = MAX(kWirelessAdaptiveMinBitrate, prevBitrate - severeStepDown);
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveDownshifts);
    } else if (tailRiskCongestion) {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak += 1;
        _wifiAdaptiveSevereCongestionStreak = 0;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveDownshiftCooldownMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=tail-risk-cooldown floor=%dfps target=%dfps/%dMbps sinceLast=%llums mildStreak=%d",
                   kWirelessAdaptiveMinFPS, prevFPS, prevBitrate / 1000000, sinceMs, _wifiAdaptiveMildCongestionStreak);
            return;
        }
        if (_wifiAdaptiveMildCongestionStreak < kWirelessAdaptiveMildCongestionStreak) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=tail-risk-hysteresis target=%dfps/%dMbps mildStreak=%d threshold=%d",
                   prevFPS, prevBitrate / 1000000, _wifiAdaptiveMildCongestionStreak, kWirelessAdaptiveMildCongestionStreak);
            return;
        }
        targetFPS = MIN(prevFPS, kWirelessAdaptiveMidFPS);
        int32_t tailStepDown = kWirelessAdaptiveBitrateStepDown + (burstTailRisk ? 125000 : 0);
        targetBitrate = MAX(kWirelessAdaptiveMinBitrate, prevBitrate - tailStepDown);
        reason = @"downshift-tail-guard";
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveDownshifts);
    } else if (mildCongestion) {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak += 1;
        _wifiAdaptiveSevereCongestionStreak = 0;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveDownshiftCooldownMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=mild-cooldown floor=%dfps target=%dfps/%dMbps sinceLast=%llums mildStreak=%d",
                   kWirelessAdaptiveMinFPS, prevFPS, prevBitrate / 1000000, sinceMs, _wifiAdaptiveMildCongestionStreak);
            return;
        }
        if (_wifiAdaptiveMildCongestionStreak < kWirelessAdaptiveMildCongestionStreak) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=mild-hysteresis target=%dfps/%dMbps mildStreak=%d threshold=%d",
                   prevFPS, prevBitrate / 1000000, _wifiAdaptiveMildCongestionStreak, kWirelessAdaptiveMildCongestionStreak);
            return;
        }
        targetFPS = prevFPS;
        targetBitrate = MAX(kWirelessAdaptiveMinBitrate, prevBitrate - kWirelessAdaptiveBitrateStepDown);
        reason = @"downshift-mild-bitrate";
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveDownshifts);
    } else if (healthy) {
        if (postStallHold) {
            _wifiAdaptiveHealthyStreak = 0;
            _wifiAdaptiveMildCongestionStreak = 0;
            _wifiAdaptiveSevereCongestionStreak = 0;
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=post-stall-recovery target=%dfps/%dMbps sinceRecovery=%llums holdMs=%llums",
                   prevFPS, prevBitrate / 1000000, sinceStallRecoveryMs, kWirelessTCPPostRecoveryAdaptiveHoldMs);
            return;
        }
        if (postStaleHold) {
            _wifiAdaptiveHealthyStreak = 0;
            _wifiAdaptiveMildCongestionStreak = 0;
            _wifiAdaptiveSevereCongestionStreak = 0;
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=post-stale-recovery target=%dfps/%dMbps staleDrops=%d staleMaxAge=%dms sinceStale=%llums holdMs=%llums",
                   prevFPS, prevBitrate / 1000000, staleDrops, staleMaxAgeMs,
                   sinceStaleDropMs, kWirelessAdaptivePostStaleUpshiftHoldMs);
            return;
        }
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak = 0;
        _wifiAdaptiveHealthyStreak += 1;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        BOOL fastRecoveryEligible = (prevFPS <= (kWirelessAdaptiveMidFPS + kWirelessAdaptiveFPSStepUp * 2)) &&
                                    (tcpInFlightNow == 0) &&
                                    (tcpSlowCompletions == 0) &&
                                    (tcpMaxCompletionMs <= 16) &&
                                    (preDrops == 0) &&
                                    (staleDrops == 0) &&
                                    (tcpSendDrops == 0) &&
                                    (queueDrops == 0) &&
                                    !burstTailRisk &&
                                    !burstSevereRisk;
        if (fastRecoveryEligible) {
            if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveFastRecoveryHoldMs) {
                OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
                os_log(sLog, "WiFi adaptive hold: reason=recovery-fast-cooldown target=%dfps/%dMbps sinceLast=%llums healthyStreak=%d threshold=%d metrics[inFlight=%d slow=%d max=%dms preDrop=%d burstTail=%{public}s]",
                       prevFPS, prevBitrate / 1000000, sinceMs,
                       _wifiAdaptiveHealthyStreak, kWirelessAdaptiveFastUpshiftHealthyStreak,
                       tcpInFlightNow, tcpSlowCompletions, tcpMaxCompletionMs, preDrops,
                       burstTailRisk ? "yes" : "no");
                return;
            }
            if (_wifiAdaptiveHealthyStreak < kWirelessAdaptiveFastUpshiftHealthyStreak) {
                OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
                os_log(sLog, "WiFi adaptive hold: reason=recovery-fast-hysteresis target=%dfps/%dMbps healthyStreak=%d threshold=%d metrics[inFlight=%d slow=%d max=%dms preDrop=%d burstTail=%{public}s]",
                       prevFPS, prevBitrate / 1000000,
                       _wifiAdaptiveHealthyStreak, kWirelessAdaptiveFastUpshiftHealthyStreak,
                       tcpInFlightNow, tcpSlowCompletions, tcpMaxCompletionMs, preDrops,
                       burstTailRisk ? "yes" : "no");
                return;
            }
            if (!bitrateOvershootRisk && prevFPS < kWirelessAdaptiveMaxFPS) {
                targetFPS = MIN(kWirelessAdaptiveMaxFPS, prevFPS + kWirelessAdaptiveFastMaxUpshiftFPSDelta);
            }
        } else {
            if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveRecoveryHoldMs) {
                OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
                os_log(sLog, "WiFi adaptive hold: reason=recovery-hold target=%dfps/%dMbps sinceLast=%llums healthyStreak=%d threshold=%d",
                       prevFPS, prevBitrate / 1000000, sinceMs, _wifiAdaptiveHealthyStreak, kWirelessAdaptiveUpshiftHealthyStreak);
                return;
            }
            if (_wifiAdaptiveHealthyStreak < kWirelessAdaptiveUpshiftHealthyStreak) {
                OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
                os_log(sLog, "WiFi adaptive hold: reason=healthy-hysteresis target=%dfps/%dMbps healthyStreak=%d threshold=%d",
                       prevFPS, prevBitrate / 1000000, _wifiAdaptiveHealthyStreak, kWirelessAdaptiveUpshiftHealthyStreak);
                return;
            }
            if (!bitrateOvershootRisk && prevFPS < kWirelessAdaptiveMaxFPS) {
                targetFPS = MIN(kWirelessAdaptiveMaxFPS, prevFPS + kWirelessAdaptiveFPSStepUp);
            }
        }
        if (bitrateOvershootRisk) {
            targetBitrate = MAX(kWirelessHEVCBitrate, prevBitrate - kWirelessAdaptiveBitrateStepDown);
            reason = @"hold-tail-guard-bitrate";
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
        } else if (prevBitrate < kWirelessAdaptiveMaxBitrate) {
            targetBitrate = MIN(kWirelessAdaptiveMaxBitrate, prevBitrate + kWirelessAdaptiveBitrateStepUp);
        }
        if (!bitrateOvershootRisk) {
            reason = fastRecoveryEligible ? @"recovery-upshift-fast" : @"recovery-upshift";
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveUpshifts);
        }
    } else {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak = 0;
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
        os_log(sLog, "WiFi adaptive hold: reason=transitional target=%dfps/%dMbps slow=%d maxMs=%d preDrop=%d staleDrop=%d staleMaxAge=%dms sendDrop=%d",
               prevFPS, prevBitrate / 1000000, tcpSlowCompletions, tcpMaxCompletionMs, preDrops, staleDrops, staleMaxAgeMs, tcpSendDrops);
        return;
    }

    targetFPS = MAX(kWirelessAdaptiveMinFPS, MIN(kWirelessAdaptiveMaxFPS, targetFPS));
    targetBitrate = MAX(kWirelessAdaptiveMinBitrate, MIN(kWirelessAdaptiveMaxBitrate, targetBitrate));

    _wifiAdaptiveTargetFPS = targetFPS;
    _wifiAdaptiveTargetBitrate = targetBitrate;
    [self applyWiFiAdaptiveRateTargetsIfNeededWithReason:reason nowUs:nowUs];
}

#pragma mark - Wi-Fi ack gate (tla/WiFiSendLoop.tla)

- (void)wifiAckResetWithReason:(const char *)reason {
    os_unfair_lock_lock(&_wifiAckLock);
    BOOL wasActive = _wifiAckActive;
    int32_t unacked = _wifiAckHasSent ? (int32_t)(uint16_t)(_wifiAckLastSentSeq - _wifiAckLastAckedSeq) : 0;
    _wifiAckActive = NO;
    _wifiAckHasSent = NO;
    _wifiAckLastAckedSeq = _wifiAckLastSentSeq;
    _wifiAckLastAckMacUs = 0;
    _wifiAckLastIpadUs = 0;
    os_unfair_lock_unlock(&_wifiAckLock);
    os_log(sLog, "WiFi ack gate reset: reason=%{public}s wasActive=%d unacked=%d",
           reason ?: "unknown", wasActive, unacked);
}

/* Frames sent and not yet acknowledged, or -1 before the first ack on this connection. */
- (int32_t)wifiAckUnackedFrames {
    os_unfair_lock_lock(&_wifiAckLock);
    int32_t n = (_wifiAckActive && _wifiAckHasSent)
        ? (int32_t)(uint16_t)(_wifiAckLastSentSeq - _wifiAckLastAckedSeq) : -1;
    os_unfair_lock_unlock(&_wifiAckLock);
    return n;
}

- (void)wifiAckNoteGateHold {
    os_unfair_lock_lock(&_wifiAckLock);
    _wifiPerfAckGateHolds++;
    os_unfair_lock_unlock(&_wifiAckLock);
}

- (void)wifiAckNoteSentSeq:(uint16_t)seq bytes:(uint32_t)bytes nowUs:(uint64_t)nowUs {
    os_unfair_lock_lock(&_wifiAckLock);
    BOOL discontinuity = _wifiAckHasSent && seq != (uint16_t)(_wifiAckLastSentSeq + 1);
    uint16_t prevSent = _wifiAckLastSentSeq;
    if (!_wifiAckHasSent || discontinuity) {
        /* First frame, or the encoder renumbered (restart): count from this frame. */
        _wifiAckLastAckedSeq = (uint16_t)(seq - 1);
    }
    _wifiAckLastSentSeq = seq;
    _wifiAckHasSent = YES;
    _wifiAckSendUs[seq & 0xFF] = nowUs;
    _wifiAckBytes[seq & 0xFF] = bytes;
    int32_t unacked = (int32_t)(uint16_t)(seq - _wifiAckLastAckedSeq);
    if (unacked > _wifiPerfAckUnackedPeak) _wifiPerfAckUnackedPeak = unacked;
    BOOL active = _wifiAckActive;
    os_unfair_lock_unlock(&_wifiAckLock);
    if (discontinuity) {
        os_log(sLog, "WiFi ack gate seq discontinuity: prevSent=%u seq=%u active=%d -> counting from seq",
               prevSent, seq, active);
    }
}

- (void)wifiAckUnnoteSentSeq:(uint16_t)seq {
    os_unfair_lock_lock(&_wifiAckLock);
    BOOL undone = _wifiAckHasSent && _wifiAckLastSentSeq == seq;
    if (undone) {
        _wifiAckLastSentSeq = (uint16_t)(seq - 1);
    }
    int32_t unacked = _wifiAckHasSent ? (int32_t)(uint16_t)(_wifiAckLastSentSeq - _wifiAckLastAckedSeq) : 0;
    os_unfair_lock_unlock(&_wifiAckLock);
    os_log(sLog, "LC MacEncodeUnsent seq=%u uncounted=%{public}d unacked=%d (no ready connection at send)",
           seq, undone, unacked);
}

- (void)handleWiFiFrameAck:(const uint8_t *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader) + 2) {
        os_log_error(sLog, "WiFi frame ack too short: length=%zu", length);
        return;
    }
    const uint8_t *p = data + sizeof(InputEventHeader);
    uint16_t ackSeq = (uint16_t)(p[0] | (p[1] << 8));
    uint64_t ipadUs = ((const InputEventHeader *)data)->ts_us; /* iPad host time at receipt */
    uint64_t nowUs = keydrd_host_time_us();
    BOOL accepted = NO, first = NO;
    uint64_t rttUs = 0;
    int32_t unackedAfter = -1;
    os_unfair_lock_lock(&_wifiAckLock);
    uint16_t lastSent = _wifiAckLastSentSeq;
    uint16_t lastAcked = _wifiAckLastAckedSeq;
    if (_wifiAckHasSent) {
        uint16_t dAck = (uint16_t)(ackSeq - lastAcked);
        uint16_t dSent = (uint16_t)(lastSent - lastAcked);
        if (dAck >= 1 && dAck <= dSent) {
            accepted = YES;
            first = !_wifiAckActive;
            _wifiAckActive = YES;
            _wifiAckLastAckedSeq = ackSeq;
            uint64_t sentUs = _wifiAckSendUs[ackSeq & 0xFF];
            if (sentUs > 0 && nowUs > sentUs) rttUs = nowUs - sentUs;
            unackedAfter = (int32_t)(uint16_t)(lastSent - ackSeq);
            /* Delivery-rate sample: the frames this ack covers arrived between the previous
             * ack's iPad time and this one's. Only when the first of them was sent before the
             * previous ack came back (the link was busy throughout); else the interval holds
             * idle time and the sample would only under-read. */
            uint64_t bytes = 0;
            for (uint16_t s = (uint16_t)(lastAcked + 1); ; s = (uint16_t)(s + 1)) {
                bytes += _wifiAckBytes[s & 0xFF];
                if (s == ackSeq) break;
            }
            uint64_t firstSentUs = _wifiAckSendUs[(uint16_t)(lastAcked + 1) & 0xFF];
            if (_wifiAckLastIpadUs > 0 && ipadUs > _wifiAckLastIpadUs &&
                firstSentUs > 0 && firstSentUs < _wifiAckLastAckMacUs &&
                bytes >= kWiFiAckSampleMinBytes) {
                uint64_t spanUs = ipadUs - _wifiAckLastIpadUs;
                if (spanUs >= 1000 && spanUs <= 1000000) {
                    uint64_t bps = bytes * 8ull * 1000000ull / spanUs;
                    _wifiPerfAckRateSamples++;
                    if (bps > _wifiPerfAckDeliveryMaxBps) _wifiPerfAckDeliveryMaxBps = bps;
                }
            }
            _wifiAckLastAckMacUs = nowUs;
            _wifiAckLastIpadUs = ipadUs;
        }
    }
    if (accepted) {
        _wifiPerfAcks++;
        if (rttUs > 0) {
            _wifiPerfAckRttSamples++;
            _wifiPerfAckRttTotalUs += rttUs;
            if (rttUs > _wifiPerfAckRttMaxUs) _wifiPerfAckRttMaxUs = rttUs;
        }
    } else {
        _wifiPerfAckStale++;
    }
    int32_t staleCount = _wifiPerfAckStale;
    os_unfair_lock_unlock(&_wifiAckLock);

    if (first) {
        os_log(sLog, "WiFi ack gate active: ack=%u lastSent=%u unacked=%d rtt=%lluus limit=%d",
               ackSeq, lastSent, unackedAfter, rttUs, kWiFiAckGateFrames);
    } else if (!accepted && (staleCount <= 5 || staleCount % 100 == 0)) {
        os_log(sLog, "WiFi frame ack ignored: ack=%u lastAcked=%u lastSent=%u (stale or outside window) count=%d",
               ackSeq, lastAcked, lastSent, staleCount);
    }
}

- (void)applyWiFiAdaptiveRateTargetsIfNeededWithReason:(NSString *)reason nowUs:(uint64_t)nowUs {
    int32_t requestedFPS = MAX(kWirelessAdaptiveMinFPS, MIN(kWirelessAdaptiveMaxFPS, _wifiAdaptiveTargetFPS));
    int32_t requestedBitrate = MAX(kWirelessAdaptiveMinBitrate, MIN(kWirelessAdaptiveMaxBitrate, _wifiAdaptiveTargetBitrate));
    int32_t targetFPS = requestedFPS;
    int32_t targetBitrate = requestedBitrate;
    int32_t maxUpshiftFPSDelta = kWirelessAdaptiveMaxUpshiftFPSDelta;
    int32_t maxUpshiftBitrateDelta = kWirelessAdaptiveMaxUpshiftBitrateDelta;
    if ([reason isEqualToString:@"recovery-upshift-fast"]) {
        maxUpshiftFPSDelta = kWirelessAdaptiveFastMaxUpshiftFPSDelta;
    } else if ([reason isEqualToString:@"ack-gate"]) {
        /* tla/WiFiRateControl.tla KeepFps: straight back to max; bitrate steps are chosen by
         * evaluateWiFiAckRateControlNowUs. */
        maxUpshiftFPSDelta = kWirelessAdaptiveMaxFPS;
        maxUpshiftBitrateDelta = kWiFiAckRateStepUp;
    }

    int32_t currentFPS = _wifiAdaptiveAppliedFPS > 0 ? _wifiAdaptiveAppliedFPS : kWirelessAdaptiveMaxFPS;
    int32_t currentBitrate = _wifiAdaptiveAppliedBitrate > 0 ? _wifiAdaptiveAppliedBitrate : kWirelessHEVCBitrate;
    int32_t fpsDelta = requestedFPS - currentFPS;
    int32_t bitrateDelta = requestedBitrate - currentBitrate;

    if (fpsDelta > maxUpshiftFPSDelta) {
        targetFPS = currentFPS + maxUpshiftFPSDelta;
    } else if (fpsDelta < -kWirelessAdaptiveMaxDownshiftFPSDelta) {
        targetFPS = currentFPS - kWirelessAdaptiveMaxDownshiftFPSDelta;
    }

    if (bitrateDelta > maxUpshiftBitrateDelta) {
        targetBitrate = currentBitrate + maxUpshiftBitrateDelta;
    } else if (bitrateDelta < -kWirelessAdaptiveMaxDownshiftBitrateDelta) {
        targetBitrate = currentBitrate - kWirelessAdaptiveMaxDownshiftBitrateDelta;
    }

    targetFPS = MAX(kWirelessAdaptiveMinFPS, MIN(kWirelessAdaptiveMaxFPS, targetFPS));
    targetBitrate = MAX(kWirelessAdaptiveMinBitrate, MIN(kWirelessAdaptiveMaxBitrate, targetBitrate));

    BOOL floorGuardEngaged = (requestedFPS <= kWirelessAdaptiveMinFPS || targetFPS <= kWirelessAdaptiveMinFPS);
    if (targetFPS < kWirelessAdaptiveMinFPS) {
        floorGuardEngaged = YES;
        targetFPS = kWirelessAdaptiveMinFPS;
    }
    if (floorGuardEngaged) {
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveFloorGuards);
    }

    BOOL fpsChanged = (_wifiAdaptiveAppliedFPS != targetFPS);
    BOOL bitrateChanged = (_wifiAdaptiveAppliedBitrate != targetBitrate);
    if (!fpsChanged && !bitrateChanged) {
        if (requestedFPS != targetFPS || requestedBitrate != targetBitrate) {
            os_log(sLog, "WiFi adaptive smooth hold: reason=%{public}s requested=%dfps/%dMbps applied=%dfps/%dMbps maxStepUp=%dfps/%dKbps maxStepDown=%dfps/%dKbps",
                   reason.UTF8String ?: "none",
                   requestedFPS, requestedBitrate / 1000000,
                   _wifiAdaptiveAppliedFPS, _wifiAdaptiveAppliedBitrate / 1000000,
                   maxUpshiftFPSDelta, kWirelessAdaptiveMaxUpshiftBitrateDelta / 1000,
                   kWirelessAdaptiveMaxDownshiftFPSDelta, kWirelessAdaptiveMaxDownshiftBitrateDelta / 1000);
        }
        return;
    }

    _capture.captureFPS = (uint32_t)targetFPS;
    if (fpsChanged && _captureWidth > 0 && _captureHeight > 0) {
        [_capture updateCaptureResolution:_captureWidth height:_captureHeight];
    }
    [_hevcEncoder updateStreamingRateWithFPS:targetFPS bitrate:targetBitrate reason:reason];

    _wifiAdaptiveAppliedFPS = targetFPS;
    _wifiAdaptiveAppliedBitrate = targetBitrate;
    _wifiAdaptiveLastChangeUs = nowUs;
    os_log(sLog, "WiFi adaptive apply: reason=%{public}s requested=%dfps/%dMbps applied=%dfps/%dMbps prev=%dfps/%dMbps floor=%dfps floorGuard=%{public}s smoothDelta=%+dfps/%+dKbps",
           reason.UTF8String ?: "none",
           requestedFPS, requestedBitrate / 1000000,
           targetFPS, targetBitrate / 1000000,
           currentFPS, currentBitrate / 1000000,
           kWirelessAdaptiveMinFPS, floorGuardEngaged ? "engaged" : "clear",
           targetFPS - currentFPS, (targetBitrate - currentBitrate) / 1000);
}

#pragma mark - Latency Probe

- (void)startLatencyProbeTimer {
    [_latencyProbeTimer invalidate];
    __weak SessionManager *weakSelf = self;
    _latencyProbeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) {
            [timer invalidate];
            return;
        }
        [strongSelf sendLatencyProbeResponse];
    }];
}

- (void)sendLatencyProbeResponse {
    /* Latency probes are echoed back -- iPad sends, Mac echoes.
     * This timer is just a keepalive. The actual echo happens in handleReceivedInputEvent. */
}

#pragma mark - Received Input Events from iPad

- (void)handleReceivedInputEvent:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader)) return;

    const InputEventHeader *header = (const InputEventHeader *)data;

    /* Any message proves an iPad link alive (InputPath SilenceDeadline). Pointer and key
     * messages go straight to the injector's own queue. */
    [_inputInjector noteActivity];
    if ([InputInjector isInputMessageType:header->type]) {
        [_inputInjector handleMessage:data length:length];
        return;
    }
    if (header->type == KEYDRD_INPUT_TEST_CONTROL) {
        if (!_testMode) {
            os_log_error(sLog, "Input test control ignored: not in test mode");
            return;
        }
        NSData *json = [NSData dataWithBytes:(const uint8_t *)data + sizeof(InputEventHeader)
                                      length:length - sizeof(InputEventHeader)];
        NSDictionary *cmdObj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if ([cmdObj isKindOfClass:[NSDictionary class]] && [cmdObj[@"cmd"] isEqual:@"bw-probe"]) {
            int ms = [cmdObj[@"ms"] intValue];
            [self startBandwidthProbeMs:(ms > 0 && ms <= 10000) ? ms : 3000];
            return;
        }
        if (!_inputTestHarness) _inputTestHarness = [[InputTestHarness alloc] initWithInjector:_inputInjector];
        __weak SessionManager *weakSelf = self;
        [_inputTestHarness handleControl:json reply:^(NSData *reply) {
            SessionManager *s = weakSelf;
            if (!s) return;
            NSMutableData *msg = [NSMutableData dataWithLength:sizeof(InputEventHeader)];
            InputEventHeader rh = { .type = KEYDRD_INPUT_TEST_REPORT, .ts_us = [s currentTimestampUs] };
            memcpy(msg.mutableBytes, &rh, sizeof rh);
            [msg appendData:reply];
            [s sendInputEventToiPad:msg.bytes length:msg.length];
        }];
        return;
    }

    switch (header->type) {
        case KEYDRD_INPUT_FRAME_ACK:
            [self handleWiFiFrameAck:data length:length];
            break;

        case KEYDRD_INPUT_RES_MATCH_REQUEST:
            [self handleResolutionMatchRequest:data length:length];
            break;

        case KEYDRD_INPUT_MODE_CHANGE:
            [self handleModeChangeFromiPad:data length:length];
            break;

        case KEYDRD_INPUT_VIEWPORT_REPORT:
            [self handleViewportReport:data length:length];
            break;

        case KEYDRD_INPUT_CLOCK_SYNC_REQ:
            [self handleClockSyncRequest:data length:length];
            break;

        case KEYDRD_INPUT_LATENCY_PROBE:
            /* Echo latency probe back to iPad immediately */
            [self sendInputEventToiPad:data length:length];
            break;

        case KEYDRD_INPUT_KEEPALIVE:
            /* Just a keepalive, no action needed */
            break;

        default:
            os_log_debug(sLog, "Unhandled input event type: 0x%02x", header->type);
            break;
    }
}

#pragma mark - Peer Address Update (Mac → iPad)

- (void)sendPeerAddressUpdate {
    /* Get Mac's USB NCM IP from the USB transport */
    NSString *usbIP = _usbTransport.localIPAddress;
    if (!usbIP || usbIP.length == 0) {
        os_log(sLog, "sendPeerAddressUpdate: no USB NCM IP available");
        return;
    }

    os_log(sLog, "Sending peer address update to iPad: %{public}@ (before WiFi→USB switch)", usbIP);

    const char *ipCStr = [usbIP UTF8String];
    size_t ipLen = strlen(ipCStr) + 1; /* include null terminator */
    size_t totalLen = sizeof(InputEventHeader) + ipLen;

    uint8_t *packet = malloc(totalLen);
    if (!packet) return;

    InputEventHeader header;
    header.type = KEYDRD_INPUT_PEER_ADDRESS_UPDATE;
    header.ts_us = [self currentTimestampUs];

    memcpy(packet, &header, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), ipCStr, ipLen);

    /* Send over whatever transport is alive (WiFi at this point) */
    [self sendInputEventToiPad:packet length:totalLen];
    free(packet);
}

#pragma mark - Viewport Report (iPad → Mac)

- (void)_autoMatchDisplayModeForViewport {
    if (_viewportWidth == 0 || _viewportHeight == 0) return;

    CGDirectDisplayID mainDisplay = CGMainDisplayID();

    /* Store current display mode for revert on disconnect (if not already stored) */
    if (!_resolutionChanged) {
        CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplay);
        if (currentMode) {
            if (_storedDisplayMode) {
                CGDisplayModeRelease(_storedDisplayMode);
            }
            _storedDisplayMode = currentMode;
            /* Don't release — we keep it for revert */
        }
    }

    /* Get all available display modes */
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(mainDisplay, NULL);
    if (!allModes) {
        os_log_error(sLog, "_autoMatchDisplayModeForViewport: failed to get display modes");
        return;
    }

    /* Find the BEST display mode for remote desktop:
     *
     * PRIORITY: HiDPI (Retina) modes >> 1x modes.
     * A 2x mode at 2880x1864 with slight SCStream downscale (0.96x) gives FAR better
     * text quality than a 1x mode at 2704x1756 where macOS renders text without HiDPI.
     *
     * Algorithm:
     * 1. First pass: find closest HiDPI mode (pixel width > logical width) where
     *    pixel width >= 85% of viewport width.
     * 2. If no HiDPI mode qualifies, fall back to closest 1x mode.
     * 3. Among qualifying modes, pick the one whose pixel count is closest to viewport
     *    (prefer modes >= viewport to avoid upscale, but accept smaller within 15% DPI). */
    uint32_t vpW = _viewportWidth;
    uint32_t vpH = _viewportHeight;
    size_t vpPixelCount = (size_t)vpW * (size_t)vpH;
    float minWidth = 0.85f * (float)vpW;

    CGDisplayModeRef bestHiDPI = NULL;
    size_t bestHiDPIDiff = SIZE_MAX;
    size_t bestHiDPIPixelW = 0, bestHiDPIPixelH = 0;

    CGDisplayModeRef best1x = NULL;
    size_t best1xDiff = SIZE_MAX;
    size_t best1xPixelW = 0, best1xPixelH = 0;

    /* Also check the current mode — maybe it's already optimal */
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplay);
    size_t currentPixelW = 0, currentPixelH = 0;
    float currentScale = 1.0f;
    if (currentMode) {
        currentPixelW = CGDisplayModeGetPixelWidth(currentMode);
        currentPixelH = CGDisplayModeGetPixelHeight(currentMode);
        size_t currentLogW = CGDisplayModeGetWidth(currentMode);
        currentScale = (currentLogW > 0) ? (float)currentPixelW / (float)currentLogW : 1.0f;
        CGDisplayModeRelease(currentMode);
    }

    CFIndex modeCount = CFArrayGetCount(allModes);
    os_log(sLog, "_autoMatchDisplayModeForViewport: scanning %ld modes for viewport %ux%u (minWidth=%.0f, currentScale=%.1f)",
           (long)modeCount, vpW, vpH, minWidth, currentScale);

    for (CFIndex i = 0; i < modeCount; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t modeW = CGDisplayModeGetPixelWidth(mode);
        size_t modeH = CGDisplayModeGetPixelHeight(mode);
        size_t modeLogW = CGDisplayModeGetWidth(mode);

        if (modeW == 0 || modeH == 0) continue;

        /* DPI constraint: pixel width must be >= 85% of viewport width */
        if ((float)modeW < minWidth) continue;

        /* Determine if this is a HiDPI (Retina) mode */
        BOOL isHiDPI = (modeLogW > 0 && modeW > modeLogW);

        /* Compute difference from viewport pixel count */
        size_t modePixelCount = modeW * modeH;
        size_t diff = (modePixelCount > vpPixelCount)
            ? (modePixelCount - vpPixelCount)
            : (vpPixelCount - modePixelCount);

        if (isHiDPI) {
            if (diff < bestHiDPIDiff) {
                bestHiDPI = mode;
                bestHiDPIDiff = diff;
                bestHiDPIPixelW = modeW;
                bestHiDPIPixelH = modeH;
            }
        } else {
            if (diff < best1xDiff) {
                best1x = mode;
                best1xDiff = diff;
                best1xPixelW = modeW;
                best1xPixelH = modeH;
            }
        }
    }

    /* Prefer HiDPI mode; fall back to 1x only if no HiDPI available */
    CGDisplayModeRef bestMode;
    size_t bestPixelWidth, bestPixelHeight;
    if (bestHiDPI) {
        bestMode = bestHiDPI;
        bestPixelWidth = bestHiDPIPixelW;
        bestPixelHeight = bestHiDPIPixelH;
        os_log(sLog, "_autoMatchDisplayModeForViewport: selected HiDPI mode %zux%zu (diff=%zu from viewport)",
               bestPixelWidth, bestPixelHeight, bestHiDPIDiff);
    } else if (best1x) {
        bestMode = best1x;
        bestPixelWidth = best1xPixelW;
        bestPixelHeight = best1xPixelH;
        os_log(sLog, "_autoMatchDisplayModeForViewport: no HiDPI mode, using 1x mode %zux%zu",
               bestPixelWidth, bestPixelHeight);
    } else {
        bestMode = NULL;
        bestPixelWidth = 0;
        bestPixelHeight = 0;
    }

    if (!bestMode) {
        os_log(sLog, "_autoMatchDisplayModeForViewport: no suitable mode found");
        CFRelease(allModes);
        return;
    }

    /* Check if the best mode differs from the current display mode */
    if (bestPixelWidth == currentPixelW && bestPixelHeight == currentPixelH) {
        os_log(sLog, "_autoMatchDisplayModeForViewport: current mode %zux%zu already optimal",
               currentPixelW, currentPixelH);
        CFRelease(allModes);
        return;
    }

    /* Read logical width BEFORE releasing allModes (bestMode belongs to allModes) */
    size_t bestLogicalWidth = CGDisplayModeGetWidth(bestMode);

    /* Switch display mode */
    os_log(sLog, "_autoMatchDisplayModeForViewport: switching %zux%zu -> %zux%zu (viewport: %ux%u)",
           currentPixelW, currentPixelH, bestPixelWidth, bestPixelHeight, vpW, vpH);

    CGError err = CGDisplaySetDisplayMode(mainDisplay, bestMode, NULL);
    CFRelease(allModes);

    if (err != kCGErrorSuccess) {
        os_log_error(sLog, "_autoMatchDisplayModeForViewport: CGDisplaySetDisplayMode failed: %d", err);
        return;
    }

    _resolutionChanged = YES;

    /* Update capture dimensions to the new native pixel dimensions.
     * SCStream will capture at 1:1 (no downscale blur). */
    _captureWidth = (uint32_t)bestPixelWidth;
    _captureHeight = (uint32_t)bestPixelHeight;
    _captureScale = (bestLogicalWidth > 0) ? (float)bestPixelWidth / (float)bestLogicalWidth : 2.0f;

    os_log(sLog, "_autoMatchDisplayModeForViewport: display mode changed to %ux%u @%.1fx",
           _captureWidth, _captureHeight, _captureScale);
}

- (void)handleViewportReport:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader) + sizeof(ViewportReportPayload)) {
        os_log_error(sLog, "Viewport report too short: %zu bytes", length);
        return;
    }

    const ViewportReportPayload *payload =
        (const ViewportReportPayload *)((const uint8_t *)data + sizeof(InputEventHeader));

    uint32_t oldViewportWidth = _viewportWidth;
    uint32_t oldViewportHeight = _viewportHeight;
    _viewportWidth = payload->viewport_width;
    _viewportHeight = payload->viewport_height;
    _viewportReceived = YES;

    BOOL viewportChanged = (_viewportWidth != oldViewportWidth) || (_viewportHeight != oldViewportHeight);
    os_log(sLog, "iPad viewport report: %ux%u (previous: %ux%u, changed=%{public}d, Mac display: %ux%u, hevcActive=%{public}d, usbConnected=%{public}d)",
           _viewportWidth, _viewportHeight,
           oldViewportWidth, oldViewportHeight, viewportChanged,
           _captureWidth, _captureHeight, _hevcEncoder.isActive, _usbTransport.isConnected);

    if (!_usbTransport.isConnected && _hevcEncoder.isActive) {
        uint32_t expectedEncodeWidth = _viewportWidth;
        uint32_t expectedEncodeHeight = _viewportHeight;
        keydrd_limit_size(_viewportWidth, _viewportHeight,
                          _wirelessTransport.isAWDL ? kAWDLMaxEncodeWidth : kWirelessMaxEncodeWidth,
                          _wirelessTransport.isAWDL ? kAWDLMaxEncodeHeight : kWirelessMaxEncodeHeight,
                          &expectedEncodeWidth, &expectedEncodeHeight);
        if (!viewportChanged &&
            _captureWidth == expectedEncodeWidth &&
            _captureHeight == expectedEncodeHeight) {
            os_log(sLog, "Skipping redundant HEVC restart on unchanged viewport during active wireless session (expected=%ux%u capture=%ux%u)",
                   expectedEncodeWidth, expectedEncodeHeight, _captureWidth, _captureHeight);
            return;
        }
    }

    /* In LZ4 mode (wired USB), no HEVC encoder needed.
     * Resize capture to viewport dims, send geometry update to iPad so LZ4
     * decompressor uses the correct size, THEN start capture.
     * Order matters: geometry update must arrive before frames at new size. */
    if (!_hevcEncoder.isActive && _usbTransport.isConnected) {
        os_log(sLog, "LZ4 mode (USB) — setting capture to viewport %ux%u, then starting capture",
               _viewportWidth, _viewportHeight);
        _captureWidth = _viewportWidth;
        _captureHeight = _viewportHeight;

        /* Tell iPad the frame size BEFORE any frames arrive */
        [self sendGeometryUpdate];

        if (_capture.isCapturing) {
            /* Capture already runs (e.g. it started at display size during a wireless session
             * that never got a viewport, then USB connected). Setting the size properties does
             * not touch a running SCStream, so frames stayed at display size and every iPad
             * decode failed (size mismatch, seen 2026-11-16 after an agent restart).
             * updateCaptureResolution reconfigures the stream and the compressor. */
            os_log(sLog, "LZ4 viewport: capture running at %ux%u -> reconfiguring to %ux%u",
                   _capture.captureWidth, _capture.captureHeight, _viewportWidth, _viewportHeight);
            [_capture updateCaptureResolution:_viewportWidth height:_viewportHeight];
            [_capture requestLZ4Keyframe];
        } else {
            /* Set capture resolution (applied at stream start) */
            _capture.captureWidth = _viewportWidth;
            _capture.captureHeight = _viewportHeight;

            /* NOW start capture — iPad decompressor is already at correct size */
            [self _beginCapture];
        }

        if (self.onResolutionChanged) {
            self.onResolutionChanged(_captureWidth, _captureHeight);
        }
        return;
    }

    /* HEVC mode (WiFi): start encoder + reconfigure capture at viewport resolution */
    [self _startEncoderAtViewportResolution];
}

- (void)_startEncoderAtViewportResolution {
    if (_viewportWidth == 0 || _viewportHeight == 0) {
        os_log_error(sLog, "_startEncoderAtViewportResolution: viewport not set");
        return;
    }

    /* Always use viewport dimensions for encoding — no display mode matching.
     * SCStream downscales from Mac native (e.g. 3600x2338) to viewport (2752x1786). */
    uint32_t encodeWidth = _viewportWidth;
    uint32_t encodeHeight = _viewportHeight;

    /* USB: AverageBitRate=40Mbps — realistic target the encoder can track.
     * At 150Mbps the encoder undershoots to 6Mbps (too much headroom).
     * At 40Mbps it produces 15-30Mbps actual = good text quality + fast encode.
     * Quality-based (0.85-0.95) was tried but makes encoder work much harder
     * per frame (~40ms vs ~20ms), causing stutter on complex content.
     * WiFi: use a lower, steadier operating point. 120 Hz / 20 Mbps produced
     * 300-800 KB frames and overwhelmed the paced DTLS path. */
    int bitrate;
    float quality;
    int fps;
    if (_usbTransport.isConnected) {
        bitrate = 100000000; /* 100 Mbps — USB 3.2 Gen 2 has headroom, maximize quality */
        quality = 0.0f;     /* bitrate-based, faster than quality-based */
        fps = 120;
        _capture.captureFPS = 120;
        self.wirelessLastEncodeSubmitUs = 0;
        [self resetWiFiAdaptiveControlState];
    } else {
        bitrate = [self wirelessTargetBitrate];
        os_log(sLog, "Wireless HEVC start: link=%{public}s bitrate=%.1fMbps fps=%d ackGate=%d",
               _wirelessTransport.isAWDL ? "awdl" : "infra", bitrate / 1e6,
               kWirelessHEVCFPS, kWiFiAckGateFrames);
        quality = 0.0f;     /* bitrate-based */
        fps = kWirelessHEVCFPS;
        _capture.captureFPS = fps;
        self.wirelessLastEncodeSubmitUs = 0;
        _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
        _wifiAdaptiveTargetBitrate = bitrate;
        _wifiAdaptiveAppliedFPS = fps;
        _wifiAdaptiveAppliedBitrate = bitrate;
        _wifiAdaptiveLastChangeUs = keydrd_host_time_us();
        keydrd_limit_size(_viewportWidth, _viewportHeight,
                          _wirelessTransport.isAWDL ? kAWDLMaxEncodeWidth : kWirelessMaxEncodeWidth,
                          _wirelessTransport.isAWDL ? kAWDLMaxEncodeHeight : kWirelessMaxEncodeHeight,
                          &encodeWidth, &encodeHeight);
        if (encodeWidth != _viewportWidth || encodeHeight != _viewportHeight) {
            os_log(sLog, "WiFi encode cap: viewport %ux%u -> %ux%u (link cap)",
                   _viewportWidth, _viewportHeight, encodeWidth, encodeHeight);
        }
    }

    os_log(sLog, "Starting HEVC encoder: %ux%u @%dfps bitrate=%dMbps (capture: %ux%u, viewport: %ux%u)",
           encodeWidth, encodeHeight, fps, bitrate / 1000000,
           _captureWidth, _captureHeight, _viewportWidth, _viewportHeight);

    [_hevcEncoder startWithWidth:(int)encodeWidth
                          height:(int)encodeHeight
                             fps:fps
                         bitrate:bitrate
                         quality:quality];

    /* Live-reconfigure capture resolution.
     * Uses SCStream.updateConfiguration — no stop/start, no Sequoia re-auth prompt. */
    [_capture updateCaptureResolution:encodeWidth height:encodeHeight];

    /* Update captureWidth/Height so handshake/geometry messages reflect actual encode size */
    _captureWidth = encodeWidth;
    _captureHeight = encodeHeight;

    /* Reconfigure frame delivery */
    [self configureFrameDelivery];

    /* Send geometry update so iPad knows the new frame dimensions */
    [self sendGeometryUpdate];

    /* Notify Mac UI (menu bar) of the new resolution */
    if (self.onResolutionChanged) {
        self.onResolutionChanged(_captureWidth, _captureHeight);
    }
}

#pragma mark - Clock Sync (Cristian's Algorithm)

- (void)handleClockSyncRequest:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader)) return;

    /* t2: Mac receive host time (as close to reception as possible) */
    uint64_t t2Us = keydrd_host_time_us();

    /* Extract t1 from request (iPad send time, stored in ts_us) */
    const InputEventHeader *reqHeader = (const InputEventHeader *)data;
    uint64_t t1Us = reqHeader->ts_us;

    /* Build response: InputEventHeader + ClockSyncResponse */
    size_t totalLen = sizeof(InputEventHeader) + sizeof(ClockSyncResponse);
    uint8_t packet[sizeof(InputEventHeader) + sizeof(ClockSyncResponse)];

    /* t3: Mac send host time (just before send) */
    uint64_t t3Us = keydrd_host_time_us();

    InputEventHeader respHeader;
    respHeader.type = KEYDRD_INPUT_CLOCK_SYNC_RESP;
    respHeader.ts_us = t3Us;

    ClockSyncResponse resp;
    resp.t1_ipad_us = t1Us;
    resp.t2_mac_us = t2Us;
    resp.t3_mac_us = t3Us;

    memcpy(packet, &respHeader, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), &resp, sizeof(ClockSyncResponse));

    [self sendInputEventToiPad:packet length:totalLen];
}

#pragma mark - Mode Change from iPad

#pragma mark - Bandwidth probe (test mode)

/* Measures Mac->iPad capacity on the live Wi-Fi TCP/TLS connection. Sends 64 KB filler
 * messages (KEYDRD_INPUT_TEST_FILLER) back to back, kBWProbeMaxInFlight at a time, for `ms`,
 * then a TEST_REPORT once every filler send has completed. The iPad times each arrival
 * (DeviceTestRunner runBandwidthProbe); the report follows the filler on the same stream, so
 * its arrival marks the end. The media stream keeps running, so the iPad sees filler plus
 * stream. Runs on the Wi-Fi transport queue: TEST_CONTROL is handled there, and send
 * completions are delivered there (WirelessTransport sets it as the connection queue). */
static const int kBWProbeMaxInFlight = 8;
static const size_t kBWProbeChunkBytes = 64 * 1024;

- (void)sendBandwidthProbeReply:(NSDictionary *)obj {
    NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data];
    NSMutableData *msg = [NSMutableData dataWithLength:sizeof(InputEventHeader)];
    InputEventHeader rh = { .type = KEYDRD_INPUT_TEST_REPORT, .ts_us = [self currentTimestampUs] };
    memcpy(msg.mutableBytes, &rh, sizeof rh);
    [msg appendData:body];
    [self sendInputEventToiPad:msg.bytes length:msg.length];
}

- (void)startBandwidthProbeMs:(int)ms {
    if (!_wirelessTransport.isConnected || _usbTransport.isConnected || self.bwProbeActive) {
        os_log(sLog, "bw-probe: refused wifi=%d usb=%d active=%d",
               _wirelessTransport.isConnected, _usbTransport.isConnected, self.bwProbeActive);
        [self sendBandwidthProbeReply:@{ @"bwProbe": @"refused" }];
        return;
    }
    NSMutableData *chunk = [NSMutableData dataWithLength:kBWProbeChunkBytes];
    InputEventHeader h = { .type = KEYDRD_INPUT_TEST_FILLER, .ts_us = 0 };
    memcpy(chunk.mutableBytes, &h, sizeof h);
    self.bwProbeChunk = chunk;
    self.bwProbeStartUs = keydrd_host_time_us();
    self.bwProbeEndUs = self.bwProbeStartUs + (uint64_t)ms * 1000;
    self.bwProbeSentBytes = 0;
    self.bwProbeInFlight = 0;
    self.bwProbeActive = YES;
    os_log(sLog, "bw-probe: start ms=%d chunk=%zu maxInFlight=%d", ms, kBWProbeChunkBytes, kBWProbeMaxInFlight);
    [self pumpBandwidthProbe];
}

- (void)pumpBandwidthProbe {
    if (!self.bwProbeActive) return;
    uint64_t nowUs = keydrd_host_time_us();
    while (self.bwProbeInFlight < kBWProbeMaxInFlight && nowUs < self.bwProbeEndUs &&
           _wirelessTransport.isConnected) {
        self.bwProbeInFlight += 1;
        NSData *chunk = self.bwProbeChunk;
        __weak SessionManager *weakSelf = self;
        [_wirelessTransport sendMediaFrameViaTCP:chunk.bytes length:chunk.length completion:^(BOOL success) {
            SessionManager *s = weakSelf;
            if (!s) return;
            s.bwProbeInFlight -= 1;
            if (success) s.bwProbeSentBytes += kBWProbeChunkBytes + 4;
            [s pumpBandwidthProbe];
        }];
    }
    if (self.bwProbeInFlight == 0 && (nowUs >= self.bwProbeEndUs || !_wirelessTransport.isConnected)) {
        self.bwProbeActive = NO;
        self.bwProbeChunk = nil;
        uint64_t elapsedMs = (nowUs - self.bwProbeStartUs) / 1000;
        os_log(sLog, "bw-probe: done sentBytes=%llu elapsedMs=%llu localRate=%.1fMb/s",
               self.bwProbeSentBytes, elapsedMs,
               elapsedMs ? (double)self.bwProbeSentBytes * 8.0 / ((double)elapsedMs * 1000.0) : 0.0);
        [self sendBandwidthProbeReply:@{ @"bwProbe": @"done",
                                         @"sentBytes": @(self.bwProbeSentBytes),
                                         @"elapsedMs": @(elapsedMs) }];
    }
}

- (void)handleModeChangeFromiPad:(const void *)data length:(size_t)length {
    /* After the 9-byte InputEventHeader, subtype byte indicates the change type */
    if (length < sizeof(InputEventHeader) + 1) return;

    const uint8_t *payload = (const uint8_t *)data + sizeof(InputEventHeader);
    uint8_t subtype = payload[0];

    switch (subtype) {
        case KEYDRD_MODE_CHANGE_ECO: {
            /* Eco mode change: next byte is 0x01 (on) or 0x00 (off) */
            if (length < sizeof(InputEventHeader) + 2) return;
            BOOL ecoOn = (payload[1] != 0);
            [self handleEcoModeRequest:ecoOn];
            break;
        }
        case KEYDRD_MODE_CHANGE_REQUEST_KEYFRAME: {
            /* tla/FrameLoop.tla KeyRetry: the iPad awaits a key (handshake, gap or decode
             * failure). Owe one on both codecs; IdleKey re-emits if the screen is static. */
            uint64_t flNowUs = keydrd_host_time_us();
            os_unfair_lock_lock(&_flLock);
            [self flNeedKeyLocked:"ipad-request" nowUs:flNowUs];
            _flLastKeyReqUs = flNowUs;
            os_unfair_lock_unlock(&_flLock);
            os_log(sLog, "FL MacIpadKeyReq hevcActive=%{public}d", _hevcEncoder.isActive);
            [self flRequestKeyframe:"ipad-request"];
            break;
        }
        default:
            os_log_debug(sLog, "Unknown mode change subtype: 0x%02x", subtype);
            break;
    }
}

#pragma mark - Eco Mode

- (void)handleEcoModeRequest:(BOOL)ecoOn {
    os_log(sLog, "Eco mode request: %{public}s", ecoOn ? "ON" : "OFF");

    if (ecoOn) {
        _isEcoMode = YES;
        _capture.captureFPS = kEcoFPS;

        /* Activate HEVC at reduced resolution (1080p) and 30fps.
         * Eco mode always uses bitrate-based encoding (quality=0). */
        [_hevcEncoder startWithWidth:kEcoWidth height:kEcoHeight fps:kEcoFPS bitrate:kEcoBitrate quality:0];

        /* Reconfigure frame delivery for HEVC path */
        [self configureFrameDelivery];
    } else {
        _isEcoMode = NO;

        /* Restart HEVC at viewport resolution (not Mac native) */
        if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
            [self _startEncoderAtViewportResolution];
        } else {
            os_log_error(sLog, "Eco OFF but no viewport — cannot restart encoder");
            [_hevcEncoder stop];
            [self configureFrameDelivery];
        }
    }

    if (self.onModeChanged) {
        self.onModeChanged(_isEcoMode);
    }
}

#pragma mark - Resolution Matching

- (void)handleResolutionMatchRequest:(const void *)data length:(size_t)length {
    /* Payload: InputEventHeader (9 bytes) + ResolutionMatchPayload (8 bytes) */
    if (length < sizeof(InputEventHeader) + sizeof(ResolutionMatchPayload)) {
        os_log_error(sLog, "Resolution match request too short: %zu bytes", length);
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_FAILED width:0 height:0 scale:0];
        return;
    }

    const ResolutionMatchPayload *payload =
        (const ResolutionMatchPayload *)((const uint8_t *)data + sizeof(InputEventHeader));

    uint32_t iPadWidth = payload->ipad_width;
    uint32_t iPadHeight = payload->ipad_height;

    os_log(sLog, "Resolution match request: iPad wants %ux%u", iPadWidth, iPadHeight);

    if (iPadWidth == 0 || iPadHeight == 0) {
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_FAILED width:0 height:0 scale:0];
        return;
    }

    CGDirectDisplayID mainDisplay = CGMainDisplayID();

    /* Store current display mode for revert on disconnect */
    if (!_resolutionChanged) {
        CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplay);
        if (currentMode) {
            if (_storedDisplayMode) {
                CGDisplayModeRelease(_storedDisplayMode);
            }
            _storedDisplayMode = currentMode;
        }
    }

    /* Get all available display modes */
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(mainDisplay, NULL);
    if (!allModes) {
        os_log_error(sLog, "Failed to get display modes");
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_NO_MODE width:0 height:0 scale:0];
        return;
    }

    /* Find best mode matching iPad aspect ratio */
    float targetAspect = (float)iPadWidth / (float)iPadHeight;
    CGDisplayModeRef bestMode = NULL;
    size_t bestPixelCount = 0;
    float bestAspectDiff = HUGE_VALF;

    CFIndex modeCount = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < modeCount; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t modeWidth = CGDisplayModeGetPixelWidth(mode);
        size_t modeHeight = CGDisplayModeGetPixelHeight(mode);

        if (modeWidth == 0 || modeHeight == 0) continue;

        float modeAspect = (float)modeWidth / (float)modeHeight;
        float aspectDiff = fabsf(modeAspect - targetAspect);

        /* Accept modes within 2% aspect ratio difference */
        if (aspectDiff < 0.02f) {
            size_t pixelCount = modeWidth * modeHeight;
            /* Prefer higher resolution modes, but also prefer closer aspect ratio */
            if (aspectDiff < bestAspectDiff ||
                (aspectDiff == bestAspectDiff && pixelCount > bestPixelCount)) {
                bestMode = mode;
                bestPixelCount = pixelCount;
                bestAspectDiff = aspectDiff;
            }
        }
    }

    if (!bestMode) {
        os_log(sLog, "No suitable display mode found for aspect ratio %.4f", targetAspect);
        CFRelease(allModes);
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_NO_MODE width:0 height:0 scale:0];
        return;
    }

    /* Apply the display mode */
    CGError err = CGDisplaySetDisplayMode(mainDisplay, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        os_log_error(sLog, "CGDisplaySetDisplayMode failed: %d", err);
        CFRelease(allModes);
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_FAILED width:0 height:0 scale:0];
        return;
    }

    _resolutionChanged = YES;

    /* Read back the new geometry */
    size_t newPixelWidth = CGDisplayModeGetPixelWidth(bestMode);
    size_t newPixelHeight = CGDisplayModeGetPixelHeight(bestMode);
    size_t newLogicalWidth = CGDisplayModeGetWidth(bestMode);
    float newScale = (newLogicalWidth > 0) ? (float)newPixelWidth / (float)newLogicalWidth : 2.0f;

    CFRelease(allModes);

    os_log(sLog, "Display mode changed to %zux%zu @%.1fx", newPixelWidth, newPixelHeight, newScale);

    /* Update capture dimensions */
    _captureWidth = (uint32_t)newPixelWidth;
    _captureHeight = (uint32_t)newPixelHeight;
    _captureScale = newScale;

    /* Restart capture with new geometry */
    [_capture stopCapture];
    [_capture startCapture];
    [self configureFrameDelivery];

    /* Send success response */
    [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_OK
                                width:_captureWidth
                               height:_captureHeight
                                scale:_captureScale];

    /* Send geometry update to iPad */
    [self sendGeometryUpdate];

    if (self.onResolutionChanged) {
        self.onResolutionChanged(_captureWidth, _captureHeight);
    }
}

- (void)sendResolutionMatchResponse:(uint8_t)result
                              width:(uint32_t)width
                             height:(uint32_t)height
                              scale:(float)scale {
    InputEventHeader header;
    header.type = KEYDRD_INPUT_RES_MATCH_RESPONSE;
    header.ts_us = [self currentTimestampUs];

    ResolutionMatchResponse response;
    response.result = result;
    response.new_width = width;
    response.new_height = height;
    response.new_scale = scale;

    size_t totalLen = sizeof(InputEventHeader) + sizeof(ResolutionMatchResponse);
    uint8_t *packet = malloc(totalLen);
    if (!packet) return;

    memcpy(packet, &header, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), &response, sizeof(ResolutionMatchResponse));

    [self sendInputEventToiPad:packet length:totalLen];

    free(packet);
}

- (void)sendGeometryUpdate {
    InputEventHeader header;
    header.type = KEYDRD_INPUT_GEOMETRY_UPDATE;
    header.ts_us = [self currentTimestampUs];

    GeometryUpdatePayload geo;
    geo.display_width = _captureWidth;
    geo.display_height = _captureHeight;
    geo.scale_factor = _captureScale;
    geo.aspect_ratio = (float)_captureWidth / (float)_captureHeight;

    size_t totalLen = sizeof(InputEventHeader) + sizeof(GeometryUpdatePayload);
    uint8_t *packet = malloc(totalLen);
    if (!packet) return;

    memcpy(packet, &header, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), &geo, sizeof(GeometryUpdatePayload));

    [self sendInputEventToiPad:packet length:totalLen];

    free(packet);

    os_log(sLog, "Sent geometry update: %ux%u @%.1fx", _captureWidth, _captureHeight, _captureScale);
}

- (void)revertDisplayMode {
    if (!_resolutionChanged || !_storedDisplayMode) return;

    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CGError err = CGDisplaySetDisplayMode(mainDisplay, _storedDisplayMode, NULL);
    if (err == kCGErrorSuccess) {
        os_log(sLog, "Display mode reverted to original");
    } else {
        os_log_error(sLog, "Failed to revert display mode: %d", err);
    }

    CGDisplayModeRelease(_storedDisplayMode);
    _storedDisplayMode = NULL;
    _resolutionChanged = NO;
}

#pragma mark - Reconnection

- (void)startReconnection {
    os_log(sLog, "Connection lost -- starting reconnection with exponential backoff");
    [self transitionTo:SESSION_RECONNECTING];
    [_capture stopCapture];
    [_latencyProbeTimer invalidate];
    _latencyProbeTimer = nil;

    /* Revert resolution on disconnect */
    [self revertDisplayMode];

    /* Ensure WiFi advertising is active so the iPad can reconnect wirelessly.
     * If USB connected first during startTransportMonitoring, WiFi advertising
     * was skipped. Start it now so transport rotation tests (and real reconnections)
     * can discover the Mac over WiFi/AWDL. */
    if (!_wiredOnly) {
        [_wirelessTransport beginReconnectWindow];
    }

    if (!_wiredOnly && !_wirelessTransport.isConnected) {
        os_log(sLog, "Starting WiFi advertising for reconnection (may have been skipped earlier, state=%{public}s transport=%{public}s)",
               [self sessionStateName:_sessionState], transport_state_name(_transportState));
        [_wirelessTransport startAdvertising];
    } else if (!_wiredOnly) {
        os_log(sLog, "Reconnect path: WiFi advertising already active (wirelessConnected=%{public}d state=%{public}s transport=%{public}s)",
               _wirelessTransport.isConnected, [self sessionStateName:_sessionState], transport_state_name(_transportState));
    }

    _reconnectAttempt = 0;
    [self scheduleReconnect];
}

- (void)scheduleReconnect {
    if (_reconnectAttempt >= kReconnectMaxAttempts) {
        os_log(sLog, "Max reconnection attempts reached -- waiting for transport event");
        return;
    }

    NSTimeInterval delay = kReconnectIntervals[_reconnectAttempt];
    os_log(sLog, "Reconnection attempt %d in %.1fs", _reconnectAttempt + 1, delay);

    __weak SessionManager *weakSelf = self;
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                     repeats:NO
                                                       block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.sessionState != SESSION_RECONNECTING) return;

        strongSelf.reconnectAttempt++;

        /* Check if transport is back */
        if (strongSelf.usbTransport.isConnected || strongSelf.wirelessTransport.isConnected) {
            os_log(sLog, "Transport reconnected on attempt %d", strongSelf.reconnectAttempt);
            [strongSelf onSession:"reconnect-timer" type:0 block:^{
                SessionManager *s = weakSelf;
                if (s && s.sessionState == SESSION_RECONNECTING) [s onTransportConnected];
            }];
        } else {
            [strongSelf scheduleReconnect];
        }
    }];
}

#pragma mark - State Transitions

- (void)transitionTo:(SessionState)newState {
    if (_sessionState == newState) return;

    os_log(sLog, "Session state: %{public}s -> %{public}s",
           [self sessionStateName:_sessionState],
           [self sessionStateName:newState]);

    _sessionState = newState;

    if (self.onSessionStateChanged) {
        self.onSessionStateChanged(newState);
    }
}

- (const char *)sessionStateName:(SessionState)state {
    switch (state) {
        case SESSION_AWAITING_PERMISSIONS: return "AWAITING_PERMISSIONS";
        case SESSION_AWAITING_PAIRING:    return "AWAITING_PAIRING";
        case SESSION_CONNECTING:          return "CONNECTING";
        case SESSION_STREAMING:           return "STREAMING";
        case SESSION_RECONNECTING:        return "RECONNECTING";
        case SESSION_STOPPED:             return "STOPPED";
    }
    return "UNKNOWN";
}

#pragma mark - Utilities

- (uint64_t)currentTimestampUs {
    return keydrd_host_time_us();
}

@end
