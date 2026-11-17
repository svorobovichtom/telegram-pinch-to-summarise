#include <metal_stdlib>
using namespace metal;

// The liquid layer of the timeline: rounded rects merged with a smooth minimum of their signed distances. A shape is
// either a solid color (a message bubble's fill) or Telegram's service material (the date pill look); where shapes
// blend, so do their colors. Shapes of one group (the bubbles of a day flowing into that day's bubble) merge with
// `groupK`. Groups merge with each other with `gooK`, which is 0 at rest and swells mid-transition, so neighbours
// briefly flow together and pull apart again.

struct GooShape {
    float4 rect;     // minX, minY, maxX, maxY, in points
    float radius;
    float shrink;    // grows the distance: 0 = the full shape, >= half its height = gone
    uint group;
    float pad;
    float4 color;    // alpha 0: the service material
};

struct GooUniforms {
    float2 size;     // points
    float scale;     // pixels per point
    uint count;
    float groupK;
    float gooK;
    float4 dim;      // service dim, straight alpha
    float4 flat;     // Night: the flat service fill
    uint hasTexture; // Day: the wallpaper gradient at saturation 1.7, seen through the shape
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut gooVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float roundedRect(float2 p, float4 r, float radius) {
    float2 center = (r.xy + r.zw) * 0.5;
    float2 half_ = max((r.zw - r.xy) * 0.5, float2(0.0));
    float rr = min(radius, min(half_.x, half_.y));
    float2 q = abs(p - center) - half_ + rr;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
}

static float smin(float a, float b, float k) {
    if (k <= 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

fragment half4 gooFragment(VertexOut in [[stage_in]],
                           constant GooUniforms &u [[buffer(0)]],
                           const device GooShape *shapes [[buffer(1)]],
                           texture2d<float> gradient [[texture(0)]],
                           sampler gradientSampler [[sampler(0)]]) {
    float2 p = in.position.xy / u.scale;
    float3 base = u.flat.rgb;
    if (u.hasTexture != 0) {
        base = gradient.sample(gradientSampler, p / u.size).rgb;
    }
    float3 material = mix(base, u.dim.rgb, u.dim.a);
    float3 colorSum = float3(0.0);
    float weightSum = 0.0;
    float reach = max(max(u.groupK, u.gooK), 10.0) + 1.0;
    float total = 1e4;
    float group = 1e4;
    uint current = 0xffffffffu;
    for (uint i = 0; i < u.count; i++) {
        GooShape s = shapes[i];
        float d = 1e4;
        // Cheap reject: a pixel this far from the box can't be inside it or in its blend.
        if (p.x > s.rect.x - reach && p.x < s.rect.z + reach && p.y > s.rect.y - reach && p.y < s.rect.w + reach) {
            d = roundedRect(p, s.rect, s.radius) + s.shrink;
            // Colors mix over the last 10pt around each shape.
            float w = clamp(1.0 - d / 10.0, 0.0, 1.0);
            w *= w;
            colorSum += (s.color.a > 0.0 ? s.color.rgb : material) * w;
            weightSum += w;
        }
        if (s.group != current) {
            total = smin(total, group, u.gooK);
            group = d;
            current = s.group;
        } else {
            group = smin(group, d, u.groupK);
        }
    }
    total = smin(total, group, u.gooK);
    float alpha = clamp(0.5 - total * u.scale, 0.0, 1.0);
    if (alpha <= 0.0) { return half4(0.0); }

    float3 color = weightSum > 0.0 ? colorSum / weightSum : material;
    return half4(half3(color * alpha), half(alpha));
}
