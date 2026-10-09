#include <metal_stdlib>
using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float2 texCoords;
};

struct PerspectiveUniforms {
    float angle;            // Current lid angle in radians
    float aspect;           // Screen aspect ratio (width / height)
    float keystoneStrength; // Horizontal taper intensity
    float stretchBalance;   // Aspect ratio compensator
};

vertex RasterizerData vertex_main(uint vertexID [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0,  1.0), float2(-1.0, -1.0), float2( 1.0, -1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    const float2 texCoords[6] = {
        float2(0.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
    };

    RasterizerData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoords = texCoords[vertexID];
    return out;
}

fragment float4 fragment_main(RasterizerData in [[stage_in]],
                              texture2d<float> screenTexture [[texture(0)]],
                              texture2d<float> blurredTexture [[texture(1)]],
                              sampler textureSampler [[sampler(0)]],
                              constant PerspectiveUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.texCoords;

    float currentTheta = min(uniforms.angle, 1.5707963f);
    float delta = 1.5707963f - currentTheta;

    // Upright at 90° or wider: render flat and completely sharp edge-to-edge
    if (delta <= 0.0001f) {
        return screenTexture.sample(textureSampler, uv);
    }

    float tiltAmount = sin(delta);
    float s = 1.0f - uv.y; // 0.0 at bottom hinge, 1.0 at top bezel

    // 1. Perspective Depth Coordinate Warping
    float w = max(1.0f - (s * tiltAmount * uniforms.keystoneStrength), 0.05f);
    float warpedX = ((uv.x - 0.5f) / w) + 0.5f;
    float warpedY = 1.0f - (s * (1.0f - (tiltAmount * (1.0f - uniforms.stretchBalance))) / w);
    float2 finalUV = float2(warpedX, warpedY);

    // 2. Traveling Focus Wavefront Math
    const float minAngleRad = 60.0f * (3.14159265f / 180.0f); // ~60°
    const float maxAngleRad = 90.0f * (3.14159265f / 180.0f); // ~90°
    
    // Normalized open progress (0.0 when nearly closed, 1.0 when upright)
    float openProgress = clamp((uniforms.angle - minAngleRad) / (maxAngleRad - minAngleRad), 0.0f, 1.0f);
    float smoothProgress = smoothstep(0.0f, 1.0f, openProgress);

    // The focus horizon sweeps upward from below the screen (-0.35) to above the top (4.0)
    float focusLine = mix(-0.35f, 4.0f, smoothProgress);
    
    // Width of the soft transition zone between sharp and blurred
    float feather = 4.0f;

    // Sweep factor: 0.0 below the focus line (sharp), 1.0 above it (blurred)
    float sweepFactor = smoothstep(focusLine - feather, focusLine + feather, s);

    // Depth gradient when out of focus
    float gradientIntensity = mix(0.8f, 2.0f, s);

    // Combined local blur amount for this specific pixel (0.0 to 1.0)
    float localBlur = clamp(sweepFactor * gradientIntensity, 0.0f, 1.0f);

    // 3. Dynamic Silhouette Edge Bleed
    float edgeBleed = mix(0.003f, 0.080f, localBlur);

    // Cull pixels that fall entirely beyond the outward bloom area
    if (finalUV.x < -edgeBleed || finalUV.x > (1.0f + edgeBleed) ||
        finalUV.y < -edgeBleed || finalUV.y > (1.0f + edgeBleed)) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    // 4. Sample and Blend Content
    float4 sharpColor = screenTexture.sample(textureSampler, clamp(finalUV, 0.0f, 1.0f));
    float4 blurredColor = blurredTexture.sample(textureSampler, finalUV);
    float4 frameColor = mix(sharpColor, blurredColor, localBlur);

    // 5. Progressive Depth Shadow / Illumination Wave (Delayed to <= 70°)
        const float shadowStartAngleRad = 80.0f * (3.14159265f / 180.0f); // Shadow begins ONLY under 70°
        const float shadowFullAngleRad  = 20.0f * (3.14159265f / 180.0f); // Reaches full intensity by 55°

        // 0.0 when angle >= 70°, ramping smoothly to 1.0 as the lid closes toward 55°
        float shadowActivation = smoothstep(shadowStartAngleRad, shadowFullAngleRad, uniforms.angle);

        float maxShadowTop = 2.0f;    // Max darkness at the top
        float maxShadowBottom = 2.0f; // Ambient shadow at bottom hinge
        float depthShadow = mix(maxShadowBottom, maxShadowTop, s);

        // Gated strictly by shadowActivation (stays 0 above 70°)
        float shadowAmount = clamp(sweepFactor * depthShadow * shadowActivation, 0.0f, 1.0f);
        frameColor.rgb *= (1.0f - shadowAmount);

    // 6. Soft Silhouette Falloff into Black Bars
    float maskX = smoothstep(-edgeBleed, edgeBleed, finalUV.x) *
                  (1.0f - smoothstep(1.0f - edgeBleed, 1.0f + edgeBleed, finalUV.x));
    float maskY = smoothstep(-edgeBleed, edgeBleed, finalUV.y) *
                  (1.0f - smoothstep(1.0f - edgeBleed, 1.0f + edgeBleed, finalUV.y));
    float borderMask = clamp(maskX * maskY, 0.0f, 1.0f);

    return mix(float4(0.0f, 0.0f, 0.0f, 1.0f), frameColor, borderMask);
}
