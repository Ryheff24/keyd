# Resolution Status & Quality Issues

**Date:** 2026-03-30

---

## The Problem

The visual quality of the remote desktop is poor — text is blurry, edges are soft, and it doesn't look like a native display. This happens even over wired USB with plenty of bandwidth.

## Root Cause

There are **three separate issues** compounding into one bad visual result:

### Issue 1: SCStream Downscale Blur

**What happens:** The Mac display renders its UI at **3600x2338 pixels** (1800x1169 logical points at 2x Retina). Our viewport optimization tells SCStream to capture at **2752x1786** — the iPad's viewport size. SCStream downscales using bilinear interpolation.

**Why it's bad:** 3600→2752 is a **0.764x scale** — a non-integer ratio. Every pixel in the output is an interpolation of ~1.7 source pixels. Text rendered at 2x Retina gets resampled to fractional pixel positions, creating subpixel blur. Sharp 1px lines become soft 1.3px lines.

**Visual effect:** Everything looks slightly out of focus, like viewing through frosted glass. Most noticeable on text, UI chrome, and thin lines.

### Issue 2: Double Viewport Computation

**What happens:** After the viewport resize, the Mac sends a geometry update with `captureWidth=2752, captureHeight=1786` to the iPad. The iPad receives this as the "Mac display dimensions" and recomputes its Metal viewport for these dimensions. Since 2752x1786 has the same aspect ratio as the original Mac display (1.54), the viewport computation gives nearly the same result — but the iPad is now letterboxing a frame that's already been downscaled and letterbox-aware. The aspect ratios don't perfectly match due to even-number rounding (`& ~1`), causing a potential 1-2 pixel mismatch.

**Visual effect:** Minor — may cause a subtle scaling artifact at the edges.

### Issue 3: Low Effective Bitrate

**What happens:** The HEVC encoder is configured for 150 Mbps (USB) / 20 Mbps (WiFi) using `AverageBitRate` rate control. But actual measured throughput is only **6.1 Mbps**. The rate control aggressively undershoots on low-complexity content because `AverageBitRate` allows the encoder to use fewer bits when the content is "easy."

**Why it's bad:** 6.1 Mbps at 50fps and 2752x1786 = ~15KB per frame average. That's barely enough for clean text rendering. HEVC quantization artifacts (blocking, ringing) are visible on text edges and gradients.

**Visual effect:** Compression artifacts, especially visible on sharp text and color gradients. Gets worse on WiFi (20 Mbps target but actual output may be even lower).

---

## Current State

| Property | Value |
|----------|-------|
| Mac display | 3600x2338 (native Retina, 1800x1169 points) |
| iPad display | 2752x2064 (native, 1376x1032 points) |
| Actual viewport | 2752x1786 (letterboxed for Mac aspect ratio) |
| SCStream capture | 2752x1786 (downscaled from 3600x2338) |
| HEVC encode | 2752x1786 |
| Bitrate target | 150 Mbps (USB) / 20 Mbps (WiFi) |
| Bitrate actual | ~6 Mbps (AverageBitRate undershoot) |
| Pipeline latency | 29ms median (good) |

---

## Solution Options

### Option A: Display Mode Matching (Best Quality)

**What:** Change the Mac's physical display mode to match the iPad viewport using `CGDisplaySetDisplayMode`. The Mac renders its UI natively at 2752x1786 (or the closest available mode). SCStream captures at 1:1 — no downscale.

**Pros:**
- Text renders natively at the target resolution — pixel-perfect, no interpolation
- No SCStream downscale blur
- Mac UI is fully legible at the target DPI
- The existing `resolutionMatchRequest` infrastructure already does this

**Cons:**
- Changes the Mac's visible display (text/windows resize on the Mac screen)
- Must revert on disconnect (already handled in existing code)
- Available modes depend on the Mac hardware — exact match may not exist
- Somewhat intrusive UX (Mac display visibly changes)

**Implementation:** Already 80% built — `handleResolutionMatchRequest` in SessionManager.m changes the display mode. Just need to trigger it automatically from the viewport report instead of requiring a manual UI action.

### Option B: Capture at Native, iPad Scales in Metal (Simplest Quality Fix)

**What:** Revert SCStream to capture at Mac native resolution (3600x2338). Encode and send at full resolution. Let the iPad's Metal renderer downscale in the GPU shader during the render pass.

**Pros:**
- Mac renders at full native quality — sharpest possible source
- Metal GPU downscale is high-quality (hardware bilinear/trilinear)
- No Mac display changes
- Simple to implement (just remove the viewport-based capture resize)

**Cons:**
- Sends 42% more pixels → encode time goes back to ~100ms+ → latency regresses to ~120ms
- Uses more bandwidth
- Decode takes longer (larger frames)
- Undoes the latency improvement we just achieved

**Trade-off:** Quality vs latency. Not a good trade.

### Option C: Display Mode Match + Viewport Capture (Best of Both)

**What:** Change the Mac display mode to match the iPad viewport, THEN capture at that native resolution. The Mac renders at the target resolution natively, SCStream captures 1:1, and encode/decode operate on the right-sized frames.

**Pros:**
- Pixel-perfect quality (Mac renders at target resolution natively)
- Low latency (smaller frames, ~29ms pipeline)
- Low bandwidth
- Best quality + best latency simultaneously

**Cons:**
- Mac display visibly changes
- Must revert on disconnect
- Need to find the right display mode

**Implementation:**
1. iPad sends viewport report (already done)
2. Mac receives viewport dims
3. Mac calls `CGDisplaySetDisplayMode` to the closest matching mode (code exists in `handleResolutionMatchRequest`)
4. Mac starts SCStream capture at the new native resolution (no downscale needed)
5. HEVC encoder starts at that resolution
6. On disconnect, Mac reverts to original display mode (code exists)

### Option D: Quality-Based Encoding (CRF) (Fixes Bitrate Only)

**What:** Switch from `AverageBitRate` to constant-quality encoding using `kVTCompressionPropertyKey_Quality` (0.0-1.0 scale). The encoder targets a quality level instead of a bitrate, using as many bits as needed.

**Pros:**
- Consistent visual quality regardless of content complexity
- No bitrate undershoot — the encoder uses bits when it needs them
- Can be combined with any resolution option

**Cons:**
- Variable bitrate makes bandwidth management harder
- May produce very large keyframes on complex content
- Less control over network utilization

**Note:** This can be combined with Option A or C to fix both resolution AND bitrate issues.

---

## Recommended Path

**Option C + D** — Display mode match for pixel-perfect resolution, plus quality-based encoding for consistent visual quality.

This gives:
- Native-quality text rendering (no interpolation blur)
- Low latency (small frames, ~29ms pipeline)
- Consistent visual quality (no bitrate undershoot)
- Clean revert on disconnect

---

## What Still Needs Work (Full Status)

### Wired (USB NCM)
| Issue | Status | Impact |
|-------|--------|--------|
| Resolution quality (blur from SCStream downscale) | **Fixed** — auto display mode match (2704x1756 1:1 capture) | High → Resolved |
| Bitrate undershoot (6 Mbps actual vs 150 target) | **Fixed** — quality-based encoding (CRF 0.85) | Medium → Resolved |
| Pipeline latency | **Improved** — 28ms median (was 29ms), p95=34ms (was 75ms) | Low |
| Pipeline latency p95/max spikes | **Fixed** — frame skip on encoder queue >1 (max 47ms, was 92ms) | Medium → Resolved |
| FPS | **Improved** — 74.8fps (was ~50fps) | Medium → Low |
| Frame jitter | **Fixed** — 4.8ms stddev, 0 stutters, p95=17ms | Low |
| WiFi→USB handoff takes 15-20s | **Investigating** | Medium |
| Eco→normal mode broken | **Fixed** — restarts HEVC at viewport res | Low |
| Mac menu bar shows wrong resolution | **Fixed** — onResolutionChanged callback | Low |
| Double viewport computation | **Fixed** — geometry update handler doesn't re-send viewport report | Low |

### WiFi
| Issue | Status | Impact |
|-------|--------|--------|
| Stutter / choppy playback | **Fixed** — paced UDP sends (0.56ms/chunk) | Critical → Resolved |
| No pacing on UDP chunk sends | **Fixed** — mach_wait_until pacing on dedicated queue | Root cause → Resolved |
| Lossy reassembler (32-frame limit, 500ms timeout) | **Fixed** — 128 concurrent, 2s timeout, in-order delivery | Medium → Resolved |
| No congestion control | **Partial** — loss rate tracking + stats logging added | Medium |
| DTLS overhead on 1400B chunks | **Open** | ~73 datagrams per 100KB keyframe |
| Quality (20 Mbps target) | **Open** | Low quality + same bitrate undershoot |
| WiFi transport E2E | **Fixed** — 2591 frames rendered in rotation test | Critical → Resolved |

### Both Transports
| Issue | Status | Impact |
|-------|--------|--------|
| No mutual TLS (mTLS) | **Known gap** | Security — unauthenticated clients can connect |
| FPS ceiling at ~50fps (target 120) | **Improved** — 74.8fps (encode time is bottleneck) | Medium |
| iPad UI menu doesn't close on outside tap | **Open** | UX annoyance |
| Ghostty screen recording dialogs during E2E | **Fixed** — using updateConfiguration | Low |
