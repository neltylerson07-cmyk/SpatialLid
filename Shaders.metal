#include <metal_stdlib>
using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float2 texCoords;
};

struct PerspectiveUniforms {
    float angle;              // Current lid angle in radians
    float aspect;             // Screen aspect ratio (width / height)
    float keystoneStrength;   // Horizontal taper intensity
    float stretchBalance;     // Aspect ratio compensator
    float settleProgress;     // 0.0 = full perspective, 1.0 = completely flat & unwarped
    float keyboardReflection; // Intensity of simulated keyboard reflection (0.0 to 1.0)
    float keyboardTilt;       // Ground-plane pitch / tilt angle (0.4 to 2.0, default 1.0)
    float keyboardReach;      // Reflection height / reach (0.15 to 0.60, default 0.35)
    float keyboardBacklight;  // Key backlight luminescence brightness (0.0 to 2.0, default 1.0)
    float keyboardOffset;     // Vertical position shift to bring keys right to bottom edge (default 0.00)
    float keyboardWidth;      // Width of the keyboard well (0.60 to 1.00, default 0.94)
    float keyboardDepthBlur;  // Optical depth-of-field blur gradient between closest & furthest row (default 1.0)
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

// Geometric structure for 1:1 Apple Magic Keyboard / MacBook layout
struct KeyGeometry {
    float centerU;
    float halfWU;
    float centerV;
    float halfHV;
    bool isKey;
    bool isTouchId;
    bool hasHomingBump;
    bool hasCapsDot;
    bool isOuterCorner;
};

// Computes key boundaries, offsets, and metadata across all 6 rows based on the official MacBook keyboard reference
static KeyGeometry getKeyGeometry(int rowIndex, float u, float relV) {
    KeyGeometry g;
    g.centerU = 0.5f;
    g.halfWU = 0.025f;
    g.centerV = 0.5f;
    g.halfHV = 0.39f; // Standard key covers ~78% of row height (0.5 ± 0.39)
    g.isKey = true;
    g.isTouchId = false;
    g.hasHomingBump = false;
    g.hasCapsDot = false;
    g.isOuterCorner = false;

    // Standard horizontal gap between keycaps (in normalized well width units)
    const float gapU = 0.0055f;

    if (rowIndex == 0) {
        // FUNCTION ROW: 14 keys (Esc, 12 F-keys, Touch ID sensor)
        const float B[15] = {0.0f, 0.095f, 0.161f, 0.227f, 0.293f, 0.359f, 0.425f, 0.491f, 0.557f, 0.623f, 0.689f, 0.755f, 0.821f, 0.887f, 1.0f};
        for (int i = 0; i < 14; ++i) {
            if (u <= B[i + 1] || i == 13) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                if (i == 0) g.isOuterCorner = true; // Esc top-left fillet
                if (i == 13) {
                    g.isTouchId = true;
                    g.isOuterCorner = true; // Touch ID top-right fillet
                }
                break;
            }
        }
    } else if (rowIndex == 1) {
        // NUMBER ROW: 14 keys (~, 1..0, -, =, Delete)
        const float B[15] = {0.0f, 0.068f, 0.136f, 0.204f, 0.272f, 0.340f, 0.408f, 0.476f, 0.544f, 0.612f, 0.680f, 0.748f, 0.816f, 0.884f, 1.0f};
        for (int i = 0; i < 14; ++i) {
            if (u <= B[i + 1] || i == 13) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                break;
            }
        }
    } else if (rowIndex == 2) {
        // TAB / QWERTY ROW: 14 keys (Tab, Q..P, [, ], \)
        const float B[15] = {0.0f, 0.103f, 0.171f, 0.239f, 0.307f, 0.375f, 0.443f, 0.511f, 0.579f, 0.647f, 0.715f, 0.783f, 0.851f, 0.919f, 1.0f};
        for (int i = 0; i < 14; ++i) {
            if (u <= B[i + 1] || i == 13) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                break;
            }
        }
    } else if (rowIndex == 3) {
        // CAPS / HOME ROW: 13 keys (Caps Lock, A..L, ;, ', Return)
        const float B[14] = {0.0f, 0.123f, 0.191f, 0.259f, 0.327f, 0.395f, 0.463f, 0.531f, 0.599f, 0.667f, 0.735f, 0.803f, 0.871f, 1.0f};
        for (int i = 0; i < 13; ++i) {
            if (u <= B[i + 1] || i == 12) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                if (i == 0) g.hasCapsDot = true; // Caps lock indicator LED
                if (i == 4) g.hasHomingBump = true; // 'F' tactile homing bar
                if (i == 7) g.hasHomingBump = true; // 'J' tactile homing bar
                break;
            }
        }
    } else if (rowIndex == 4) {
        // SHIFT ROW: 12 keys (Left Shift, Z..M, ,, ., /, Right Shift)
        const float B[13] = {0.0f, 0.158f, 0.226f, 0.294f, 0.362f, 0.430f, 0.498f, 0.566f, 0.634f, 0.702f, 0.770f, 0.838f, 1.0f};
        for (int i = 0; i < 12; ++i) {
            if (u <= B[i + 1] || i == 11) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);
                break;
            }
        }
    } else {
        // ROW 5: BOTTOM MODIFIERS, SPACEBAR & INVERTED-T ARROW KEYS
        // 0: Fn, 1: Control, 2: Option, 3: Command, 4: Spacebar, 5: Command, 6: Option, 7: Left Arrow, 8: Up/Down, 9: Right Arrow
        const float B[11] = {0.0f, 0.071f, 0.142f, 0.227f, 0.322f, 0.678f, 0.773f, 0.858f, 0.905f, 0.953f, 1.0f};
        for (int i = 0; i < 10; ++i) {
            if (u <= B[i + 1] || i == 9) {
                float left = B[i] + gapU * 0.5f;
                float right = B[i + 1] - gapU * 0.5f;
                g.centerU = (left + right) * 0.5f;
                g.halfWU = max((right - left) * 0.5f, 0.005f);

                if (i == 0) {
                    g.isOuterCorner = true; // Fn bottom-left fillet
                } else if (i == 7) {
                    // Left Arrow: half-height key in bottom half
                    if (relV > 0.50f) {
                        g.isKey = false; // Empty aluminum topcase above Left Arrow
                    } else {
                        g.centerV = 0.26f;
                        g.halfHV = 0.20f;
                    }
                } else if (i == 8) {
                    // Up / Down Arrow: two stacked half-height keys
                    if (relV > 0.50f) {
                        g.centerV = 0.74f;
                        g.halfHV = 0.20f;
                    } else {
                        g.centerV = 0.26f;
                        g.halfHV = 0.20f;
                    }
                } else if (i == 9) {
                    // Right Arrow: half-height key in bottom half
                    g.isOuterCorner = true; // Right Arrow bottom-right fillet
                    if (relV > 0.50f) {
                        g.isKey = false; // Empty aluminum topcase above Right Arrow
                    } else {
                        g.centerV = 0.26f;
                        g.halfHV = 0.20f;
                    }
                }
                break;
            }
        }
    }
    return g;
}

// Synthesizes an authentic MacBook keyboard reflection matching the reference hardware layout:
// - Dynamic Screen Light Simulation: The screen acts as an active area light source illuminating the keyboard in real time.
// - Opacity range is 45° to 90°: exactly 0 at 90° and <= 45°, holding normal full strength in the middle (~60° to 75°).
// - Closest row (Row 0 right at the bottom hinge) is in sharp focus, full opacity, and high contrast.
// - As rows recede in depth, all edges blur and opacity smoothly falls off, making distant rows translucent.
static float4 sampleKeyboardReflection(float2 finalUV,
                                        float delta,
                                        float currentTheta,
                                        constant PerspectiveUniforms &uniforms,
                                        texture2d<float> blurredTexture,
                                        sampler textureSampler) {
    const float uprightRad = 1.5707963f; // 90° in radians
    const float minAngleRad = 0.7853982f; // 45° in radians (pi / 4)

    if (currentTheta <= minAngleRad || currentTheta >= uprightRad) {
        return float4(0.0f);
    }

    // Distance from bottom hinge (finalUV.y = 1.0) upward into the display
    float vY = max(1.0f - finalUV.y, 0.0f) + uniforms.keyboardOffset;
    float maxReach = clamp(uniforms.keyboardReach, 0.12f, 0.65f);
    
    if (vY < 0.0f || vY > maxReach || finalUV.x < 0.0f || finalUV.x > 1.0f) {
        return float4(0.0f);
    }

    // Perspective foreshortening:
    // tilt controls the pitch/angle of the keyboard plane (flatter grazing angle compresses keys vertically)
    float tilt = max(uniforms.keyboardTilt, 0.10f);
    
    // Normalized distance on the ground plane (0.0 at hinge, 1.0 at max reach)
    float normY = vY / maxReach;
    float perspectiveCompression = 1.0f + 0.85f * normY;
    float groundZ = (vY * (0.80f / tilt)) * perspectiveCompression;

    // Linear keystone taper across the angled plane (straight lines remain straight)
    float taper = 1.0f + normY * (0.45f * tilt);
    float X = (finalUV.x - 0.5f) * taper;

    // Keyboard well bounds
    float halfW = clamp(uniforms.keyboardWidth * 0.5f, 0.30f, 0.495f);
    float wellLeft = -halfW;
    float wellRight = halfW;
    float wellWidth = wellRight - wellLeft;
    const float wellBottom = 0.00f; // Anchored directly to bottom screen edge
    float wellTop = maxReach * 0.68f;

    // --- Dynamic Screen Light Simulation (Screen-Space Area Light & Radiance) ---
    // Sample downward radiance from the blurred screen texture
    float screenSampleX = clamp(finalUV.x, 0.02f, 0.98f);
    // Keys near the hinge catch light from the bottom of the screen; distant keys catch light from higher up
    float screenSampleY = clamp(1.0f - normY * 0.45f, 0.45f, 0.98f);
    float3 screenLightDirect = blurredTexture.sample(textureSampler, float2(screenSampleX, screenSampleY)).rgb;
    float3 screenLightAmbient = blurredTexture.sample(textureSampler, float2(0.5f, 0.75f)).rgb;
    float3 screenRadiance = mix(screenLightAmbient, screenLightDirect, 0.75f);
    float screenLightIntensity = clamp(1.0f - normY * 0.60f, 0.20f, 1.0f);

    // Continuous Depth-of-Field (DoF) optical blur parameter:
    // 0.0 at the hinge (Row 0), smoothly accelerating to > 1.0 at Row 5 and the top of the well
    float dofT = clamp(vY / max(maxReach * 0.70f, 0.01f), 0.0f, 1.5f);
    float depthBlur = pow(dofT, 1.4f) * clamp(uniforms.keyboardDepthBlur, 0.0f, 3.0f);

    // Progressive Depth Opacity:
    // Closest row is 100% opaque. Receding rows gracefully fade out and become translucent.
    float rowDepthProgress = clamp(vY / max(wellTop, 0.01f), 0.0f, 1.25f);
    float rowOpacity = mix(1.0f, 0.18f, smoothstep(0.0f, 1.0f, rowDepthProgress));

    // Smooth forward chassis falloff near top of reach
    float forwardFalloff = smoothstep(1.0f, 0.75f, normY);

    // --- 1. Soft Out-of-Focus Well Silhouette ---
    // At the bottom hinge, the well edge is crisp. As it recedes toward the top,
    // the left, right, and top perimeter edges blur and diffuse widely into the chassis.
    float wellEdgeBlur = mix(0.0015f, 0.038f, clamp(depthBlur, 0.0f, 2.0f));
    float wellMaskX = smoothstep(-wellEdgeBlur, wellEdgeBlur, X - wellLeft) *
                      smoothstep(-wellEdgeBlur, wellEdgeBlur, wellRight - X);
    float wellMaskY = smoothstep(-wellEdgeBlur, wellEdgeBlur, wellTop - vY);
    float wellMask = clamp(wellMaskX * wellMaskY, 0.0f, 1.0f);

    // Base aluminum topcase (Space Gray specular sheen) illuminated by screen light
    float3 topcaseCol = float3(0.065f, 0.067f, 0.075f);
    topcaseCol += screenRadiance * float3(0.32f, 0.32f, 0.36f) * screenLightIntensity;
    float grainIntensity = 0.008f * max(1.0f - depthBlur * 0.8f, 0.0f);
    topcaseCol += float3(grainIntensity) * sin(X * 380.0f);

    // Trackpad region (foreshortened wide rectangle centered in front of keyboard)
    float tpBottom = wellTop + 0.015f;
    float tpTop = min(tpBottom + 0.085f * tilt, maxReach);
    if (vY >= tpBottom - 0.02f && vY <= tpTop + 0.02f && abs(X) <= 0.20f) {
        float tpH = (tpTop - tpBottom) * 0.5f;
        float2 tpD = abs(float2(X, vY - (tpBottom + tpTop) * 0.5f)) - float2(0.165f - 0.006f, tpH - 0.006f);
        float tpDist = length(max(tpD, 0.0f)) + min(max(tpD.x, tpD.y), 0.0f) - 0.006f;
        float tpBorderWidth = mix(0.003f, 0.025f, clamp(depthBlur, 0.0f, 2.0f));
        float tpBorder = smoothstep(tpBorderWidth, 0.0f, abs(tpDist));
        float3 tpColor = float3(0.072f, 0.074f, 0.082f) + screenRadiance * float3(0.40f, 0.40f, 0.44f) * screenLightIntensity;
        topcaseCol = mix(topcaseCol, tpColor + float3(0.18f) * tpBorder, tpBorder * 0.8f);
    }

    // --- 2. Keycaps and Backlight Matrix ---
    float3 wellColor = float3(0.024f, 0.024f, 0.028f);

    const int numRows = 6;
    float rowInterval = (wellTop - wellBottom);
    float relProgress = clamp((vY - wellBottom) / rowInterval, 0.0f, 1.0f);
    float warpedRow = pow(relProgress, 0.88f) * float(numRows);
    int rowIndex = clamp(int(floor(warpedRow)), 0, numRows - 1);

    // Compute row bounds in vY space
    float rowNorm0 = pow(float(rowIndex) / float(numRows), 1.0f / 0.88f);
    float rowNorm1 = pow(float(rowIndex + 1) / float(numRows), 1.0f / 0.88f);
    float rowY0 = wellBottom + rowNorm0 * rowInterval;
    float rowY1 = wellBottom + rowNorm1 * rowInterval;
    float rowH = (rowY1 - rowY0);

    // Row depth blur factor:
    // Row 0 = 0.0 (sharpest), Row 5 = 1.0+ (heavily blurred)
    float rowDepthT = float(rowIndex) / 5.0f;
    float rowBlur = pow(rowDepthT, 1.3f) * clamp(uniforms.keyboardDepthBlur, 0.0f, 3.0f);

    // Dynamic optical blur radius for keycap edges:
    // Row 0 has subpixel anti-aliased edge (0.0007f).
    // Row 5 softens by up to 0.035f so edges melt and blend smoothly into neighbors.
    float keyEdgeBlur = mix(0.0007f, 0.035f, rowBlur);

    // High-frequency contrast attenuation:
    // When objects go out of focus, high-frequency spatial variation decays exponentially.
    float gridContrast = exp(-pow(rowBlur * 1.5f, 2.0f));

    // Normalized coordinates across keyboard well
    float normU = clamp((X - wellLeft) / wellWidth, 0.0f, 1.0f);
    float relV = clamp((vY - rowY0) / rowH, 0.0f, 1.0f);

    // Exact key geometry lookup from MacBook reference layout
    KeyGeometry geo = getKeyGeometry(rowIndex, normU, relV);

    if (!geo.isKey) {
        // Empty aluminum cutout (e.g. above Left/Right inverted-T arrows)
        wellColor = topcaseCol;
    } else {
        float keyCenterX = wellLeft + geo.centerU * wellWidth;
        float keyHalfW = geo.halfWU * wellWidth;
        float keyCenterY = rowY0 + geo.centerV * rowH;
        float keyHalfH = geo.halfHV * rowH;

        // Keycap corner fillet radius (larger on outer corners of the keyboard well)
        float radius = mix(0.0035f, 0.007f, rowBlur);
        if (geo.isOuterCorner) {
            radius = mix(0.0055f, 0.009f, rowBlur);
        }

        // Distance to rounded keycap rectangle
        float2 d = abs(float2(X - keyCenterX, vY - keyCenterY)) - float2(keyHalfW - radius, keyHalfH - radius);
        float dist = length(max(d, 0.0f)) + min(max(d.x, d.y), 0.0f) - radius;

        // 1. Soft Keycap Mask:
        float rawKeyMask = smoothstep(keyEdgeBlur, -keyEdgeBlur, dist);
        float keyMask = mix(0.5f, rawKeyMask, gridContrast);

        // 2. Dish shading & specular glint catching direct screen light:
        float glintExtent = mix(keyHalfH * 0.30f, keyHalfH * 0.95f, rowBlur);
        float topEdgeGlint = smoothstep(glintExtent, keyHalfH, vY - keyCenterY) * (0.18f * (1.0f - 0.65f * rowBlur));
        float dishShading = 1.0f - mix(0.22f, 0.04f, rowBlur) * length(float2((X - keyCenterX) / keyHalfW, (vY - keyCenterY) / keyHalfH));
        
        // Keycap color: matte black base plastic + diffuse screen illumination + specular edge glint reflecting screen content
        float3 basePlastic = float3(0.055f, 0.056f, 0.062f) * dishShading;
        float3 keyCapDiffuse = basePlastic + screenRadiance * float3(0.22f, 0.22f, 0.25f) * screenLightIntensity;
        float3 keyCapSpecular = screenLightDirect * (topEdgeGlint * 2.0f) * screenLightIntensity;
        float3 keyCap = keyCapDiffuse + keyCapSpecular;

        // Distinct Touch ID sensor key:
        // A clean matte black key with a subtle, dark recessed circular sensor ring.
        // It has NO backlight glow and NO printed legend (matches authentic Apple hardware).
        if (geo.isTouchId) {
            float physAspect = 0.80f / max(tilt, 0.10f);
            float2 localCoord = float2(X - keyCenterX, (vY - keyCenterY) * physAspect);
            float circleR = keyHalfH * 0.65f * physAspect;
            float ringDist = abs(length(localCoord) - circleR);
            float ring = smoothstep(mix(0.0015f, 0.0035f, rowBlur), 0.0f, ringDist);
            float inSensor = smoothstep(0.0f, -0.002f, length(localCoord) - circleR);

            // Darker sapphire sensor surface inside the ring
            keyCap = mix(keyCap, float3(0.022f, 0.022f, 0.025f), inSensor);
            // Subtle dark chamfer groove (darker than keycap, NOT bright glowing white)
            keyCap = mix(keyCap, float3(0.015f, 0.015f, 0.018f), ring);
        }

        // Tactile raised homing bars on 'F' and 'J' keys
        if (geo.hasHomingBump) {
            float bumpY = keyCenterY - keyHalfH * 0.55f;
            float bumpDist = length(max(abs(float2(X - keyCenterX, vY - bumpY)) - float2(0.0045f, 0.0009f), 0.0f));
            float bump = smoothstep(mix(0.0014f, 0.004f, rowBlur), 0.0f, bumpDist);
            keyCap += float3(0.14f) * bump * (1.0f - 0.7f * rowBlur);
        }

        // Caps Lock LED status dot indicator
        if (geo.hasCapsDot) {
            float dotX = keyCenterX - keyHalfW * 0.65f;
            float dotY = keyCenterY + keyHalfH * 0.35f;
            float dotDist = length(float2(X - dotX, vY - dotY));
            float dot = smoothstep(mix(0.0025f, 0.0055f, rowBlur), 0.0f, dotDist);
            keyCap = mix(keyCap, float3(0.22f, 0.88f, 0.38f) * uniforms.keyboardBacklight, dot * (1.0f - 0.4f * rowBlur));
        }

        // 3. Illuminated key legend diffusion (Touch ID key is blank):
        if (!geo.isTouchId) {
            float legDiffusion = 1.0f + 3.5f * rowBlur;
            float legSpread = 3.5f / legDiffusion;
            float legX = (X - keyCenterX) / (keyHalfW * 0.50f);
            float legY = (vY - keyCenterY) / (keyHalfH * 0.65f);
            float legendBrightness = (0.32f / legDiffusion) * uniforms.keyboardBacklight * mix(1.0f, 0.40f, rowDepthProgress);
            float legend = exp(-(legX * legX + legY * legY) * legSpread) * legendBrightness;
            keyCap += float3(0.85f, 0.90f, 1.0f) * legend;
        }

        // 4. Perimeter backlight glow dispersal (Touch ID key is not backlit):
        float glowBrightness = geo.isTouchId ? 0.0f : clamp(uniforms.keyboardBacklight, 0.0f, 2.5f) * mix(1.0f, 0.45f, rowDepthProgress);
        float glowSpread = mix(450.0f, 65.0f, clamp(rowBlur, 0.0f, 1.0f));
        float glow = exp(-max(dist, 0.0f) * glowSpread) * glowBrightness;
        float3 backlight = float3(0.92f, 0.95f, 1.0f) * 0.85f;
        
        // Crevice ambient occlusion: key wells are naturally shaded from direct overhead screen light
        float creviceAO = mix(0.40f, 1.0f, keyMask);
        float3 wellGlow = mix(float3(0.024f, 0.024f, 0.028f) * creviceAO, backlight, glow);

        // Keycaps blend with backlight well based on the blurred optical mask
        wellColor = mix(wellGlow, keyCap, keyMask);
    }

    // Smoothly combine well with surrounding topcase using the soft feathered wellMask
    float3 col = mix(topcaseCol, wellColor, wellMask);

    // Distance falloff from hinge upward: quadratic decay ensures natural optical light attenuation
    float distanceFalloff = pow(max(1.0f - normY, 0.0f), 1.6f) * forwardFalloff;

    // Lateral reflection falloff on screen edges to prevent any hard screen edge cuts
    float lateralFalloff = smoothstep(0.0f, 0.04f, finalUV.x) * smoothstep(1.0f, 0.96f, finalUV.x);

    // Angle Opacity Envelope:
    // Active range is 45° to 90°:
    // - Opacity is 0 at 90° (upright) and 0 at 45° (and below 45°)
    // - Smoothly peaks at 1.0 (normal full opacity) in the middle of this range (~60° to 75°)
    float angleNorm = clamp((currentTheta - minAngleRad) / (uprightRad - minAngleRad), 0.0f, 1.0f);
    float sinAngle = sin(angleNorm * 3.14159265f);
    float angleEnvelope = smoothstep(0.0f, 1.0f, clamp(sinAngle * 1.25f, 0.0f, 1.0f));

    // Total reflection alpha modulated by row-by-row depth opacity falloff and angle envelope
    float alpha = distanceFalloff * rowOpacity * lateralFalloff * angleEnvelope * (1.0f - uniforms.settleProgress);
    return float4(col, alpha);
}

fragment float4 fragment_main(RasterizerData in [[stage_in]],
                              texture2d<float> screenTexture [[texture(0)]],
                              texture2d<float> blurredTexture [[texture(1)]],
                              sampler textureSampler [[sampler(0)]],
                              constant PerspectiveUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.texCoords;

    const float uprightRad = 1.5707963f; // 90° in radians
    const float minReflectAngleRad = 0.7853982f; // 45° in radians
    
    // When settleProgress > 0, smoothly blend angle towards upright 90° (flat)
    float targetAngle = mix(uniforms.angle, uprightRad, clamp(uniforms.settleProgress, 0.0f, 1.0f));
    float currentTheta = min(targetAngle, uprightRad);
    float delta = uprightRad - currentTheta;

    // Upright at 90° or wider, or settled: render flat and completely sharp edge-to-edge
    if (delta <= 0.0001f || uniforms.settleProgress >= 0.999f) {
        return screenTexture.sample(textureSampler, uv);
    }

    // Smooth transition envelope as angle begins closing (smoothly ramps from 0.0 to 1.0 by ~86°)
    float transitionProgress = smoothstep(0.0f, 0.07f, delta);

    float tiltAmount = sin(delta) * transitionProgress;
    float s = 1.0f - uv.y; // 0.0 at bottom hinge, 1.0 at top bezel

    // Progressive low-angle dual compensation (below 45°):
    // Simultaneously increases horizontal keystone taper and decreases vertical
    // stretch balance as the lid angle closes toward 0°.
    const float angle45Rad = 1.3963f; // 45° in radians
    float lowAngleKeystoneBoost = 1.0f;
    float lowAngleStretchMultiplier = 1.0f;
    if (currentTheta < angle45Rad) {
        float lowAngleProgress = clamp((angle45Rad - currentTheta) / angle45Rad, 0.0f, 1.0f);
        // Keystone taper ramps up smoothly below 45°
        lowAngleKeystoneBoost += 1.0f * (0.8f * lowAngleProgress + 0.6f * lowAngleProgress * lowAngleProgress);
        // Stretch balance drops smoothly below 45°
        lowAngleStretchMultiplier -= 1.8f * lowAngleProgress;
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
    float openProgress = clamp((targetAngle - minAngleRad) / (maxAngleRad - minAngleRad), 0.0f, 1.0f);
    float smoothProgress = smoothstep(0.0f, 1.0f, openProgress);

    // The focus horizon sweeps upward from below the screen (-0.35) to above the top (4.0)
    float focusLine = mix(-0.35f, 4.0f, smoothProgress);
    float feather = 4.0f;
    float sweepFactor = smoothstep(focusLine - feather, focusLine + feather, s);
    float gradientIntensity = mix(0.8f, 2.0f, s);

    // Scale blur by transitionProgress and settleFactor so blur fades out during settle
    float settleFactor = 1.0f - clamp(uniforms.settleProgress, 0.0f, 1.0f);
    float localBlur = clamp(sweepFactor * gradientIntensity * transitionProgress * settleFactor, 0.0f, 1.0f);

    // 3. Dynamic Silhouette Edge Bleed
    float edgeBleed = mix(0.003f, 0.040f, localBlur) * transitionProgress * settleFactor;

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
    const shadowStartAngleRad = 70.0f * (3.14159265f / 180.0f);
    const shadowFullAngleRad  = 30.0f * (3.14159265f / 180.0f);
    float shadowActivation = smoothstep(shadowStartAngleRad, shadowFullAngleRad, targetAngle);

    float maxShadowTop = 2.0f;
    float maxShadowBottom = 1.0f;
    float depthShadow = mix(maxShadowBottom, maxShadowTop, s);
    float shadowAmount = clamp(sweepFactor * depthShadow * shadowActivation * transitionProgress * settleFactor, 0.0f, 1.0f);
    frameColor.rgb *= (1.0f - shadowAmount);

    // 6. Simulated Keyboard Reflection (Active exclusively between 45° and 90°)
    if (uniforms.keyboardReflection > 0.001f && delta > 0.0001f && uniforms.settleProgress < 0.999f && currentTheta > minReflectAngleRad) {
        float4 kbReflect = sampleKeyboardReflection(finalUV, delta, currentTheta, uniforms, blurredTexture, textureSampler);
        float refAlpha = clamp(kbReflect.a * uniforms.keyboardReflection, 0.0f, 0.85f);
        // Specular reflection blend on glass: subtle attenuation of screen backlight + reflected light
        frameColor.rgb = frameColor.rgb * (1.0f - 0.25f * refAlpha) + kbReflect.rgb * refAlpha;
    }

    // 7. Seamless Silhouette Edge Mask
    // Only fall off into black outside the [0, 1] texture coordinates
    // At the bottom hinge (finalUV.y >= 1.0), the screen connects to the laptop base so it never clips into black
    float distLeft   = max(-finalUV.x, 0.0f);
    float distRight  = max(finalUV.x - 1.0f, 0.0f);
    float distTop    = max(-finalUV.y, 0.0f);
    float outsideDist = max(max(distLeft, distRight), distTop);

    // If outside bottom edge, keep solid to avoid black gap at the hinge
    float borderMask = (edgeBleed > 0.0001f) ? (1.0f - smoothstep(0.0f, edgeBleed, outsideDist)) : (outsideDist <= 0.0f ? 1.0f : 0.0f);

    return mix(float4(0.0f, 0.0f, 0.0f, 1.0f), frameColor, borderMask);
}
