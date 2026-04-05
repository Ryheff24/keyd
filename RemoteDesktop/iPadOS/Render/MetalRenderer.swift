import Metal
import MetalKit
import QuartzCore
import CoreVideo

// MARK: - Uniforms (matches Shaders.metal)

/// Viewport rect in NDC [-1, 1] for letterbox positioning.
struct ViewportUniforms {
    var viewport: SIMD4<Float> // x, y, width, height in NDC
}

// MARK: - MetalRenderer

/// Metal frame renderer driven by CAMetalDisplayLink.
///
/// Uses triple buffering (DispatchSemaphore(value: 3)) and P3 wide color gamut.
/// Letterbox viewport computation ensures the Mac screen fits aspect-correctly
/// on the iPad with true black bars (OLED pixels off).
///
/// This is the consumer end of the display pipeline: decompressed frame data
/// arrives via `updateFrame(_:width:height:)` and is rendered on the next
/// display link callback.
final class MetalRenderer: NSObject {
    private struct PendingRenderFrame {
        let texture: MTLTexture
        let cvTextureRef: CVMetalTexture?
        let captureTimestampUs: UInt64
        let enqueuedAtUs: UInt64
    }

    struct StatsSnapshot {
        let overwrittenFrames: Int
        let hasPendingFrame: Bool
        let pendingDepth: Int
        let adaptiveCatchupCount: Int
        let adaptiveCatchupDropFrames: Int
        let adaptiveSoftCatchupCount: Int
        let adaptiveHardCatchupCount: Int
        let adaptiveSoftCatchupDropFrames: Int
        let adaptiveHardCatchupDropFrames: Int
    }

    private static let maxPendingFrames = 4
    private static let hardDepthCatchupPendingThreshold = 3
    private static let hardDepthCatchupMinQueueDelayThresholdMs = 18.0
    private static let hardDepthAggressiveTrimPendingThreshold = 4
    private static let hardDepthAggressiveTrimQueueDelayThresholdMs = 22.0
    private static let hardDepthAggressiveTrimLegacyQueueDelayThresholdMs = 24.0
    private static let hardDepthCatchupDelayStreakThreshold = 1
    private static let hardDepthCatchupCooldownTicks = 4
    private static let softCatchupQueueDelayThresholdMs = 16.0
    private static let softCatchupShallowDepthDelayThresholdMs = 20.0
    private static let softCatchupMidDepthDelayThresholdMs = 18.0
    private static let softCatchupDeepBacklogDelayThresholdMs = 18.0
    private static let hardCatchupQueueDelayThresholdMs = 48.0
    private static let hardCatchupExtremeQueueDelayThresholdMs = 140.0
    private static let softCatchupMinPendingDepth = 2
    private static let softCatchupDelayStreakThreshold = 1
    private static let hardCatchupDelayStreakThreshold = 2

    // MARK: - Properties

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState

    /// CAMetalDisplayLink drives the render loop (NOT MTKView built-in timer).
    /// Requires iPadOS 17.0+ and `CADisableMinimumFrameDuration = YES` in Info.plist
    /// for ProMotion 120Hz support.
    private var displayLink: CAMetalDisplayLink?

    /// Triple buffering: allow up to 3 frames in flight simultaneously.
    /// Prevents CPU stalls while GPU processes previous frames.
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    /// Small render queue of decoded frames waiting for presentation.
    /// A depth of 3 absorbs short decode bursts without turning them straight
    /// into dropped presents, while still bounding latency tightly.
    private var pendingFrames: [PendingRenderFrame] = []
    private let textureLock = NSLock()

    /// Count of NEW unique frames rendered (texture changed since last render).
    /// NOT display link tick count — a stale texture re-drawn doesn't count.
    private(set) var renderedFrameCount: Int = 0

    /// Timestamps of each NEW rendered frame (for FPS/jitter analysis by tests).
    private(set) var renderedFrameTimestamps: [CFAbsoluteTime] = []

    /// Callback fired each time a NEW frame is submitted for presentation.
    /// Tests hook into this to count real frame updates rather than stale redraws.
    var onFrameRendered: (() -> Void)?

    /// Callback fired with glass-to-glass timing data using the display link's
    /// target presentation timestamp for the current drawable.
    /// Parameters: (captureTimestampUs: UInt64, presentedHostTimeUs: Int64)
    /// Both values are on the Core Animation host-time timeline.
    var onFramePresented: ((_ captureTimestampUs: UInt64, _ presentedHostTimeUs: Int64) -> Void)?
    /// Callback fired when a frame leaves the renderer queue for a render pass.
    /// Parameters: captureTsUs, enqueuedAtUs, dequeuedAtUs, queueDelayMs, pendingBefore, pendingAfter, mode
    var onFrameDequeuedForRender: ((_ captureTimestampUs: UInt64,
                                    _ enqueuedAtUs: UInt64,
                                    _ dequeuedAtUs: UInt64,
                                    _ queueDelayMs: Double,
                                    _ pendingBefore: Int,
                                    _ pendingAfter: Int,
                                    _ mode: String) -> Void)?
    /// Callback fired when GPU work for a rendered frame completes.
    /// Parameters: captureTsUs, completionUs, queueDelayMs, gpuRoundtripMs, mode
    var onFrameRenderCompleted: ((_ captureTimestampUs: UInt64,
                                  _ completionUs: UInt64,
                                  _ queueDelayMs: Double,
                                  _ gpuRoundtripMs: Double,
                                  _ mode: String) -> Void)?

    /// Count of decoded frames that replaced a previous frame before the display
    /// link consumed it. This quantifies render-path coalescing under load.
    private var overwrittenFrameCount = 0

    /// Count of display-link ticks skipped because no drawable slot was
    /// available immediately. Used to detect render-side backpressure without
    /// blocking the main run loop.
    private var inflightSkipCount = 0
    private var renderQueueDelayLogCount = 0
    private var adaptiveCatchupCount = 0
    private var adaptiveCatchupDropFrames = 0
    private var adaptiveSoftCatchupCount = 0
    private var adaptiveHardCatchupCount = 0
    private var adaptiveSoftCatchupDropFrames = 0
    private var adaptiveHardCatchupDropFrames = 0
    private var softCatchupDelayStreak = 0
    private var hardCatchupDelayStreak = 0
    private var hardDepthCatchupDelayStreak = 0
    private var hardDepthCatchupCooldownTicksRemaining = 0
    private var renderTickCount = 0
    private var noPendingTickCount = 0
    private var commandBufferFailureCount = 0
    private var encoderFailureCount = 0
    private var presentCompletionLogCount = 0
    private var catchupDecisionLogCount = 0

    private static func pendingDepthBand(_ depth: Int) -> String {
        switch depth {
        case ..<2: return "low"
        case ..<4: return "mid"
        default: return "high"
        }
    }

    /// Mac display dimensions, set during session handshake.
    /// Used for aspect ratio computation and texture sizing.
    private(set) var macDisplayWidth: Int = 0
    private(set) var macDisplayHeight: Int = 0

    /// Computed letterbox viewport in NDC coordinates.
    private var viewportUniforms = ViewportUniforms(viewport: SIMD4<Float>(-1, -1, 2, 2))

    /// The CAMetalLayer this renderer draws to.
    private weak var metalLayer: CAMetalLayer?

    /// CVMetalTextureCache for zero-copy CVPixelBuffer → MTLTexture.
    /// Eliminates the ~5ms CPU→GPU memcpy of 33MB pixel data per frame.
    private var textureCache: CVMetalTextureCache?

    // MARK: - Init

    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MetalRenderer: Metal is not supported on this device")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("MetalRenderer: Failed to create command queue")
        }
        self.commandQueue = commandQueue

        // Load shaders from default library
        guard let library = device.makeDefaultLibrary() else {
            fatalError("MetalRenderer: Failed to load default Metal library")
        }
        guard let vertexFunction = library.makeFunction(name: "vertexShader") else {
            fatalError("MetalRenderer: Failed to find vertexShader function")
        }
        guard let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            fatalError("MetalRenderer: Failed to find fragmentShader function")
        }

        // Build render pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("MetalRenderer: Failed to create pipeline state: \(error)")
        }

        super.init()

        // Create CVMetalTextureCache for zero-copy pixel buffer → texture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
    }

    // MARK: - Setup

    /// Configure the Metal layer and start the display link render loop.
    ///
    /// - Parameter metalLayer: The CAMetalLayer to render into. Must be retained
    ///   by the owning view/view controller.
    func setup(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer

        // Configure layer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm

        // P3 wide color gamut (RD-REND-02)
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        // Triple buffering: 3 drawables in rotation (RD-REND-03)
        metalLayer.maximumDrawableCount = 3

        // Disable framebuffer-only for potential readback (debugging)
        metalLayer.framebufferOnly = true

        // Create display link (RD-REND-01)
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self

        // Prefer high frame rate for ProMotion 120Hz.
        // CADisableMinimumFrameDuration=YES in Info.plist enables this.
        // Ask Core Animation to keep render lead time to a single frame to
        // minimize display-link queuing latency during glass-to-glass tests.
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )

        link.add(to: .main, forMode: .common)
        link.isPaused = false
        displayLink = link
    }

    // MARK: - Frame Update

    /// Update the current frame texture with decompressed pixel data.
    ///
    /// Called from the decode pipeline after LZ4 decompress or HEVC decode.
    /// Thread-safe: protected by NSLock.
    ///
    /// - Parameters:
    ///   - data: Raw BGRA pixel data pointer.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    func updateFrame(_ data: UnsafeRawPointer, width: Int, height: Int, captureTimestampUs: UInt64 = 0) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        // Upload pixel data to texture
        let bytesPerRow = width * 4
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        enqueueFrame(texture: texture, cvTextureRef: nil, captureTimestampUs: captureTimestampUs)
    }

    /// Zero-copy frame update from CVPixelBuffer (HEVC decode output).
    ///
    /// Uses CVMetalTextureCache to create an MTLTexture backed by the pixel buffer's
    /// IOSurface — no CPU→GPU memcpy. This eliminates ~5ms per frame for 3600x2338
    /// and preserves exact pixel data from the hardware decoder.
    func updateFrameFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, captureTimestampUs: UInt64 = 0) {
        guard let cache = textureCache else {
            // Fallback to copy path
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            updateFrame(UnsafeRawPointer(base),
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer),
                        captureTimestampUs: captureTimestampUs)
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            // Fallback to copy path on failure
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            updateFrame(UnsafeRawPointer(base), width: width, height: height,
                        captureTimestampUs: captureTimestampUs)
            return
        }

        enqueueFrame(texture: texture, cvTextureRef: cvTex, captureTimestampUs: captureTimestampUs)
    }

    private func enqueueFrame(texture: MTLTexture,
                              cvTextureRef: CVMetalTexture?,
                              captureTimestampUs: UInt64) {
        textureLock.lock()
        defer { textureLock.unlock() }

        let pendingBefore = pendingFrames.count
        if pendingFrames.count >= Self.maxPendingFrames {
            let dropped = pendingFrames.removeFirst()
            overwrittenFrameCount += 1
            if overwrittenFrameCount <= 5 || overwrittenFrameCount % 100 == 0 {
                print("[CONSOLE] MetalRenderer: enqueue overflow drop oldest (pendingBefore=\(pendingBefore), droppedCaptureTs=\(dropped.captureTimestampUs), overwrittenTotal=\(overwrittenFrameCount))")
            }
        }

        pendingFrames.append(PendingRenderFrame(
            texture: texture,
            cvTextureRef: cvTextureRef,
            captureTimestampUs: captureTimestampUs,
            enqueuedAtUs: UInt64(CACurrentMediaTime() * 1_000_000.0)
        ))
        let pendingAfter = pendingFrames.count
        let pendingBandBefore = Self.pendingDepthBand(pendingBefore)
        let pendingBandAfter = Self.pendingDepthBand(pendingAfter)
        if pendingBandBefore != pendingBandAfter {
            print("[CONSOLE] MetalRenderer: pending depth transition reason=enqueue from=\(pendingBefore)(\(pendingBandBefore)) to=\(pendingAfter)(\(pendingBandAfter)) captureTsUs=\(captureTimestampUs)")
        }
        if pendingAfter >= 2 && (pendingAfter == Self.maxPendingFrames || pendingAfter % 2 == 0) {
            print("[CONSOLE] MetalRenderer: enqueue success pending=\(pendingAfter) captureTsUs=\(captureTimestampUs)")
        }
    }

    /// Set the Mac display dimensions (called during session handshake).
    /// Triggers viewport recomputation if screen bounds are known.
    func setMacDisplaySize(width: Int, height: Int) {
        macDisplayWidth = width
        macDisplayHeight = height

        if let layer = metalLayer {
            computeViewport(screenBounds: CGRect(
                x: 0, y: 0,
                width: layer.bounds.width * layer.contentsScale,
                height: layer.bounds.height * layer.contentsScale
            ))
        }
    }

    // MARK: - Viewport

    /// Compute the letterbox viewport for aspect-fit rendering.
    ///
    /// Calculates an aspect-fit rectangle so the entire Mac screen is visible.
    /// Background is true black (0,0,0,1) -- on tandem OLED, these pixels are off.
    ///
    /// - Parameter screenBounds: The iPad screen bounds in pixels.
    func computeViewport(screenBounds: CGRect) {
        guard macDisplayWidth > 0, macDisplayHeight > 0 else {
            // No Mac dimensions yet; render fullscreen
            viewportUniforms.viewport = SIMD4<Float>(-1, -1, 2, 2)
            return
        }

        let macAspect = Float(macDisplayWidth) / Float(macDisplayHeight)
        let screenAspect = Float(screenBounds.width) / Float(screenBounds.height)

        let ndcX: Float
        let ndcY: Float
        let ndcW: Float
        let ndcH: Float

        if macAspect > screenAspect {
            // Mac is wider relative to iPad: full width, letterbox top/bottom
            ndcX = -1.0
            ndcW = 2.0
            let scale = screenAspect / macAspect
            ndcH = 2.0 * scale
            ndcY = -scale // Center vertically
        } else if macAspect < screenAspect {
            // Mac is taller relative to iPad: full height, pillarbox left/right
            ndcY = -1.0
            ndcH = 2.0
            let scale = macAspect / screenAspect
            ndcW = 2.0 * scale
            ndcX = -scale // Center horizontally
        } else {
            // Exact match: fill entire screen
            ndcX = -1.0
            ndcY = -1.0
            ndcW = 2.0
            ndcH = 2.0
        }

        viewportUniforms.viewport = SIMD4<Float>(ndcX, ndcY, ndcW, ndcH)
    }

    /// Handle orientation or bounds change. Call from the view controller's
    /// `viewWillTransition(to:with:)` or when layer bounds change.
    ///
    /// No hardcoded dimensions: uses actual screen bounds for iPad Pro 11" and 13" support.
    func handleBoundsChange(newBounds: CGRect, scale: CGFloat) {
        let pixelBounds = CGRect(
            x: 0, y: 0,
            width: newBounds.width * scale,
            height: newBounds.height * scale
        )
        computeViewport(screenBounds: pixelBounds)
    }

    func statsSnapshot() -> StatsSnapshot {
        textureLock.lock()
        defer { textureLock.unlock() }
        return StatsSnapshot(
            overwrittenFrames: overwrittenFrameCount,
            hasPendingFrame: !pendingFrames.isEmpty,
            pendingDepth: pendingFrames.count,
            adaptiveCatchupCount: adaptiveCatchupCount,
            adaptiveCatchupDropFrames: adaptiveCatchupDropFrames,
            adaptiveSoftCatchupCount: adaptiveSoftCatchupCount,
            adaptiveHardCatchupCount: adaptiveHardCatchupCount,
            adaptiveSoftCatchupDropFrames: adaptiveSoftCatchupDropFrames,
            adaptiveHardCatchupDropFrames: adaptiveHardCatchupDropFrames
        )
    }

    // MARK: - Teardown

    /// Stop the display link and release resources.
    func stop() {
        displayLink?.isPaused = true
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        stop()
    }
}

// MARK: - CAMetalDisplayLinkDelegate

extension MetalRenderer: CAMetalDisplayLinkDelegate {

    func metalDisplayLink(_ link: CAMetalDisplayLink,
                          needsUpdate update: CAMetalDisplayLink.Update) {
        renderTickCount += 1
        textureLock.lock()
        let hasPendingFrame = !pendingFrames.isEmpty
        let pendingDepth = pendingFrames.count
        textureLock.unlock()

        // Nothing new to show. Keep the last presented frame on screen rather
        // than consuming drawables/redrawing stale content at display-link rate.
        guard hasPendingFrame else {
            noPendingTickCount += 1
            if noPendingTickCount <= 5 || noPendingTickCount % 300 == 0 {
                print("[CONSOLE] MetalRenderer: tick skip reason=no-pending tick=\(renderTickCount) noPendingTotal=\(noPendingTickCount)")
            }
            return
        }

        // Never block the main run loop waiting for a drawable slot; if the GPU
        // is briefly behind, keep the newest decoded frame pending for the next tick.
        if inflightSemaphore.wait(timeout: .now()) == .timedOut {
            inflightSkipCount += 1
            if inflightSkipCount <= 5 || inflightSkipCount % 100 == 0 {
                textureLock.lock()
                let pending = pendingFrames.count
                textureLock.unlock()
                print("[CONSOLE] MetalRenderer: skipped render tick waiting for inflight slot (pending=\(pending), total=\(inflightSkipCount))")
            }
            return
        }

        // Step 2: Get the drawable from the update
        let drawable = update.drawable

        // Step 3: Create command buffer
        let commandBufferCreateStartUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            commandBufferFailureCount += 1
            print("[CONSOLE] MetalRenderer: render abort reason=command-buffer-create-failed pendingDepth=\(pendingDepth) failures=\(commandBufferFailureCount)")
            inflightSemaphore.signal()
            return
        }

        // Step 4: Create render pass descriptor -- clear to true black (OLED pixels off)
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1
        )
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        // Step 5: Create render command encoder
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            encoderFailureCount += 1
            print("[CONSOLE] MetalRenderer: render abort reason=encoder-create-failed pendingDepth=\(pendingDepth) failures=\(encoderFailureCount)")
            inflightSemaphore.signal()
            return
        }

        // Pop one queued frame atomically so latency samples always pair the
        // presented texture with its original capture timestamp.
        //
        // Present frames in FIFO order to preserve cadence continuity.
        // Dropping already-decoded pending frames at render tick can cause
        // visible stutter and low rendered-FPS under bursty arrivals.
        let dequeueNowUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
        textureLock.lock()
        guard !pendingFrames.isEmpty else {
            textureLock.unlock()
            encoder.endEncoding()
            inflightSemaphore.signal()
            return
        }
        let pendingBefore = pendingFrames.count
        if hardDepthCatchupCooldownTicksRemaining > 0 {
            hardDepthCatchupCooldownTicksRemaining -= 1
        }
        let oldestDelayMs = Double(dequeueNowUs &- pendingFrames[0].enqueuedAtUs) / 1000.0
        let hardDelayTriggered = oldestDelayMs >= Self.hardCatchupQueueDelayThresholdMs
        let hardExtremeTail = oldestDelayMs >= Self.hardCatchupExtremeQueueDelayThresholdMs
        if hardDelayTriggered {
            hardCatchupDelayStreak += 1
        } else {
            hardCatchupDelayStreak = 0
        }
        let hardDepthCandidate = pendingBefore >= Self.hardDepthCatchupPendingThreshold &&
            oldestDelayMs >= Self.hardDepthCatchupMinQueueDelayThresholdMs
        let hardDepthAggressiveTrimEligible = pendingBefore >= Self.hardDepthAggressiveTrimPendingThreshold
        let hardDepthAggressiveTrimCandidate = hardDepthAggressiveTrimEligible &&
            oldestDelayMs >= Self.hardDepthAggressiveTrimQueueDelayThresholdMs
        let hardDepthAggressiveTrimLegacyCandidate = hardDepthAggressiveTrimEligible &&
            oldestDelayMs >= Self.hardDepthAggressiveTrimLegacyQueueDelayThresholdMs
        if hardDepthCandidate {
            hardDepthCatchupDelayStreak += 1
        } else if pendingBefore <= Self.softCatchupMinPendingDepth {
            hardDepthCatchupDelayStreak = 0
            hardDepthCatchupCooldownTicksRemaining = 0
        } else if hardDepthCatchupDelayStreak > 0 {
            hardDepthCatchupDelayStreak -= 1
        }
        let hardDepthTriggered = hardDepthCandidate &&
            hardDepthCatchupDelayStreak >= Self.hardDepthCatchupDelayStreakThreshold &&
            hardDepthCatchupCooldownTicksRemaining == 0
        let shouldHardCatchUp = hardExtremeTail || hardDepthTriggered ||
            (hardDelayTriggered && hardCatchupDelayStreak >= Self.hardCatchupDelayStreakThreshold)
        let midSoftDepth = pendingBefore >= Self.hardDepthCatchupPendingThreshold &&
            pendingBefore < Self.hardDepthAggressiveTrimPendingThreshold
        let deepSoftDepth = pendingBefore >= Self.hardDepthAggressiveTrimPendingThreshold
        let softDelayThresholdMs: Double
        if pendingBefore <= Self.softCatchupMinPendingDepth {
            softDelayThresholdMs = Self.softCatchupShallowDepthDelayThresholdMs
        } else if midSoftDepth {
            softDelayThresholdMs = max(Self.softCatchupMidDepthDelayThresholdMs,
                                       Self.hardDepthCatchupMinQueueDelayThresholdMs)
        } else if deepSoftDepth {
            softDelayThresholdMs = max(Self.softCatchupDeepBacklogDelayThresholdMs,
                                       Self.hardDepthCatchupMinQueueDelayThresholdMs)
        } else {
            softDelayThresholdMs = Self.softCatchupQueueDelayThresholdMs
        }
        let softDelayTriggered = oldestDelayMs >= softDelayThresholdMs
        if softDelayTriggered {
            softCatchupDelayStreak += 1
        } else {
            softCatchupDelayStreak = 0
        }
        let softSuppressedByDepthCooldown = hardDepthCatchupCooldownTicksRemaining > 0 &&
            (midSoftDepth || deepSoftDepth) &&
            !hardDelayTriggered
        if softSuppressedByDepthCooldown {
            softCatchupDelayStreak = 0
        }
        let shouldSoftCatchUp = !shouldHardCatchUp &&
            !softSuppressedByDepthCooldown &&
            pendingBefore >= Self.softCatchupMinPendingDepth &&
            softDelayTriggered &&
            softCatchupDelayStreak >= Self.softCatchupDelayStreakThreshold
        catchupDecisionLogCount += 1
        let holdWithBacklog = !shouldHardCatchUp && !shouldSoftCatchUp &&
            (pendingBefore >= Self.softCatchupMinPendingDepth ||
             oldestDelayMs >= softDelayThresholdMs)
        if shouldHardCatchUp || shouldSoftCatchUp || holdWithBacklog ||
            catchupDecisionLogCount <= 10 || catchupDecisionLogCount % 240 == 0 {
            let hardDepthAggressiveTrimDecision: String
            if hardDepthTriggered && !hardDelayTriggered && hardDepthAggressiveTrimEligible {
                hardDepthAggressiveTrimDecision = hardDepthAggressiveTrimCandidate ? "apply" : "hold"
            } else {
                hardDepthAggressiveTrimDecision = "na"
            }
            let hardDepthAggressiveDelayDeltaMs = oldestDelayMs - Self.hardDepthAggressiveTrimQueueDelayThresholdMs
            let hardDepthAggressiveLegacyDelayDeltaMs = oldestDelayMs - Self.hardDepthAggressiveTrimLegacyQueueDelayThresholdMs
            let decisionBranch = (shouldHardCatchUp || shouldSoftCatchUp) ? "apply" : "hold"
            let decisionMode: String
            let hardTrimPolicy: String
            if shouldHardCatchUp {
                decisionMode = hardExtremeTail
                    ? "catchup-hard-extreme"
                    : (hardDepthTriggered ? "catchup-hard-depth" : "catchup-hard-delay")
                if hardExtremeTail {
                    hardTrimPolicy = "extreme-keep-2"
                } else if hardDepthTriggered && !hardDelayTriggered && hardDepthAggressiveTrimCandidate {
                    hardTrimPolicy = "depth-aggressive-keep-2"
                } else if hardDepthTriggered && !hardDelayTriggered {
                    hardTrimPolicy = "depth-standard-keep-3"
                } else {
                    hardTrimPolicy = "delay-keep-2"
                }
            } else if shouldSoftCatchUp {
                decisionMode = "catchup-soft-single"
                hardTrimPolicy = "soft-single-drop-1"
            } else {
                decisionMode = "fifo"
                hardTrimPolicy = "none"
            }
            let softSuppressionReason = softSuppressedByDepthCooldown ? "depth-cooldown-middeep" : "none"
            print("[CONSOLE] MetalRenderer: catchup decision branch=\(decisionBranch) mode=\(decisionMode) pendingBefore=\(pendingBefore) oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms softThreshold=\(String(format: "%.2f", Self.softCatchupQueueDelayThresholdMs))ms softThresholdApplied=\(String(format: "%.2f", softDelayThresholdMs))ms shallowSoftThreshold=\(String(format: "%.2f", Self.softCatchupShallowDepthDelayThresholdMs))ms midSoftThreshold=\(String(format: "%.2f", Self.softCatchupMidDepthDelayThresholdMs))ms deepSoftThreshold=\(String(format: "%.2f", Self.softCatchupDeepBacklogDelayThresholdMs))ms hardDepthDelayThreshold=\(String(format: "%.2f", Self.hardDepthCatchupMinQueueDelayThresholdMs))ms hardDepthAggressiveThreshold=\(String(format: "%.2f", Self.hardDepthAggressiveTrimQueueDelayThresholdMs))ms hardDepthAggressiveLegacyThreshold=\(String(format: "%.2f", Self.hardDepthAggressiveTrimLegacyQueueDelayThresholdMs))ms hardThreshold=\(String(format: "%.2f", Self.hardCatchupQueueDelayThresholdMs))ms extremeThreshold=\(String(format: "%.2f", Self.hardCatchupExtremeQueueDelayThresholdMs))ms softDepth=\(Self.softCatchupMinPendingDepth) hardDepth=\(Self.hardDepthCatchupPendingThreshold) hardDepthAggressivePending=\(Self.hardDepthAggressiveTrimPendingThreshold) softDelayTriggered=\(softDelayTriggered) hardDelayTriggered=\(hardDelayTriggered) hardDepthCandidate=\(hardDepthCandidate) hardDepthAggressiveCandidate=\(hardDepthAggressiveTrimCandidate) hardDepthAggressiveLegacyCandidate=\(hardDepthAggressiveTrimLegacyCandidate) hardDepthAggressiveDecision=\(hardDepthAggressiveTrimDecision) hardDepthAggressiveDelayDeltaMs=\(String(format: "%.2f", hardDepthAggressiveDelayDeltaMs)) hardDepthAggressiveLegacyDelayDeltaMs=\(String(format: "%.2f", hardDepthAggressiveLegacyDelayDeltaMs)) hardDepthTriggered=\(hardDepthTriggered) hardTrimPolicy=\(hardTrimPolicy) softSuppressedByDepthCooldown=\(softSuppressedByDepthCooldown) softSuppressionReason=\(softSuppressionReason) shallowSoftDepth=\(pendingBefore <= Self.softCatchupMinPendingDepth) midSoftDepth=\(midSoftDepth) deepSoftDepth=\(deepSoftDepth) depthStreak=\(hardDepthCatchupDelayStreak)/\(Self.hardDepthCatchupDelayStreakThreshold) depthCooldownTicks=\(hardDepthCatchupCooldownTicksRemaining) softStreak=\(softCatchupDelayStreak)/\(Self.softCatchupDelayStreakThreshold) hardStreak=\(hardCatchupDelayStreak)/\(Self.hardCatchupDelayStreakThreshold) sampled=\((shouldHardCatchUp || shouldSoftCatchUp || oldestDelayMs >= Self.hardDepthAggressiveTrimQueueDelayThresholdMs) ? "forced" : "sampled") count=\(catchupDecisionLogCount)")
        }

        let frame: PendingRenderFrame
        let dequeueMode: String
        var droppedStaleFrames = 0
        var hardKeepTarget = 0
        if shouldHardCatchUp && pendingBefore > 1 {
            if hardExtremeTail {
                hardKeepTarget = 2
            } else if hardDepthTriggered && !hardDelayTriggered && hardDepthAggressiveTrimCandidate {
                hardKeepTarget = 2
            } else if hardDepthTriggered && !hardDelayTriggered {
                hardKeepTarget = max(3, pendingFrames.count - 1)
            } else {
                hardKeepTarget = 2
            }
            droppedStaleFrames = max(0, pendingFrames.count - hardKeepTarget)
            if droppedStaleFrames > 0 {
                pendingFrames.removeFirst(droppedStaleFrames)
                adaptiveCatchupDropFrames += droppedStaleFrames
                adaptiveHardCatchupDropFrames += droppedStaleFrames
            }
            frame = pendingFrames.removeFirst()
            adaptiveCatchupCount += 1
            adaptiveHardCatchupCount += 1
            softCatchupDelayStreak = 0
            hardCatchupDelayStreak = 0
            if hardDepthTriggered && !hardDelayTriggered && !hardExtremeTail {
                hardDepthCatchupCooldownTicksRemaining = Self.hardDepthCatchupCooldownTicks
                hardDepthCatchupDelayStreak = 0
            }
            dequeueMode = hardExtremeTail
                ? "catchup-hard-extreme"
                : (hardDepthTriggered ? "catchup-hard-depth" : "catchup-hard-delay")
        } else if shouldSoftCatchUp && pendingBefore > 1 {
            _ = pendingFrames.removeFirst()
            droppedStaleFrames = 1
            adaptiveCatchupDropFrames += droppedStaleFrames
            adaptiveSoftCatchupDropFrames += droppedStaleFrames
            adaptiveCatchupCount += 1
            adaptiveSoftCatchupCount += 1
            softCatchupDelayStreak = 0
            hardCatchupDelayStreak = 0
            frame = pendingFrames.removeFirst()
            dequeueMode = "catchup-soft-single"
        } else {
            frame = pendingFrames.removeFirst()
            dequeueMode = "fifo"
        }
        let pendingAfterPop = pendingFrames.count
        let pendingBandBefore = Self.pendingDepthBand(pendingBefore)
        let pendingBandAfter = Self.pendingDepthBand(pendingAfterPop)
        textureLock.unlock()

        let queueDelayMs = Double(dequeueNowUs &- frame.enqueuedAtUs) / 1000.0
        let dequeueAgeDeltaMs = max(0.0, oldestDelayMs - queueDelayMs)
        let displayLeadMs = (update.targetPresentationTimestamp - CACurrentMediaTime()) * 1000.0
        renderQueueDelayLogCount += 1
        if pendingBandBefore != pendingBandAfter || droppedStaleFrames > 0 {
            print("[CONSOLE] MetalRenderer: pending depth transition reason=dequeue mode=\(dequeueMode) from=\(pendingBefore)(\(pendingBandBefore)) to=\(pendingAfterPop)(\(pendingBandAfter)) droppedStale=\(droppedStaleFrames) oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms queueDelay=\(String(format: "%.2f", queueDelayMs))ms")
        }
        if droppedStaleFrames > 0 {
            let hardDepthAggressiveTrimDecision: String
            if hardDepthTriggered && !hardDelayTriggered && hardDepthAggressiveTrimEligible {
                hardDepthAggressiveTrimDecision = hardDepthAggressiveTrimCandidate ? "apply" : "hold"
            } else {
                hardDepthAggressiveTrimDecision = "na"
            }
            let hardDepthAggressiveDelayDeltaMs = oldestDelayMs - Self.hardDepthAggressiveTrimQueueDelayThresholdMs
            let hardDepthAggressiveLegacyDelayDeltaMs = oldestDelayMs - Self.hardDepthAggressiveTrimLegacyQueueDelayThresholdMs
            print("[CONSOLE] MetalRenderer: dequeue branch mode=\(dequeueMode) pendingBefore=\(pendingBefore) pendingAfter=\(pendingAfterPop) oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms softThreshold=\(String(format: "%.2f", Self.softCatchupQueueDelayThresholdMs))ms softThresholdApplied=\(String(format: "%.2f", softDelayThresholdMs))ms shallowSoftThreshold=\(String(format: "%.2f", Self.softCatchupShallowDepthDelayThresholdMs))ms midSoftThreshold=\(String(format: "%.2f", Self.softCatchupMidDepthDelayThresholdMs))ms deepSoftThreshold=\(String(format: "%.2f", Self.softCatchupDeepBacklogDelayThresholdMs))ms hardDepthDelayThreshold=\(String(format: "%.2f", Self.hardDepthCatchupMinQueueDelayThresholdMs))ms hardDepthAggressiveThreshold=\(String(format: "%.2f", Self.hardDepthAggressiveTrimQueueDelayThresholdMs))ms hardThreshold=\(String(format: "%.2f", Self.hardCatchupQueueDelayThresholdMs))ms extremeThreshold=\(String(format: "%.2f", Self.hardCatchupExtremeQueueDelayThresholdMs))ms hardDepth=\(Self.hardDepthCatchupPendingThreshold) hardDepthAggressivePending=\(Self.hardDepthAggressiveTrimPendingThreshold) softDepth=\(Self.softCatchupMinPendingDepth) hardDepthCandidate=\(hardDepthCandidate) hardDepthAggressiveCandidate=\(hardDepthAggressiveTrimCandidate) hardDepthTriggered=\(hardDepthTriggered) softSuppressedByDepthCooldown=\(softSuppressedByDepthCooldown) shallowSoftDepth=\(pendingBefore <= Self.softCatchupMinPendingDepth) midSoftDepth=\(midSoftDepth) deepSoftDepth=\(deepSoftDepth) depthStreak=\(hardDepthCatchupDelayStreak)/\(Self.hardDepthCatchupDelayStreakThreshold) depthCooldownTicks=\(hardDepthCatchupCooldownTicksRemaining) softStreak=\(softCatchupDelayStreak)/\(Self.softCatchupDelayStreakThreshold) hardStreak=\(hardCatchupDelayStreak)/\(Self.hardCatchupDelayStreakThreshold) hardKeep=\(hardKeepTarget) hardExtreme=\(hardExtremeTail) droppedStale=\(droppedStaleFrames) dequeueAgeDelta=\(String(format: "%.2f", dequeueAgeDeltaMs))ms catchupTotal=\(adaptiveCatchupCount) catchupDropTotal=\(adaptiveCatchupDropFrames) softCatchup=\(adaptiveSoftCatchupCount)/\(adaptiveSoftCatchupDropFrames) hardCatchup=\(adaptiveHardCatchupCount)/\(adaptiveHardCatchupDropFrames)")
            print("[CONSOLE] MetalRenderer: dequeue branch mode=\(dequeueMode) pendingBefore=\(pendingBefore) pendingAfter=\(pendingAfterPop) oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms softThreshold=\(String(format: "%.2f", Self.softCatchupQueueDelayThresholdMs))ms softThresholdApplied=\(String(format: "%.2f", softDelayThresholdMs))ms shallowSoftThreshold=\(String(format: "%.2f", Self.softCatchupShallowDepthDelayThresholdMs))ms midSoftThreshold=\(String(format: "%.2f", Self.softCatchupMidDepthDelayThresholdMs))ms deepSoftThreshold=\(String(format: "%.2f", Self.softCatchupDeepBacklogDelayThresholdMs))ms hardDepthDelayThreshold=\(String(format: "%.2f", Self.hardDepthCatchupMinQueueDelayThresholdMs))ms hardDepthAggressiveThreshold=\(String(format: "%.2f", Self.hardDepthAggressiveTrimQueueDelayThresholdMs))ms hardDepthAggressiveLegacyThreshold=\(String(format: "%.2f", Self.hardDepthAggressiveTrimLegacyQueueDelayThresholdMs))ms hardThreshold=\(String(format: "%.2f", Self.hardCatchupQueueDelayThresholdMs))ms extremeThreshold=\(String(format: "%.2f", Self.hardCatchupExtremeQueueDelayThresholdMs))ms hardDepth=\(Self.hardDepthCatchupPendingThreshold) hardDepthAggressivePending=\(Self.hardDepthAggressiveTrimPendingThreshold) softDepth=\(Self.softCatchupMinPendingDepth) hardDepthCandidate=\(hardDepthCandidate) hardDepthAggressiveCandidate=\(hardDepthAggressiveTrimCandidate) hardDepthAggressiveLegacyCandidate=\(hardDepthAggressiveTrimLegacyCandidate) hardDepthAggressiveDecision=\(hardDepthAggressiveTrimDecision) hardDepthAggressiveDelayDeltaMs=\(String(format: "%.2f", hardDepthAggressiveDelayDeltaMs)) hardDepthAggressiveLegacyDelayDeltaMs=\(String(format: "%.2f", hardDepthAggressiveLegacyDelayDeltaMs)) hardDepthTriggered=\(hardDepthTriggered) softSuppressedByDepthCooldown=\(softSuppressedByDepthCooldown) shallowSoftDepth=\(pendingBefore <= Self.softCatchupMinPendingDepth) midSoftDepth=\(midSoftDepth) deepSoftDepth=\(deepSoftDepth) depthStreak=\(hardDepthCatchupDelayStreak)/\(Self.hardDepthCatchupDelayStreakThreshold) depthCooldownTicks=\(hardDepthCatchupCooldownTicksRemaining) softStreak=\(softCatchupDelayStreak)/\(Self.softCatchupDelayStreakThreshold) hardStreak=\(hardCatchupDelayStreak)/\(Self.hardCatchupDelayStreakThreshold) hardKeep=\(hardKeepTarget) hardExtreme=\(hardExtremeTail) droppedStale=\(droppedStaleFrames) dequeueAgeDelta=\(String(format: "%.2f", dequeueAgeDeltaMs))ms catchupTotal=\(adaptiveCatchupCount) catchupDropTotal=\(adaptiveCatchupDropFrames) softCatchup=\(adaptiveSoftCatchupCount)/\(adaptiveSoftCatchupDropFrames) hardCatchup=\(adaptiveHardCatchupCount)/\(adaptiveHardCatchupDropFrames)")
        }
        if renderQueueDelayLogCount <= 10 || renderQueueDelayLogCount % 120 == 0 || queueDelayMs >= Self.softCatchupQueueDelayThresholdMs || droppedStaleFrames > 0 || pendingBefore >= Self.hardDepthCatchupPendingThreshold {
            let hardDepthAggressiveTrimDecision: String
            if hardDepthTriggered && !hardDelayTriggered && hardDepthAggressiveTrimEligible {
                hardDepthAggressiveTrimDecision = hardDepthAggressiveTrimCandidate ? "apply" : "hold"
            } else {
                hardDepthAggressiveTrimDecision = "na"
            }
            let hardDepthAggressiveDelayDeltaMs = oldestDelayMs - Self.hardDepthAggressiveTrimQueueDelayThresholdMs
            let hardDepthAggressiveLegacyDelayDeltaMs = oldestDelayMs - Self.hardDepthAggressiveTrimLegacyQueueDelayThresholdMs
            print("[CONSOLE] MetalRenderer: render dequeue mode=\(dequeueMode) pendingBefore=\(pendingBefore) pendingAfter=\(pendingAfterPop) queueDelay=\(String(format: "%.2f", queueDelayMs))ms oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms dequeueAgeDelta=\(String(format: "%.2f", dequeueAgeDeltaMs))ms displayLead=\(String(format: "%.2f", displayLeadMs))ms softThresholdApplied=\(String(format: "%.2f", softDelayThresholdMs))ms shallowSoftDepth=\(pendingBefore <= Self.softCatchupMinPendingDepth) midSoftDepth=\(midSoftDepth) deepSoftDepth=\(deepSoftDepth) softDelayTriggered=\(softDelayTriggered) hardDelayTriggered=\(hardDelayTriggered) hardDepthCandidate=\(hardDepthCandidate) hardDepthAggressiveCandidate=\(hardDepthAggressiveTrimCandidate) hardDepthAggressiveLegacyCandidate=\(hardDepthAggressiveTrimLegacyCandidate) hardDepthAggressiveDecision=\(hardDepthAggressiveTrimDecision) hardDepthAggressiveDelayDeltaMs=\(String(format: "%.2f", hardDepthAggressiveDelayDeltaMs)) hardDepthAggressiveLegacyDelayDeltaMs=\(String(format: "%.2f", hardDepthAggressiveLegacyDelayDeltaMs)) hardDepthTriggered=\(hardDepthTriggered) softSuppressedByDepthCooldown=\(softSuppressedByDepthCooldown) depthStreak=\(hardDepthCatchupDelayStreak)/\(Self.hardDepthCatchupDelayStreakThreshold) depthCooldownTicks=\(hardDepthCatchupCooldownTicksRemaining) softStreak=\(softCatchupDelayStreak)/\(Self.softCatchupDelayStreakThreshold) hardStreak=\(hardCatchupDelayStreak)/\(Self.hardCatchupDelayStreakThreshold) captureTsUs=\(frame.captureTimestampUs)")
        }
        onFrameDequeuedForRender?(frame.captureTimestampUs,
                                  frame.enqueuedAtUs,
                                  dequeueNowUs,
                                  queueDelayMs,
                                  pendingBefore,
                                  pendingAfterPop,
                                  dequeueMode)

        // Step 6: Set pipeline state and resources
        encoder.setRenderPipelineState(pipelineState)

        // Pass viewport uniforms to vertex shader
        var uniforms = viewportUniforms
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<ViewportUniforms>.size,
            index: 0
        )

        // Set frame texture for fragment shader
        encoder.setFragmentTexture(frame.texture, index: 0)

        // Step 7: Draw triangle strip (4 vertices = full-screen quad)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderedFrameCount += 1
        renderedFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
        onFrameRendered?()

        // Step 8: End encoding
        encoder.endEncoding()

        // Step 9: Present drawable
        commandBuffer.present(drawable)

        // Glass-to-glass: compare the capture host time to the display
        // link's target presentation time for this drawable.
        if frame.captureTimestampUs > 0 {
            let targetPresentation = update.targetPresentationTimestamp
            if targetPresentation > 0 {
                let presentedHostTimeUs = Int64(targetPresentation * 1_000_000)
                onFramePresented?(frame.captureTimestampUs, presentedHostTimeUs)
            }
        }

        let submitToGPUStartUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
        commandBuffer.addCompletedHandler { [weak self, retainedCVTexture = frame.cvTextureRef] _ in
            _ = retainedCVTexture
            let completionUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
            let gpuRoundtripMs = Double(completionUs &- submitToGPUStartUs) / 1000.0
            if let self {
                self.presentCompletionLogCount += 1
                if self.presentCompletionLogCount <= 10 || self.presentCompletionLogCount % 240 == 0 || gpuRoundtripMs >= 12.0 {
                    print("[CONSOLE] MetalRenderer: render complete mode=\(dequeueMode) queueDelay=\(String(format: "%.2f", queueDelayMs))ms gpuRoundtrip=\(String(format: "%.2f", gpuRoundtripMs))ms pendingAfter=\(pendingAfterPop) submitLag=\(String(format: "%.2f", Double(submitToGPUStartUs &- commandBufferCreateStartUs) / 1000.0))ms")
                }
                self.onFrameRenderCompleted?(frame.captureTimestampUs,
                                             completionUs,
                                             queueDelayMs,
                                             gpuRoundtripMs,
                                             dequeueMode)
            }
            self?.inflightSemaphore.signal()
        }

        commandBuffer.commit()
    }
}
