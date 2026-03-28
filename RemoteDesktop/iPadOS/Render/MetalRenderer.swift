import Metal
import MetalKit
import QuartzCore

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

    /// Mac display dimensions, set during session handshake.
    /// Used for aspect ratio computation and texture sizing.
    private(set) var macDisplayWidth: Int = 0
    private(set) var macDisplayHeight: Int = 0

    /// Computed letterbox viewport in NDC coordinates.
    private var viewportUniforms = ViewportUniforms(viewport: SIMD4<Float>(-1, -1, 2, 2))

    /// The CAMetalLayer this renderer draws to.
    private weak var metalLayer: CAMetalLayer?

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

        // Prefer high frame rate for ProMotion 120Hz
        // CADisableMinimumFrameDuration=YES in Info.plist enables this
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
    func updateFrame(_ data: UnsafeRawPointer, width: Int, height: Int) {
        textureLock.lock()
        defer { textureLock.unlock() }

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
        // Step 1: Wait for an available in-flight slot (triple buffering)
        inflightSemaphore.wait()

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

        // Only render if we have a frame texture
        textureLock.lock()
        let currentTexture = frameTexture
        textureLock.unlock()

        if let texture = currentTexture {
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
            encoder.setFragmentTexture(texture, index: 0)

            // Step 7: Draw triangle strip (4 vertices = full-screen quad)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Step 8: End encoding
        encoder.endEncoding()

        // Step 9: Present drawable
        commandBuffer.present(drawable)

        // Step 10: Signal semaphore on completion (triple buffering)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        // Step 11: Commit
        commandBuffer.commit()
    }
}
