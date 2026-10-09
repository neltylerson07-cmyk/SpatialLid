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

    const float uprightRad = 1.5707963f; // 90° in radians
    float currentTheta = min(uniforms.angle, uprightRad);
    float delta = uprightRad - currentTheta;

    // Upright at 90° or wider: render flat and completely sharp edge-to-edge
    if (delta <= 0.0001f) {
        return screenTexture.sample(textureSampler, uv);
    }

    // Smooth transition envelope as angle begins closing (smoothly ramps from 0.0 to 1.0 by ~86°)
    float transitionProgress = smoothstep(0.0f, 0.07f, delta);

    float tiltAmount = sin(delta) * transitionProgress;
    float s = 1.0f - uv.y; // 0.0 at bottom hinge, 1.0 at top bezel

    // Progressive low-angle dual compensation (below 45°):
    // Simultaneously increases horizontal keystone taper and decreases vertical
    // stretch balance as the lid angle closes toward 0°.
    const float angle45Rad = 0.7853982f; // 45° in radians
    float lowAngleKeystoneBoost = 1.0f;
    float lowAngleStretchMultiplier = 1.0f;
    if (currentTheta < angle45Rad) {
        float lowAngleProgress = clamp((angle45Rad - currentTheta) / angle45Rad, 0.0f, 1.0f);
        // Keystone taper ramps up smoothly below 45°
        lowAngleKeystoneBoost += 1.0f * (0.8f * lowAngleProgress + 0.2f * lowAngleProgress * lowAngleProgress);
        // Stretch balance drops smoothly below 45°
        lowAngleStretchMultiplier -= 0.45f * lowAngleProgress;
    }

    // 1. Perspective Depth Coordinate Warping
    float effectiveKeystone = uniforms.keystoneStrength * transitionProgress * lowAngleKeystoneBoost;
    float effectiveStretch = max(uniforms.stretchBalance * lowAngleStretchMultiplier, 0.01f);
    float w = max(1.0f - (s * tiltAmount * effectiveKeystone), 0.05f);
    float warpedX = ((uv.x - 0.5f) / w) + 0.5f;
    float warpedY = 1.0f - (s * (1.0f - (tiltAmount * (1.0f - effectiveStretch))) / w);
    float2 finalUV = float2(warpedX, warpedY);

    // 2. Traveling Focus Wavefront Math
    const float minAngleRad = 60.0f * (3.14159265f / 180.0f); // ~60°
    const float maxAngleRad = 90.0f * (3.14159265f / 180.0f); // ~90°
    
    // Normalized open progress (0.0 when nearly closed, 1.0 when upright)
    float openProgress = clamp((uniforms.angle - minAngleRad) / (maxAngleRad - minAngleRad), 0.0f, 1.0f);
    float smoothProgress = smoothstep(0.0f, 1.0f, openProgress);

    // The focus horizon sweeps upward from below the screen (-0.35) to above the top (4.0)
    float focusLine = mix(-0.35f, 4.0f, smoothProgress);
    float feather = 4.0f;
    float sweepFactor = smoothstep(focusLine - feather, focusLine + feather, s);
    float gradientIntensity = mix(0.8f, 2.0f, s);

    // Scale blur by transitionProgress so at 90° blur is strictly 0.0
    float localBlur = clamp(sweepFactor * gradientIntensity * transitionProgress, 0.0f, 1.0f);

    // 3. Dynamic Silhouette Edge Bleed
    float edgeBleed = mix(0.003f, 0.080f, localBlur) * transitionProgress;

    // Cull pixels that fall entirely beyond the outward bloom area
    if (finalUV.x < -edgeBleed || finalUV.x > (1.0f + edgeBleed) ||
        finalUV.y < -edgeBleed || finalUV.y > (1.0f + edgeBleed)) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    // 4. Sample and Blend Content
    float4 sharpColor = screenTexture.sample(textureSampler, clamp(finalUV, 0.0f, 1.0f));
    float4 blurredColor = blurredTexture.sample(textureSampler, finalUV);
    float4 frameColor = mix(sharpColor, blurredColor, localBlur);

    // 5. Progressive Depth Shadow (Delayed to <= 70°)
    const float shadowStartAngleRad = 70.0f * (3.14159265f / 180.0f);
    const float shadowFullAngleRad  = 30.0f * (3.14159265f / 180.0f);
    float shadowActivation = smoothstep(shadowStartAngleRad, shadowFullAngleRad, uniforms.angle);

    float maxShadowTop = 2.0f;
    float maxShadowBottom = 1.0f;
    float depthShadow = mix(maxShadowBottom, maxShadowTop, s);
    float shadowAmount = clamp(sweepFactor * depthShadow * shadowActivation * transitionProgress, 0.0f, 1.0f);
    frameColor.rgb *= (1.0f - shadowAmount);

    // 6. Seamless Silhouette Edge Mask
    // Only fall off into black outside the [0, 1] texture coordinates
    float distLeft   = max(-finalUV.x, 0.0f);
    float distRight  = max(finalUV.x - 1.0f, 0.0f);
    float distBottom = max(-finalUV.y, 0.0f);
    float distTop    = max(finalUV.y - 1.0f, 0.0f);
    float outsideDist = max(max(distLeft, distRight), max(distBottom, distTop));

    float borderMask = (edgeBleed > 0.0001f) ? (1.0f - smoothstep(0.0f, edgeBleed, outsideDist)) : (outsideDist <= 0.0f ? 1.0f : 0.0f);

    return mix(float4(0.0f, 0.0f, 0.0f, 1.0f), frameColor, borderMask);
}
