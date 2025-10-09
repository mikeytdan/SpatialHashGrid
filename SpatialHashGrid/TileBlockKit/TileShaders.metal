// File: TileBlockKit/TileShaders.metal
#include <metal_stdlib>
using namespace metal;

struct QuadVertex { float2 pos; float2 uv01; };
struct TileInstance {
    float2 originPx;
    float2 sizePx;
    float4 uvRect;
    float4 tint;
    uint   effectMask;
    uint   shapeKind;
};
struct Uniforms {
    float2 viewportSizePx;
    float  bevelWidth;
    float  cornerRadius;
    float  outlineWidth;
    float  outlineIntensity;
    float  shadowSize;
    float2 tilePx;
    float2 pad0;
    float  stripeAngle;
    float  stripeWidth;
    float4 stripeA;
    float4 stripeB;
    uint   highlightMask;
    uint   shadowMask;
    uint   lightingMode;
    uint   padLighting;
    float  highlightIntensity;
    float  shadowIntensity;
    float  edgeFalloff;
    float  hueShift;
    float  saturation;
    float  brightness;
    float  contrast;
    float4 highlightColor;
    float4 shadowColor;
};
struct VSOut {
    float4 position [[position]];
    float2 uvAtlas;
    float2 uvLocal;
    float4 tint;
    uint   effectMask;
    uint   shapeKind;
    float2 fragSizePx;
};

vertex VSOut tileVertex(const device QuadVertex* verts [[buffer(0)]],
                        const device TileInstance* inst  [[buffer(1)]],
                        constant Uniforms& uni [[buffer(2)]],
                        uint vid [[vertex_id]],
                        uint iid [[instance_id]])
{
    QuadVertex v = verts[vid];
    TileInstance ti = inst[iid];
    float2 pixelPos = ti.originPx + v.pos * ti.sizePx;
    float2 ndc;
    ndc.x = (pixelPos.x / uni.viewportSizePx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixelPos.y / uni.viewportSizePx.y) * 2.0;

    VSOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.uvAtlas  = ti.uvRect.xy + v.uv01 * ti.uvRect.zw;
    o.uvLocal  = v.uv01;
    o.tint     = ti.tint;
    o.effectMask = ti.effectMask;
    o.shapeKind  = ti.shapeKind;
    o.fragSizePx = ti.sizePx;
    return o;
}

float edgeDist(float2 p) {
    return min(min(p.x, p.y), min(1.0 - p.x, 1.0 - p.y));
}

float roundedMask(float2 p, float r) {
    if (r <= 0.0001) return 1.0;
    float2 tl = float2(r, r);
    float2 tr = float2(1.0 - r, r);
    float2 bl = float2(r, 1.0 - r);
    float2 br = float2(1.0 - r, 1.0 - r);
    float m = 1.0;
    if (p.x < r && p.y < r)      m = smoothstep(r, r-0.01, length(p - tl));
    else if (p.x > 1.0 - r && p.y < r) m = smoothstep(r, r-0.01, length(p - tr));
    else if (p.x < r && p.y > 1.0 - r) m = smoothstep(r, r-0.01, length(p - bl));
    else if (p.x > 1.0 - r && p.y > 1.0 - r) m = smoothstep(r, r-0.01, length(p - br));
    return clamp(m, 0.0, 1.0);
}

float slopeMask(float2 p, uint kind) {
    switch (kind) {
        case 4: return step(p.x + p.y, 1.0);         // TL
        case 5: return step(p.y, p.x);               // TR
        case 6: return step(p.x, p.y);               // BL
        default: return 1.0;
    }
}
float slopeMaskBR(float2 p) { return step(1.0, p.x + p.y); }

constant uint EDGE_TOP    = 1 << 0;
constant uint EDGE_RIGHT  = 1 << 1;
constant uint EDGE_BOTTOM = 1 << 2;
constant uint EDGE_LEFT   = 1 << 3;

float3 applyLighting(float3 color, float2 uv, constant Uniforms& uni);
float3 applyColorAdjustments(float3 color, constant Uniforms& uni);

fragment float4 tileFragment(VSOut in [[stage_in]],
                             texture2d<float> atlas [[texture(0)]],
                             sampler samp [[sampler(0)]],
                             constant Uniforms& uni [[buffer(2)]])
{
    float4 base = atlas.sample(samp, in.uvAtlas);

    float mShape = 1.0;
    if (in.shapeKind >= 4 && in.shapeKind <= 7) {
        mShape = (in.shapeKind == 7) ? slopeMaskBR(in.uvLocal) : slopeMask(in.uvLocal, in.shapeKind);
    }
    float roundMaskV = roundedMask(in.uvLocal, uni.cornerRadius);

    float d = edgeDist(in.uvLocal);
    float outlineAlpha = smoothstep(uni.outlineWidth + 0.002, uni.outlineWidth, d);
    float4 outlineCol = float4(0.0, 0.0, 0.0, outlineAlpha * clamp(uni.outlineIntensity, 0.0, 1.0));

    float bevel = clamp(uni.bevelWidth, 0.0, 0.49);
    float edge = smoothstep(bevel, bevel + 0.01, d);
    float3 lit = base.rgb;
    if (in.shapeKind == 1)      lit *= (0.9 + 0.3 * edge);           // Bevel
    else if (in.shapeKind == 2) lit *= (1.1 - 0.3 * edge);           // Inset
    else if (in.shapeKind == 3) lit *= (0.8 + 0.4 * (1.0 - abs(edge - 0.5) * 2.0)); // Pillow

    lit = applyLighting(lit, in.uvLocal, uni);

    float4 over = float4(0.0);
    if ((in.effectMask & 0x1) == 0x1) { // stripes
        float ca = cos(uni.stripeAngle);
        float sa = sin(uni.stripeAngle);
        float u = in.uvLocal.x * ca + in.uvLocal.y * sa;
        float t = fract(u / max(uni.stripeWidth, 0.01));
        float sel = step(0.5, t);
        over = mix(uni.stripeA, uni.stripeB, sel);
        over.rgb *= over.a;
    }

    float shadow = 0.0;
    if ((in.effectMask & 0x2) == 0x2) {
        float px = 1.0 / max(in.fragSizePx.x, 1.0);
        float py = 1.0 / max(in.fragSizePx.y, 1.0);
        float soft = uni.shadowSize;
        float2 dir = float2(px * 3.0, py * 3.0);
        float2 p = in.uvLocal - dir;
        float s = 1.0 - roundedMask(p, uni.cornerRadius);
        shadow = smoothstep(0.0, soft, s);
    }

    float4 color = float4(lit, base.a);
    float mask = mShape * roundMaskV;
    color = mix(color, over, over.a * mask);
    color.rgb = mix(color.rgb, outlineCol.rgb, outlineCol.a * mask);
    color.rgb *= (1.0 - 0.35 * shadow);
    color.rgb = applyColorAdjustments(color.rgb, uni);
    color *= in.tint;
    color.a *= mask;
    return color;
}
float edgeFactor(float coord, float falloff) {
    return smoothstep(falloff, 0.0, coord);
}

float3 applyLighting(float3 color, float2 uv, constant Uniforms& uni) {
    if (uni.lightingMode == 1) {
        float falloff = clamp(uni.edgeFalloff, 0.0001, 0.49);
        float topHighlight = (uni.highlightMask & EDGE_TOP) ? edgeFactor(uv.y, falloff) : 0.0;
        float rightHighlight = (uni.highlightMask & EDGE_RIGHT) ? edgeFactor(1.0 - uv.x, falloff) : 0.0;
        float bottomHighlight = (uni.highlightMask & EDGE_BOTTOM) ? edgeFactor(1.0 - uv.y, falloff) : 0.0;
        float leftHighlight = (uni.highlightMask & EDGE_LEFT) ? edgeFactor(uv.x, falloff) : 0.0;
        float highlightFactor = clamp(topHighlight + rightHighlight + bottomHighlight + leftHighlight, 0.0, 1.0);

        float topShadow = (uni.shadowMask & EDGE_TOP) ? edgeFactor(uv.y, falloff) : 0.0;
        float rightShadow = (uni.shadowMask & EDGE_RIGHT) ? edgeFactor(1.0 - uv.x, falloff) : 0.0;
        float bottomShadow = (uni.shadowMask & EDGE_BOTTOM) ? edgeFactor(1.0 - uv.y, falloff) : 0.0;
        float leftShadow = (uni.shadowMask & EDGE_LEFT) ? edgeFactor(uv.x, falloff) : 0.0;
        float shadowFactor = clamp(topShadow + rightShadow + bottomShadow + leftShadow, 0.0, 1.0);

        if (highlightFactor > 0.0001) {
            float3 target = saturate(color + uni.highlightColor.rgb * uni.highlightIntensity);
            color = mix(color, target, highlightFactor);
        }
        if (shadowFactor > 0.0001) {
            float3 shadowTarget = saturate(color * (1.0 - uni.shadowIntensity) + uni.shadowColor.rgb * uni.shadowIntensity);
            color = mix(color, shadowTarget, shadowFactor);
        }
    } else if (uni.lightingMode == 2) {
        float2 centered = uv - 0.5;
        float dist = length(centered);
        float glow = smoothstep(0.5, clamp(uni.edgeFalloff + 0.2, 0.0, 0.9), dist);
        float3 glowTarget = saturate(color + uni.highlightColor.rgb * uni.highlightIntensity);
        color = mix(glowTarget, color, glow);
    }
    return color;
}

float3 applyColorAdjustments(float3 color, constant Uniforms& uni) {
    float brightness = uni.brightness;
    color = clamp(color + brightness, 0.0, 1.0);

    float saturation = max(0.0, uni.saturation);
    float luminance = dot(color, float3(0.299, 0.587, 0.114));
    color = mix(float3(luminance), color, saturation);

    float contrast = max(0.0, uni.contrast);
    color = clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);

    if (fabs(uni.hueShift) > 0.0001) {
        float cosA = cos(uni.hueShift);
        float sinA = sin(uni.hueShift);
        float3x3 rgbToYIQ = float3x3(0.299, 0.587, 0.114,
                                     0.596, -0.274, -0.322,
                                     0.211, -0.523, 0.312);
        float3x3 yiqToRGB = float3x3(1.0, 0.956, 0.621,
                                     1.0, -0.272, -0.647,
                                     1.0, -1.105, 1.702);
        float3 yiq = rgbToYIQ * color;
        float i = yiq.y * cosA - yiq.z * sinA;
        float q = yiq.y * sinA + yiq.z * cosA;
        yiq.y = i;
        yiq.z = q;
        color = yiqToRGB * yiq;
    }

    return saturate(color);
}
