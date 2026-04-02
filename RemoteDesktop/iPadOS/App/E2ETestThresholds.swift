import Foundation

enum E2ETestThresholds {
    enum Resolution {
        static let minGeometryWidthScale = 0.90
        static let minGeometryHeightScale = 0.90
        static let minFrameWidthScale = 0.90
        static let minFrameHeightScale = 0.90
    }

    enum FPS {
        static let minAverageFPS = 60.0
        static let minOnePercentLowFPS = 30.0
        static let maxJitterMs = 16.0
        static let maxStutterPercent = 5.0
        static let maxGapMs = 200.0
        static let minWorstOneSecondFPS = 5.0
        static let minFrameCount = 20
    }

    enum FramePacing {
        static let maxCoefficientOfVariation = 0.350
    }

    enum FrameLoss {
        static let maxLossPercent = 10.0
        static let minRenderedFrames = 10
    }

    enum Throughput {
        static let minAverageFPS = 5.0
        static let minFrameCount = 10
    }

    enum PipelineLatency {
        static let minSamples = 50
        static let maxMedianMs: Int64 = 20
        static let maxAverageMs: Int64 = 25
        static let maxP95Ms: Int64 = 50
    }

    enum GlassToGlassLatency {
        static let minSamples = 50
        static let maxMedianMs: Int64 = 30
        static let maxAverageMs: Int64 = 40
        static let maxP95Ms: Int64 = 60
    }

    enum HeavyLoad {
        static let minAverageFPS = 60.0
        static let maxPipelineMedianMs: Int64 = 30
        static let maxPipelineAverageMs: Int64 = 35
        static let maxPipelineP95Ms: Int64 = 50
    }

    enum SustainedStream {
        static let minAverageFPS = 60.0
        static let minOnePercentLowFPS = 30.0
        static let maxJitterMs = 20.0
        static let minFramesPerSecond = 10.0
        static let maxReconnects = 0
        static let maxGapMs = 500.0
        static let minWorstOneSecondFPS = 10.0
        static let minimumFrameCount = 20
        static let maxPipelineMedianMs: Int64 = 20
        static let maxPipelineAverageMs: Int64 = 25
        static let maxPipelineP95Ms: Int64 = 50
        static let maxGlassMedianMs: Int64 = 30
        static let maxGlassAverageMs: Int64 = 40
        static let maxGlassP95Ms: Int64 = 60
    }
}
