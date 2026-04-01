#!/usr/bin/env swift

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

struct Config {
    var outputPath: String = "/tmp/keydrd-capture-mimic.mov"
    var width: Int = 0
    var height: Int = 0
    var fps: Int = 120
    var duration: Double = 20.0
    var codec: AVVideoCodecType = .h264
}

enum ConfigError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case .invalidValue(let message):
            return message
        }
    }
}

func detectMainDisplayPixels() -> (width: Int, height: Int)? {
    let displayID = CGMainDisplayID()
    guard let mode = CGDisplayCopyDisplayMode(displayID) else {
        return nil
    }
    return (width: mode.pixelWidth, height: mode.pixelHeight)
}

func parseArgs() throws -> Config {
    var config = Config()
    let args = Array(CommandLine.arguments.dropFirst())
    var idx = 0

    while idx < args.count {
        let arg = args[idx]
        switch arg {
        case "--output":
            idx += 1
            guard idx < args.count else {
                throw ConfigError.invalidValue("missing value for --output")
            }
            config.outputPath = args[idx]
        case "--width":
            idx += 1
            guard idx < args.count, let value = Int(args[idx]), value > 0 else {
                throw ConfigError.invalidValue("invalid --width")
            }
            config.width = value
        case "--height":
            idx += 1
            guard idx < args.count, let value = Int(args[idx]), value > 0 else {
                throw ConfigError.invalidValue("invalid --height")
            }
            config.height = value
        case "--fps":
            idx += 1
            guard idx < args.count, let value = Int(args[idx]), value > 0 else {
                throw ConfigError.invalidValue("invalid --fps")
            }
            config.fps = value
        case "--duration":
            idx += 1
            guard idx < args.count, let value = Double(args[idx]), value > 0 else {
                throw ConfigError.invalidValue("invalid --duration")
            }
            config.duration = value
        case "--codec":
            idx += 1
            guard idx < args.count else {
                throw ConfigError.invalidValue("missing value for --codec")
            }
            switch args[idx].lowercased() {
            case "h264":
                config.codec = .h264
            case "hevc", "h265":
                config.codec = .hevc
            default:
                throw ConfigError.invalidValue("unsupported --codec \(args[idx]); use h264 or hevc")
            }
        case "--help", "-h":
            throw ConfigError.invalidValue("""
            usage: generate-stress-video.swift [--output /tmp/keydrd-capture-mimic.mov] [--width 3600 --height 2338 --fps 120 --duration 20 --codec h264]
            defaults: native main-display resolution, 120 fps, 20 seconds, /tmp/keydrd-capture-mimic.mov
            """)
        default:
            throw ConfigError.invalidValue("unknown argument: \(arg)")
        }
        idx += 1
    }

    if config.width == 0 || config.height == 0 {
        let detected = detectMainDisplayPixels() ?? (1920, 1080)
        if config.width == 0 { config.width = detected.width }
        if config.height == 0 { config.height = detected.height }
    }

    return config
}

func makeColor(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func hash32(_ x: UInt32) -> UInt32 {
    var v = x
    v ^= v >> 16
    v &*= 0x7feb352d
    v ^= v >> 15
    v &*= 0x846ca68b
    v ^= v >> 16
    return v
}

func drawPseudoTextRows(ctx: CGContext, width: Int, height: Int, time: Double) {
    let rows = 18
    let baseY = Double(height) * 0.10
    let lineHeight = Double(height) * 0.035

    for row in 0..<rows {
        let y = baseY + Double(row) * lineHeight
        let segmentCount = 18
        for segment in 0..<segmentCount {
            let seed = hash32(UInt32(row * 257 + segment * 131 + Int(time * 60.0)))
            let segWidth = Double(width) * (0.018 + Double(seed & 0xff) / 255.0 * 0.06)
            let x = Double(width) * 0.05 + Double(segment) * Double(width) * 0.05 + Double((seed >> 8) & 0x1f)
            let alpha = 0.3 + Double((seed >> 16) & 0xff) / 255.0 * 0.45
            ctx.setFillColor(makeColor(0.94, 0.95, 0.98, alpha))
            ctx.fill(CGRect(x: x, y: y, width: segWidth, height: 3.0))
        }
    }
}

func drawWindowGrid(ctx: CGContext, width: Int, height: Int, time: Double) {
    let cols = 4
    let rows = 3
    let gap = Double(width) * 0.016
    let totalGapX = gap * Double(cols + 1)
    let totalGapY = gap * Double(rows + 1)
    let tileW = (Double(width) - totalGapX) / Double(cols)
    let tileH = (Double(height) - totalGapY) / Double(rows)

    for row in 0..<rows {
        for col in 0..<cols {
            let x = gap + Double(col) * (tileW + gap)
            let y = gap + Double(row) * (tileH + gap)
            let phase = time * 0.9 + Double(row) * 0.7 + Double(col) * 0.5
            let baseR = 0.15 + 0.12 * sin(phase)
            let baseG = 0.14 + 0.12 * cos(phase * 1.2)
            let baseB = 0.18 + 0.14 * sin(phase * 0.8 + 1.0)
            let rect = CGRect(x: x, y: y, width: tileW, height: tileH)

            ctx.setFillColor(makeColor(baseR, baseG, baseB, 1.0))
            ctx.fill(rect)
            ctx.setStrokeColor(makeColor(0.92, 0.96, 1.0, 0.85))
            ctx.setLineWidth(6.0)
            ctx.stroke(rect.insetBy(dx: 4.0, dy: 4.0))

            let headerHeight = tileH * 0.12
            ctx.setFillColor(makeColor(0.88, 0.9, 0.96, 0.75))
            ctx.fill(CGRect(x: x, y: y + tileH - headerHeight, width: tileW, height: headerHeight))

            drawPseudoTextRows(ctx: ctx, width: Int(tileW), height: Int(tileH), time: time + Double(row + col))

            let panelX = x + tileW * (0.1 + 0.4 * (0.5 + 0.5 * sin(time * 1.4 + Double(col))))
            let panelY = y + tileH * (0.18 + 0.38 * (0.5 + 0.5 * cos(time * 1.1 + Double(row))))
            let panelW = tileW * 0.22
            let panelH = tileH * 0.26
            ctx.setFillColor(makeColor(0.97, 0.54, 0.18, 0.88))
            ctx.fill(CGRect(x: panelX, y: panelY, width: panelW, height: panelH))
        }
    }
}

func drawStripeBurst(ctx: CGContext, width: Int, height: Int, frameIndex: Int) {
    let stripeCount = 64
    let barWidth = Double(width) / Double(stripeCount)
    for idx in 0..<stripeCount {
        let seed = hash32(UInt32(frameIndex * 4099 + idx * 131))
        let r = Double(seed & 0xff) / 255.0
        let g = Double((seed >> 8) & 0xff) / 255.0
        let b = Double((seed >> 16) & 0xff) / 255.0
        ctx.setFillColor(makeColor(r, g, b, 0.92))
        ctx.fill(CGRect(x: Double(idx) * barWidth, y: 0, width: ceil(barWidth), height: Double(height)))
    }

    let horizontalCount = 28
    let barHeight = Double(height) / Double(horizontalCount)
    for idx in 0..<horizontalCount {
        let seed = hash32(UInt32(frameIndex * 1237 + idx * 197))
        let alpha = 0.15 + Double(seed & 0xff) / 255.0 * 0.35
        ctx.setFillColor(makeColor(1.0, 1.0, 1.0, alpha))
        ctx.fill(CGRect(x: 0, y: Double(idx) * barHeight, width: Double(width), height: max(2.0, barHeight * 0.12)))
    }
}

func drawNoisePhase(pixelBuffer: CVPixelBuffer, frameIndex: Int) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return }

    let t = UInt32(frameIndex)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow)
        for x in 0..<width {
            let seed = hash32(UInt32(x * 31337 + y * 92821) ^ (t &* 0x9e3779b9))
            let offset = x * 4
            row[offset + 0] = UInt8(truncatingIfNeeded: seed)
            row[offset + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            row[offset + 2] = UInt8(truncatingIfNeeded: seed >> 16)
            row[offset + 3] = 0xff
        }
    }
}

func fillCaptureMimicFrame(pixelBuffer: CVPixelBuffer, frameIndex: Int, config: Config) {
    let phaseDuration = max(4.0, config.duration / 4.0)
    let time = Double(frameIndex) / Double(config.fps)
    let phase = Int(time / phaseDuration) % 4

    if phase == 3 {
        drawNoisePhase(pixelBuffer: pixelBuffer, frameIndex: frameIndex)
        return
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: base,
                              width: width,
                              height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue) else {
        return
    }

    let flash = (frameIndex / max(config.fps / 2, 1)) % 2 == 0 ? 0.0 : 0.18
    ctx.setFillColor(makeColor(0.03 + flash, 0.04 + flash * 0.5, 0.06 + flash * 0.2, 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    switch phase {
    case 0:
        let cols = 5
        let rows = 3
        let tileW = Double(width) / Double(cols)
        let tileH = Double(height) / Double(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let phaseT = time * 0.8 + Double(row) * 0.3 + Double(col) * 0.17
                let r = 0.22 + 0.45 * (0.5 + 0.5 * sin(phaseT * 1.7))
                let g = 0.18 + 0.46 * (0.5 + 0.5 * cos(phaseT * 1.3))
                let b = 0.20 + 0.48 * (0.5 + 0.5 * sin(phaseT * 1.1 + 1.3))
                let rect = CGRect(x: Double(col) * tileW + 12.0,
                                  y: Double(row) * tileH + 12.0,
                                  width: tileW - 24.0,
                                  height: tileH - 24.0)
                ctx.setFillColor(makeColor(r, g, b, 1.0))
                ctx.fill(rect)
                ctx.setStrokeColor(makeColor(0.95, 0.98, 1.0, 0.85))
                ctx.setLineWidth(8.0)
                ctx.stroke(rect.insetBy(dx: 6.0, dy: 6.0))
            }
        }
        let sweepX = fmod(time * Double(width) * 0.31, Double(width) + Double(width) * 0.25) - Double(width) * 0.12
        ctx.setFillColor(makeColor(1.0, 1.0, 1.0, 0.16))
        ctx.fill(CGRect(x: sweepX, y: 0, width: Double(width) * 0.22, height: Double(height)))
    case 1:
        drawWindowGrid(ctx: ctx, width: width, height: height, time: time)
    case 2:
        drawStripeBurst(ctx: ctx, width: width, height: height, frameIndex: frameIndex)
        let squareCount = 36
        let squareSize = Double(min(width, height)) * 0.07
        for idx in 0..<squareCount {
            let seed = hash32(UInt32(frameIndex * 97 + idx * 131))
            let x = Double(seed % UInt32(max(width - Int(squareSize), 1)))
            let y = Double((seed >> 8) % UInt32(max(height - Int(squareSize), 1)))
            let r = Double((seed >> 16) & 0xff) / 255.0
            let g = Double((seed >> 8) & 0xff) / 255.0
            let b = Double(seed & 0xff) / 255.0
            ctx.setFillColor(makeColor(r, g, b, 0.85))
            ctx.fill(CGRect(x: x, y: y, width: squareSize, height: squareSize))
        }
    default:
        break
    }
}

func makeWriter(config: Config) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
    let outputURL = URL(fileURLWithPath: config.outputPath)
    try? FileManager.default.removeItem(at: outputURL)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: config.codec,
        AVVideoWidthKey: config.width,
        AVVideoHeightKey: config.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: config.width * config.height * 10,
            AVVideoMaxKeyFrameIntervalKey: config.fps,
            AVVideoExpectedSourceFrameRateKey: config.fps,
        ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: config.width,
        kCVPixelBufferHeightKey as String: config.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: attributes)

    guard writer.canAdd(input) else {
        throw ConfigError.invalidValue("failed to attach AVAssetWriterInput")
    }
    writer.add(input)
    return (writer, input, adaptor)
}

let config: Config
do {
    config = try parseArgs()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}

let totalFrames = Int((Double(config.fps) * config.duration).rounded(.toNearestOrAwayFromZero))
guard totalFrames > 0 else {
    fputs("error: total frame count is zero\n", stderr)
    exit(1)
}

do {
    let (writer, input, adaptor) = try makeWriter(config: config)
    guard writer.startWriting() else {
        throw writer.error ?? ConfigError.invalidValue("failed to start writing")
    }
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool else {
        throw ConfigError.invalidValue("pixel buffer pool unavailable")
    }

    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps))

    for frameIndex in 0..<totalFrames {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ConfigError.invalidValue("failed to allocate frame \(frameIndex)")
        }

        fillCaptureMimicFrame(pixelBuffer: pixelBuffer, frameIndex: frameIndex, config: config)
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            throw writer.error ?? ConfigError.invalidValue("failed to append frame \(frameIndex)")
        }

        if frameIndex == 0 || frameIndex == totalFrames - 1 || frameIndex % max(config.fps, 1) == 0 {
            let percent = Int((Double(frameIndex + 1) / Double(totalFrames)) * 100.0)
            print("progress: \(percent)% (\(frameIndex + 1)/\(totalFrames))")
        }
    }

    input.markAsFinished()
    writer.finishWriting {
        if writer.status == .completed {
            print("wrote \(config.outputPath)")
            print("ready:")
            print("./RemoteDesktop/scripts/run-e2e-tests.sh 180 --wired-only --transport usb --capture-file \(config.outputPath)")
        } else {
            fputs("error: \(writer.error?.localizedDescription ?? "writer failed")\n", stderr)
            exit(1)
        }
    }

    while writer.status == .writing {
        Thread.sleep(forTimeInterval: 0.05)
    }

    if writer.status != .completed {
        throw writer.error ?? ConfigError.invalidValue("writer ended with status \(writer.status.rawValue)")
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
