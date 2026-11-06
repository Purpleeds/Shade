#include <metal_stdlib>
using namespace metal;

// Final pass: draws the processed frame into the screen (aspect fill) or into a capture texture.

struct DisplayVOut {
    float4 position [[position]];
    float2 uv;
};

struct DisplayUniforms {
    float2 scale;
    float2 offset;
};

vertex DisplayVOut display_vertex(uint vid [[vertex_id]]) {
    float2 pos = float2(float((vid << 1) & 2u), float(vid & 2u));
    DisplayVOut o;
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(pos.x, 1.0 - pos.y);
    return o;
}

fragment float4 display_fragment(DisplayVOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant DisplayUniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv * u.scale + u.offset;
    return float4(saturate(tex.sample(s, uv).rgb), 1.0);
}
