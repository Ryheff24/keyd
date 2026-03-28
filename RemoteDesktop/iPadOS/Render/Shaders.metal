#include <metal_stdlib>
using namespace metal;

// MARK: - Types

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float4 viewport; // x, y, width, height in NDC [-1, 1]
};

// MARK: - Vertex Shader

/// Full-screen quad via triangle strip (4 vertices, 2 triangles).
/// Vertex positions are mapped to the viewport rect (NDC) for letterboxing.
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                              constant Uniforms &uniforms [[buffer(0)]]) {
    // Unit-space quad positions: (0,0) top-left to (1,1) bottom-right
    float2 unitPositions[4] = {
        float2(0.0, 0.0), // top-left
        float2(1.0, 0.0), // top-right
        float2(0.0, 1.0), // bottom-left
        float2(1.0, 1.0), // bottom-right
    };

    float2 texCoords[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };

    float2 unit = unitPositions[vertexID];

    // Map unit position [0,1] to viewport rect in NDC [-1,1]
    float2 ndc;
    ndc.x = uniforms.viewport.x + unit.x * uniforms.viewport.z;
    ndc.y = uniforms.viewport.y + unit.y * uniforms.viewport.w;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Fragment Shader

/// Samples from BGRA frame texture. Channel swizzle is handled automatically
/// by the bgra8Unorm pixel format on the MTLTexture — shader samples normally.
/// P3 color space is set on the CAMetalLayer, not in the shader.
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> frameTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);
    return frameTexture.sample(textureSampler, in.texCoord);
}
