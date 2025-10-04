#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex VertexOut vertex_main(
    uint vertexID [[vertex_id]],
    const device VertexIn *vertices [[buffer(0)]]
) {
    VertexIn inVertex = vertices[vertexID];
    VertexOut out;
    out.position = float4(inVertex.position, 0.0, 1.0);
    out.texCoord = inVertex.texCoord;
    out.color = inVertex.color;
    return out;
}

fragment float4 fragment_textured(
    VertexOut in [[stage_in]],
    texture2d<float> colorTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
    float4 tex = colorTexture.sample(textureSampler, in.texCoord);
    return tex * in.color;
}

fragment float4 fragment_color(VertexOut in [[stage_in]]) {
    return in.color;
}
