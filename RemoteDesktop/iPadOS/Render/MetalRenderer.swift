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
///
/// Strategy: always present the newest frame. If frames arrive faster than
/// the display can consume them, older frames are silently replaced.
/// The renderer is intentionally simple — bandwidth adaptation belongs
/// on the Mac encoder/transport side, not here.
final class MetalRenderer: NSObject {

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

    /// Current BGRA frame texture received from the decode pipeline.
    /// Updated atomically on the frame delivery thread; read on the render thread.
    private var frameTexture: MTLTexture?
    private let textureLock = NSLock()

    // Render-cadence diagnostics (RENDER-CADENCE, logged once per second from the display link).
    // Arrivals and upload time are written under textureLock; the rest only on the link's thread.
    private var cadArrivalsSinceTick = 0        // frames handed in since the last callback (textureLock)
    private var cadUploadMaxMs = 0.0            // longest updateFrame texture copy this window (textureLock)
    private var cadWindowStart: CFTimeInterval = 0
    private var cadLastTick: CFTimeInterval = 0
    private var cadTicks = 0
    private var cadMaxGapMs = 0.0
    private var cadArr0 = 0, cadArr1 = 0, cadArr2Plus = 0
    private var cadSemWaitMaxMs = 0.0
    private var cadCallbackMaxMs = 0.0
    private var cadLateTicks = 0                // gap > 1.5 refresh intervals (missed vsync)

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

    /// Callback fired when a frame leaves the renderer for a render pass.
    var onFrameDequeuedForRender: ((_ captureTimestampUs: UInt64,
                                    _ enqueuedAtUs: UInt64,
                                    _ dequeuedAtUs: UInt64,
                                    _ queueDelayMs: Double,
                                    _ pendingBefore: Int,
                                    _ pendingAfter: Int,
                                    _ mode: String) -> Void)?

    /// Callback fired when GPU work for a rendered frame completes.
    var onFrameRenderCompleted: ((_ captureTimestampUs: UInt64,
                                  _ completionUs: UInt64,
                                  _ queueDelayMs: Double,
                                  _ gpuRoundtripMs: Double,
                                  _ mode: String) -> Void)?

    /// Dirty flag: set when updateFrame uploads new pixel data, cleared after render.
    private var frameDirty = false

    /// Capture timestamp (Mac host-time microseconds) of the current frame texture.
    private var frameCaptureTimestampUs: UInt64 = 0

    /// Host-time microseconds when the current frame was enqueued.
    private var frameEnqueuedAtUs: UInt64 = 0

    /// Retain the CVMetalTexture ref so the IOSurface-backed texture stays valid until rendered.
    private var cvTextureRef: CVMetalTexture?

    /// Count of decoded frames that replaced a previous frame before the display
    /// link consumed it. This quantifies render-path coalescing under load.
    private var overwrittenFrameCount = 0

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
    func setup(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer

        // Configure layer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm

        // P3 wide color gamut (RD-REND-02)
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        // Triple buffering: 3 drawables in rotation (RD-REND-03)
        metalLayer.maximumDrawableCount = 3

        metalLayer.framebufferOnly = true

        // Create display link (RD-REND-01)
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self

        // Prefer high frame rate for ProMotion 120Hz.
        // CADisableMinimumFrameDuration=YES in Info.plist enables this.
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
    func updateFrame(_ data: UnsafeRawPointer, width: Int, height: Int, captureTimestampUs: UInt64 = 0) {
        textureLock.lock()
        defer { textureLock.unlock() }

        if frameDirty { overwrittenFrameCount += 1 }
        cadArrivalsSinceTick += 1
        let uploadStart = CACurrentMediaTime()
        frameCaptureTimestampUs = captureTimestampUs
        frameEnqueuedAtUs = UInt64(uploadStart * 1_000_000.0)

        // Recreate texture if dimensions changed
        if frameTexture == nil
            || frameTexture!.width != width
            || frameTexture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            frameTexture = device.makeTexture(descriptor: descriptor)
        }

        // Upload pixel data to texture
        let bytesPerRow = width * 4
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        frameTexture?.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        cvTextureRef = nil
        frameDirty = true
        cadUploadMaxMs = max(cadUploadMaxMs, (CACurrentMediaTime() - uploadStart) * 1000.0)
    }

    /// Zero-copy frame update from CVPixelBuffer (HEVC decode output).
    ///
    /// Uses CVMetalTextureCache to create an MTLTexture backed by the pixel buffer's
    /// IOSurface — no CPU→GPU memcpy.
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

        textureLock.lock()
        if frameDirty { overwrittenFrameCount += 1 }
        cadArrivalsSinceTick += 1
        frameTexture = texture
        cvTextureRef = cvTex  // retain so IOSurface stays valid until next frame
        frameCaptureTimestampUs = captureTimestampUs
        frameEnqueuedAtUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
        frameDirty = true
        textureLock.unlock()
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
    func computeViewport(screenBounds: CGRect) {
        guard macDisplayWidth > 0, macDisplayHeight > 0 else {
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
            ndcX = -1.0
            ndcW = 2.0
            let scale = screenAspect / macAspect
            ndcH = 2.0 * scale
            ndcY = -scale
        } else if macAspect < screenAspect {
            ndcY = -1.0
            ndcH = 2.0
            let scale = macAspect / screenAspect
            ndcW = 2.0 * scale
            ndcX = -scale
        } else {
            ndcX = -1.0
            ndcY = -1.0
            ndcW = 2.0
            ndcH = 2.0
        }

        viewportUniforms.viewport = SIMD4<Float>(ndcX, ndcY, ndcW, ndcH)
    }

    /// Handle orientation or bounds change.
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
            hasPendingFrame: frameDirty,
            pendingDepth: frameDirty ? 1 : 0,
            adaptiveCatchupCount: 0,
            adaptiveCatchupDropFrames: 0,
            adaptiveSoftCatchupCount: 0,
            adaptiveHardCatchupCount: 0,
            adaptiveSoftCatchupDropFrames: 0,
            adaptiveHardCatchupDropFrames: 0
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

    /// One display-link callback finished: bucket arrivals since the previous callback and
    /// print a RENDER-CADENCE line once per second. Runs on the display link's thread.
    fileprivate func recordCadenceTick(start: CFTimeInterval, semWaitMs: Double) {
        let now = CACurrentMediaTime()
        textureLock.lock()
        let arrivals = cadArrivalsSinceTick
        cadArrivalsSinceTick = 0
        let uploadMax = cadUploadMaxMs
        textureLock.unlock()

        if cadWindowStart == 0 { cadWindowStart = start }
        if cadLastTick > 0 {
            let gapMs = (start - cadLastTick) * 1000.0
            cadMaxGapMs = max(cadMaxGapMs, gapMs)
            if gapMs > 12.5 { cadLateTicks += 1 }   // > 1.5 x 8.33 ms
        }
        cadLastTick = start
        cadTicks += 1
        switch arrivals {
        case 0: cadArr0 += 1
        case 1: cadArr1 += 1
        default: cadArr2Plus += 1
        }
        cadSemWaitMaxMs = max(cadSemWaitMaxMs, semWaitMs)
        cadCallbackMaxMs = max(cadCallbackMaxMs, (now - start) * 1000.0)

        if now - cadWindowStart >= 1.0 {
            print("[CONSOLE] RENDER-CADENCE ticks=\(cadTicks) late=\(cadLateTicks) maxGapMs=\(String(format: "%.1f", cadMaxGapMs)) arrivals0/1/2+=\(cadArr0)/\(cadArr1)/\(cadArr2Plus) semWaitMaxMs=\(String(format: "%.1f", cadSemWaitMaxMs)) callbackMaxMs=\(String(format: "%.1f", cadCallbackMaxMs)) uploadMaxMs=\(String(format: "%.1f", uploadMax)) thread=\(Thread.isMainThread ? "main" : "other")")
            cadWindowStart = now
            cadTicks = 0; cadLateTicks = 0; cadMaxGapMs = 0
            cadArr0 = 0; cadArr1 = 0; cadArr2Plus = 0
            cadSemWaitMaxMs = 0; cadCallbackMaxMs = 0
            textureLock.lock(); cadUploadMaxMs = 0; textureLock.unlock()
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink,
                          needsUpdate update: CAMetalDisplayLink.Update) {
        let tickStart = CACurrentMediaTime()
        // Wait for an available in-flight slot (triple buffering)
        inflightSemaphore.wait()
        let semWaitMs = (CACurrentMediaTime() - tickStart) * 1000.0
        defer { recordCadenceTick(start: tickStart, semWaitMs: semWaitMs) }

        let drawable = update.drawable

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1
        )
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            inflightSemaphore.signal()
            return
        }

        // Snapshot the texture/timestamp/dirty bit atomically
        let dequeueNowUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
        textureLock.lock()
        let currentTexture = frameTexture
        let currentCaptureTimestampUs = frameCaptureTimestampUs
        let currentEnqueuedAtUs = frameEnqueuedAtUs
        let hasNewFrame = frameDirty
        let retainedCVTexture = cvTextureRef
        if hasNewFrame {
            frameDirty = false
        }
        textureLock.unlock()

        if let texture = currentTexture {
            encoder.setRenderPipelineState(pipelineState)

            var uniforms = viewportUniforms
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<ViewportUniforms>.size,
                index: 0
            )

            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if hasNewFrame {
                renderedFrameCount += 1
                renderedFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
                onFrameRendered?()

                let queueDelayMs = Double(dequeueNowUs &- currentEnqueuedAtUs) / 1000.0
                onFrameDequeuedForRender?(currentCaptureTimestampUs,
                                          currentEnqueuedAtUs,
                                          dequeueNowUs,
                                          queueDelayMs,
                                          1, // pendingBefore
                                          0, // pendingAfter
                                          "newest")

                encoder.endEncoding()
                commandBuffer.present(drawable)

                // Glass-to-glass timing
                if currentCaptureTimestampUs > 0 {
                    let targetPresentation = update.targetPresentationTimestamp
                    if targetPresentation > 0 {
                        let presentedHostTimeUs = Int64(targetPresentation * 1_000_000)
                        onFramePresented?(currentCaptureTimestampUs, presentedHostTimeUs)
                    }
                }

                let submitUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
                commandBuffer.addCompletedHandler { [weak self, retainedCVTexture] _ in
                    _ = retainedCVTexture
                    let completionUs = UInt64(CACurrentMediaTime() * 1_000_000.0)
                    let gpuRoundtripMs = Double(completionUs &- submitUs) / 1000.0
                    self?.onFrameRenderCompleted?(currentCaptureTimestampUs,
                                                  completionUs,
                                                  queueDelayMs,
                                                  gpuRoundtripMs,
                                                  "newest")
                    self?.inflightSemaphore.signal()
                }

                commandBuffer.commit()
                return
            }
        }

        // No new frame — still present stale content
        encoder.endEncoding()
        commandBuffer.present(drawable)

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        commandBuffer.commit()
    }
}
