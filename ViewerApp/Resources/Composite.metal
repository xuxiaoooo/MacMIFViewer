#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct ChannelUniform {
    float4 color;
    float4 mapping; // normalized min, max, exponent, visible brightness gain
};

vertex VertexOut slide_vertex(uint i [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[i].xy, 0.0, 1.0);
    out.uv = vertices[i].zw;
    return out;
}

fragment float4 slide_fragment(VertexOut in [[stage_in]],
    array<texture2d<float>, 8> channels [[texture(0)]],
    constant ChannelUniform *style [[buffer(0)]]) {
    constexpr sampler lookup(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 rgb = 0;
    for (uint i = 0; i < 8; i++) {
        float4 transform = style[i].mapping;
        if (transform.w > 0.0) {
            float sample = channels[i].sample(lookup, in.uv).r;
            float scaled = clamp((sample - transform.x) / (transform.y - transform.x), 0.0, 1.0);
            float intensity = pow(scaled, transform.z);
            float4 palette = style[i].color;
            float3 channel;
            if (palette.w == 1.0) channel = float3(intensity);
            else if (palette.w == 2.0) channel = saturate(3.0 * intensity - float3(0, 1, 2));
            else channel = palette.rgb * intensity;
            channel *= transform.w;
            rgb += channel / max(1.0, max(channel.r, max(channel.g, channel.b)));
        }
    }
    return float4(saturate(rgb), 1.0);
}
