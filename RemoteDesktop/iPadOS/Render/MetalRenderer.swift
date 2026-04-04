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
    }

    private static let maxPendingFrames = 3
    private static let adaptiveQueueDelayThresholdMs = 12.0

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
            adaptiveCatchupDropFrames: adaptiveCatchupDropFrames
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
        textureLock.lock()
        let hasPendingFrame = !pendingFrames.isEmpty
        textureLock.unlock()

        // Nothing new to show. Keep the last presented frame on screen rather
        // than consuming drawables/redrawing stale content at display-link rate.
        guard hasPendingFrame else { return }

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
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
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
        let oldestDelayMs = Double(dequeueNowUs &- pendingFrames[0].enqueuedAtUs) / 1000.0
        let shouldCatchUp = pendingBefore >= Self.maxPendingFrames || oldestDelayMs >= Self.adaptiveQueueDelayThresholdMs

        let frame: PendingRenderFrame
        let dequeueMode: String
        var droppedStaleFrames = 0
        if shouldCatchUp && pendingBefore > 1 {
            frame = pendingFrames.removeLast()
            droppedStaleFrames = pendingFrames.count
            if droppedStaleFrames > 0 {
                pendingFrames.removeAll(keepingCapacity: true)
                adaptiveCatchupDropFrames += droppedStaleFrames
            }
            adaptiveCatchupCount += 1
            dequeueMode = pendingBefore >= Self.maxPendingFrames ? "catchup-depth" : "catchup-delay"
        } else {
            frame = pendingFrames.removeFirst()
            dequeueMode = "fifo"
        }
        let pendingAfterPop = pendingFrames.count
        textureLock.unlock()

        let queueDelayMs = Double(dequeueNowUs &- frame.enqueuedAtUs) / 1000.0
        renderQueueDelayLogCount += 1
        if droppedStaleFrames > 0 {
            print("[CONSOLE] MetalRenderer: dequeue branch mode=\(dequeueMode) pendingBefore=\(pendingBefore) pendingAfter=\(pendingAfterPop) oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms threshold=\(String(format: "%.2f", Self.adaptiveQueueDelayThresholdMs))ms droppedStale=\(droppedStaleFrames) catchupTotal=\(adaptiveCatchupCount) catchupDropTotal=\(adaptiveCatchupDropFrames)")
        }
        if renderQueueDelayLogCount <= 10 || renderQueueDelayLogCount % 120 == 0 || queueDelayMs >= 20.0 || droppedStaleFrames > 0 {
            print("[CONSOLE] MetalRenderer: render dequeue mode=\(dequeueMode) pendingBefore=\(pendingBefore) pendingAfter=\(pendingAfterPop) queueDelay=\(String(format: "%.2f", queueDelayMs))ms oldestDelay=\(String(format: "%.2f", oldestDelayMs))ms captureTsUs=\(frame.captureTimestampUs)")
        }

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

        commandBuffer.addCompletedHandler { [weak self, retainedCVTexture = frame.cvTextureRef] _ in
            _ = retainedCVTexture
            self?.inflightSemaphore.signal()
        }

        commandBuffer.commit()
    }
}
