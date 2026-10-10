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
    float showCalibrator;     // 1.0 if calibrator is active, 0.0 otherwise
    float frostedGlass;       // Frosted glass intensity (0.0 to 1.0, default 0.10)
    float blurIntensity;      // Screen depth blur intensity (0.0 to 2.0, default 1.00)
    float shadowIntensity;    // Screen depth shadow intensity (0.0 to 2.0, default 1.00)
    float lowAngleCompensation; // Low-angle taper & stretch compensation intensity (0.0 to 2.0, default 1.00)
    float clockProgress;      // Smooth transition progress for clock mode & background dimming (0.0 to 1.0)
    float showClock;          // 1.0 if clock texture is active, 0.0 otherwise
    float pad0;               // 16-byte alignment padding
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
        // Esc: 0.000 -> 0.102 (elongated Escape key)
        // F1..F12: 12 keys evenly spaced from 0.106 to 0.922 (width 0.068 each)
        // Touch ID: distinct compact square key at 0.930 -> 0.998 (width 0.068)
        if (u < 0.102f) {
            float left = gapU * 0.5f;
            float right = 0.102f - gapU * 0.5f;
            g.centerU = (left + right) * 0.5f;
            g.halfWU = max((right - left) * 0.5f, 0.005f);
            g.isOuterCorner = true; // Esc top-left fillet
        } else if (u < 0.106f) {
            g.isKey = false; // Gap between Esc and F1
        } else if (u < 0.922f) {
            int fIdx = int(floor((u - 0.106f) / 0.068f));
            fIdx = clamp(fIdx, 0, 11);
            float left = 0.106f + float(fIdx) * 0.068f + gapU * 0.5f;
            float right = 0.106f + float(fIdx + 1) * 0.068f - gapU * 0.5f;
            g.centerU = (left + right) * 0.5f;
            g.halfWU = max((right - left) * 0.5f, 0.005f);
        } else if (u < 0.930f) {
            g.isKey = false; // Aluminum separator between F12 and Touch ID
        } else {
            float left = 0.930f + gapU * 0.5f;
            float right = 0.998f - gapU * 0.5f;
            g.centerU = (left + right) * 0.5f;
            g.halfWU = max((right - left) * 0.5f, 0.005f);
            g.halfHV = 0.36f; // Compact square keycap
            g.isTouchId = true;
            g.isOuterCorner = true; // Touch ID top-right fillet
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
    const float minAngleRad = 0.87266f; // 45° in radians (pi / 4)

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

        // 2. Reversed Dish Shading & Crisp Specular Glint:
        // Sharp, defined specular glint focused on the bevel edge facing the display hinge
        float bevelStart = mix(keyHalfH * 0.78f, keyHalfH * 0.92f, rowBlur);
        float bevelEnd = keyHalfH * 0.99f;
        float edgeGlintRaw = smoothstep(bevelStart, bevelEnd, -(vY - keyCenterY));
        float edgeGlint = pow(edgeGlintRaw, 2.2f) * (1.0f - 0.55f * rowBlur);
        
        // Gracefully taper at the rounded lateral corners
        float cornerFade = smoothstep(keyHalfW, keyHalfW * 0.65f, abs(X - keyCenterX));
        edgeGlint *= cornerFade;

        float dishShading = 1.0f - mix(0.18f, 0.04f, rowBlur) * length(float2((X - keyCenterX) / keyHalfW, (vY - keyCenterY) / keyHalfH));
        float bevelSlope = 1.0f + 0.10f * clamp(-(vY - keyCenterY) / keyHalfH, -1.0f, 1.0f);
        
        // Keycap color: matte black base plastic + diffuse screen illumination + sharp specular edge glint
        float3 basePlastic = float3(0.055f, 0.056f, 0.062f) * dishShading * bevelSlope;
        float3 keyCapDiffuse = basePlastic + screenRadiance * float3(0.22f, 0.22f, 0.25f) * screenLightIntensity;
        float3 keyCapSpecular = screenLightDirect * (edgeGlint * 0.55f) * screenLightIntensity;
        float3 keyCap = keyCapDiffuse + keyCapSpecular;

        // Distinct Touch ID sensor key:
        // A clean, compact matte black key with a subtle, dark recessed circular sensor ring.
        // It has NO backlight glow and NO printed legend (matches authentic Apple hardware).
        if (geo.isTouchId) {
            float physAspect = 0.80f / max(tilt, 0.10f);
            float2 localCoord = float2(X - keyCenterX, (vY - keyCenterY) * physAspect);
            float keyRadius = min(keyHalfW, keyHalfH * physAspect);
            float circleR = keyRadius * 0.58f;
            float ringDist = abs(length(localCoord) - circleR);
            float ring = smoothstep(mix(0.0012f, 0.0030f, rowBlur), 0.0f, ringDist);
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
        // Significantly reduced opacity for a soft, subtle, realistic key perimeter glow
        float glowBrightness = geo.isTouchId ? 0.0f : clamp(uniforms.keyboardBacklight, 0.0f, 2.5f) * 0.35f * mix(1.0f, 0.35f, rowDepthProgress);
        float glowSpread = mix(500.0f, 85.0f, clamp(rowBlur, 0.0f, 1.0f));
        float glow = exp(-max(dist, 0.0f) * glowSpread) * glowBrightness;
        float3 backlight = float3(0.82f, 0.88f, 0.96f) * 0.45f;
        
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

// MARK: - Frosted Glass Grain Pattern Synthesizer
struct FrostedGrainResult {
    float height;        // Surface relief height (0.0 to 1.0)
    float2 gradient;     // Surface normal perturbation (for light reflection & refraction)
    float microSparkle;  // High-frequency silica / crystalline glint
};

static FrostedGrainResult sampleFrostedGlassGrain(float2 uv, float aspect) {
    FrostedGrainResult result;

    // Isotropic coordinates so grain pattern has uniform physical aspect on screen
    // Scale 180 means ~180 grain clusters vertically, giving tactile ~8-14 pixel cellular grain on screen
    float2 p = uv * float2(aspect * 360.0f / 1.5, 360.0f / 1.5);
    float2 ip = floor(p);
    float2 fp = fract(p);

    float minDist = 10.0f;
    float2 bestDiff = float2(0.0f);

    // 3x3 Worley / cellular search to generate distinct acid-etched glass pits and grain boundaries
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float2 g = float2(float(x), float(y));
            // Stable pseudorandom facet center
            float2 cellCoord = ip + g;
            float3 p3 = fract(float3(cellCoord.xyx) * float3(0.1031f, 0.1030f, 0.0973f));
            p3 += dot(p3, p3.yzx + 33.33f);
            float2 jitter = fract((p3.xx + p3.yz) * p3.zy);

            float2 diff = g + jitter - fp;
            float d = length(diff);
            if (d < minDist) {
                minDist = d;
                bestDiff = diff;
            }
        }
    }

    // Cell facet profile: distinct concave pit with raised rounded grain borders
    float cellFacet = 1.0f - clamp(minDist, 0.0f, 1.0f);
    // Analytical gradient of distance field for refraction & lighting normals
    float2 cellGrad = -bestDiff / max(minDist, 0.001f);

    // Secondary medium grain layer (rotated and offset for natural organic variation)
    float2 pMed = uv * float2(aspect * 760.0f / 1.5, 760.0f / 1.5);
    float2 ipMed = floor(pMed);
    float2 fpMed = fract(pMed);
    float medHash = fract(sin(dot(ipMed, float2(127.1f, 311.7f))) * 43758.5453f);
    float medGrain = medHash * (1.0f - length(fpMed - 0.5f) * 1.4f);

    // Tertiary high-frequency crystal sparkle (sandblasted quartz glitter)
    float2 pSparkle = uv * float2(aspect * 1900.0f / 1.5, 1900.0f / 1.5);
    float sparkle = fract(sin(dot(pSparkle, float2(269.5f, 183.3f))) * 43758.5453f);

    // Composite height and analytical gradient
    result.height = clamp(cellFacet * 0.70f + medGrain * 0.30f, 0.0f, 1.0f);
    result.gradient = cellGrad;
    result.microSparkle = sparkle;

    return result;
}

fragment float4 fragment_main(RasterizerData in [[stage_in]],
                              texture2d<float> screenTexture [[texture(0)]],
                              texture2d<float> blurredTexture [[texture(1)]],
                              texture2d<float> calibratorTexture [[texture(2)]],
                              texture2d<float> clockTexture [[texture(3)]],
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
        float4 base = screenTexture.sample(textureSampler, uv);
        if (uniforms.showCalibrator > 0.5f) {
            float4 calib = calibratorTexture.sample(textureSampler, uv);
            base.rgb = base.rgb * (1.0f - calib.a) + calib.rgb;
        }
        if (uniforms.showClock > 0.5f && uniforms.clockProgress > 0.001f) {
            float dimFactor = mix(1.0f, 0.52f, uniforms.clockProgress);
            base.rgb *= dimFactor;
            float4 clockPixel = clockTexture.sample(textureSampler, uv);
            if (clockPixel.a > 0.01f) {
                float2 texStep = float2(1.0f / max(float(clockTexture.get_width()), 1.0f),
                                        1.0f / max(float(clockTexture.get_height()), 1.0f));
                float aL = clockTexture.sample(textureSampler, uv - float2(texStep.x * 2.5f, 0.0f)).a;
                float aR = clockTexture.sample(textureSampler, uv + float2(texStep.x * 2.5f, 0.0f)).a;
                float aT = clockTexture.sample(textureSampler, uv - float2(0.0f, texStep.y * 2.5f)).a;
                float aB = clockTexture.sample(textureSampler, uv + float2(0.0f, texStep.y * 2.5f)).a;
                float2 glassNormal2D = float2(aR - aL, aB - aT);

                // Optical liquid glass refraction
                float2 refractOffset = glassNormal2D * 0.020f;
                float2 refractUV = clamp(uv - refractOffset, 0.0f, 1.0f);
                float4 refSharp = screenTexture.sample(textureSampler, refractUV);
                float4 refBlur = blurredTexture.sample(textureSampler, refractUV);
                float3 glassBg = mix(refSharp.rgb, refBlur.rgb, 0.30f);

                // Subtle chromatic dispersion
                glassBg.r = mix(glassBg.r, screenTexture.sample(textureSampler, clamp(refractUV - glassNormal2D * 0.003f, 0.0f, 1.0f)).r, 0.35f);
                glassBg.b = mix(glassBg.b, screenTexture.sample(textureSampler, clamp(refractUV + glassNormal2D * 0.003f, 0.0f, 1.0f)).b, 0.35f);

                // Specular meniscus highlight
                float rimGrad = length(glassNormal2D);
                float3 N = normalize(float3(-glassNormal2D * 1.8f, 1.0f));
                float3 L = normalize(float3(0.0f, -0.7f, 0.7f));
                float spec = pow(max(dot(N, L), 0.0f), 10.0f) * 0.28f;
                float rim = smoothstep(0.12f, 0.65f, rimGrad) * 0.22f;

                float3 liquidGlassColor = mix(glassBg, clockPixel.rgb, 0.62f) + float3(spec + rim);
                float clockAlpha = clockPixel.a * uniforms.clockProgress;
                base.rgb = mix(base.rgb, liquidGlassColor, clockAlpha);
            }
        }
        return base;
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
        float compFactor = clamp(uniforms.lowAngleCompensation, 0.0f, 2.0f);
        // Keystone taper ramps up smoothly below 45°
        lowAngleKeystoneBoost += compFactor * (0.8f * lowAngleProgress + 0.6f * lowAngleProgress * lowAngleProgress);
        // Stretch balance drops smoothly below 45°
        lowAngleStretchMultiplier -= (1.8f * compFactor) * lowAngleProgress;
    }

    // Scale effects by transitionProgress and settleFactor
    float settleFactor = 1.0f - clamp(uniforms.settleProgress, 0.0f, 1.0f);

    // Frosted glass intensity
    float frostAmount = clamp(uniforms.frostedGlass, 0.0f, 1.0f) * transitionProgress * settleFactor;

    // Evaluate frosted grain directly ON THE SCREEN (in screen space uv, NOT projected)
    FrostedGrainResult screenGrain;
    float2 grainRefract = float2(0.0f);
    if (frostAmount > 0.001f) {
        screenGrain = sampleFrostedGlassGrain(uv, uniforms.aspect);
        grainRefract = screenGrain.gradient * (0.0055f * frostAmount);
    }

    // Physical screen glass refracts incoming light rays before perspective projection
    float2 effectiveScreenUV = uv + grainRefract;

    // 1. Perspective Depth Coordinate Warping
    float effectiveKeystone = uniforms.keystoneStrength * transitionProgress * lowAngleKeystoneBoost;
    float effectiveStretch = max(uniforms.stretchBalance * lowAngleStretchMultiplier, 0.01f);
    float w = max(1.0f - (s * tiltAmount * effectiveKeystone), 0.05f);
    float warpedX = ((effectiveScreenUV.x - 0.5f) / w) + 0.5f;
    float warpedY = 1.0f - (s * (1.0f - (tiltAmount * (1.0f - effectiveStretch))) / w);
    float2 finalUV = float2(warpedX, warpedY);

    // Clean perspective projection coordinates (without grain refraction) for UI elements like Calibrator
    float cleanWarpedX = ((uv.x - 0.5f) / w) + 0.5f;
    float2 cleanPerspectiveUV = float2(cleanWarpedX, warpedY);

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

    // Scale blur by transitionProgress, settleFactor, and blurIntensity
    float localBlur = clamp(sweepFactor * gradientIntensity * transitionProgress * settleFactor * uniforms.blurIntensity, 0.0f, 1.0f);

    // 3. Dynamic Silhouette Edge Bleed
    float edgeBleed = mix(0.003f, 0.040f, localBlur) * transitionProgress * settleFactor;

    // Determine if pixel is inside the tilted screen quad
    bool isInside = (finalUV.x >= -edgeBleed && finalUV.x <= (1.0f + edgeBleed) &&
                     finalUV.y >= -edgeBleed && finalUV.y <= (1.0f + edgeBleed));

    float4 frameColor = float4(0.0f, 0.0f, 0.0f, 1.0f);

    if (isInside) {
        // 4. Sample and Blend Content with Frosted Glass Optical Model
        float4 sharpColor = screenTexture.sample(textureSampler, clamp(finalUV, 0.0f, 1.0f));

        if (frostAmount > 0.001f) {
            // Chromatic dispersion through screen-space grain facets
            float2 dispOffset = float2(0.0022f, 0.0012f) * frostAmount;
            float r = blurredTexture.sample(textureSampler, clamp(finalUV + dispOffset, 0.0f, 1.0f)).r;
            float g = blurredTexture.sample(textureSampler, clamp(finalUV, 0.0f, 1.0f)).g;
            float b = blurredTexture.sample(textureSampler, clamp(finalUV - dispOffset, 0.0f, 1.0f)).b;
            float4 dispersedBlurred = float4(r, g, b, 1.0f);

            float baseFrost = mix(0.40f, 0.88f, s) * frostAmount;
            float effectiveBlur = clamp(max(localBlur, baseFrost * uniforms.blurIntensity), 0.0f, 1.0f);
            frameColor = mix(sharpColor, dispersedBlurred, effectiveBlur);
        } else {
            float4 blurredColor = blurredTexture.sample(textureSampler, clamp(finalUV, 0.0f, 1.0f));
            frameColor = mix(sharpColor, blurredColor, localBlur);
        }

        // 5. Progressive Depth Shadow (Delayed to <= 70°)
        const float shadowStartAngleRad = 70.0f * (3.14159265f / 180.0f);
        const float shadowFullAngleRad  = 30.0f * (3.14159265f / 180.0f);
        float shadowActivation = smoothstep(shadowStartAngleRad, shadowFullAngleRad, targetAngle);

        float maxShadowTop = 2.0f;
        float maxShadowBottom = 1.0f;
        float depthShadow = mix(maxShadowBottom, maxShadowTop, s);
        float shadowAmount = clamp(sweepFactor * depthShadow * shadowActivation * transitionProgress * settleFactor * uniforms.shadowIntensity, 0.0f, 1.0f);
        frameColor.rgb *= (1.0f - shadowAmount);

        // 6. Simulated Keyboard Reflection (Active exclusively between 45° and 90°)
        if (uniforms.keyboardReflection > 0.001f && delta > 0.0001f && uniforms.settleProgress < 0.999f && currentTheta > minReflectAngleRad) {
            float4 kbReflect = sampleKeyboardReflection(finalUV, delta, currentTheta, uniforms, blurredTexture, textureSampler);
            float refAlpha = clamp(kbReflect.a * uniforms.keyboardReflection, 0.0f, 0.85f);
            frameColor.rgb = frameColor.rgb * (1.0f - 0.25f * refAlpha) + kbReflect.rgb * refAlpha;
        }

        // 7. Seamless Silhouette Edge Mask
        float distLeft   = max(-finalUV.x, 0.0f);
        float distRight  = max(finalUV.x - 1.0f, 0.0f);
        float distTop    = max(-finalUV.y, 0.0f);
        float outsideDist = max(max(distLeft, distRight), distTop);
        float borderMask = (edgeBleed > 0.0001f) ? (1.0f - smoothstep(0.0f, edgeBleed, outsideDist)) : (outsideDist <= 0.0f ? 1.0f : 0.0f);
        frameColor.rgb *= borderMask;
    }

    // 8. SCREEN-SPACE Frosted Glass Optical Layer (Directly on physical screen, NOT projected)
    if (frostAmount > 0.001f) {
        // Surface normal of the screen-space etched grain facets
        float bumpFactor = 0.92f * frostAmount;
        float3 grainNormal = normalize(float3(-screenGrain.gradient.x * bumpFactor, -screenGrain.gradient.y * bumpFactor, 1.0f));

        // Directional illumination across the physical laptop screen
        float3 screenLight = normalize(float3(0.20f, 0.55f, 0.81f));
        float grainShading = dot(grainNormal, screenLight);

        // Tactile grain pattern directly on the screen: highlights on ridges, micro-shadows in etched pits
        float ridgeHighlight = pow(max(grainShading, 0.0f), 2.2f) * 0.32f * frostAmount;
        float pitShadow = smoothstep(0.65f, 0.15f, screenGrain.height) * 0.18f * frostAmount;
        float grainRelief = (screenGrain.height - 0.45f) * 0.28f * frostAmount;

        // Crystalline silica micro-sparkle directly on the screen
        float crystalGlint = pow(screenGrain.microSparkle, 18.0f) * 0.35f * frostAmount;

        // Diffuse milky translucent haze across the screen
        float3 milkyMist = float3(0.92f, 0.94f, 0.98f);
        float mistIntensity = (0.065f + 0.045f * (1.0f - screenGrain.height)) * frostAmount;
        frameColor.rgb = mix(frameColor.rgb, milkyMist, mistIntensity);

        // Apply physical grain pattern on the screen
        frameColor.rgb = frameColor.rgb + float3(grainRelief) + float3(ridgeHighlight - pitShadow) + float3(crystalGlint);

        // Subtle satin sheen across the physical screen
        float screenSheen = (0.05f + 0.10f * (1.0f - uv.y)) * tiltAmount * frostAmount * (0.8f + 0.4f * screenGrain.height);
        frameColor.rgb += float3(0.95f, 0.97f, 1.0f) * screenSheen;
    }

    // 9. Background Dimming for Clock Mode (Subtly darkens background quad for contrast)
    if (uniforms.clockProgress > 0.001f) {
        float dimFactor = mix(1.0f, 0.52f, uniforms.clockProgress);
        frameColor.rgb *= dimFactor;
    }

    // 10. Digital Perspective Liquid Glass Clock Overlay (Rendered in 3D perspective over the dimmed background)
    if (uniforms.showClock > 0.5f && uniforms.clockProgress > 0.001f) {
        if (cleanPerspectiveUV.x >= 0.0f && cleanPerspectiveUV.x <= 1.0f &&
            cleanPerspectiveUV.y >= 0.0f && cleanPerspectiveUV.y <= 1.0f) {
            float4 clockPixel = clockTexture.sample(textureSampler, cleanPerspectiveUV);
            if (clockPixel.a > 0.01f) {
                float2 texStep = float2(1.0f / max(float(clockTexture.get_width()), 1.0f),
                                        1.0f / max(float(clockTexture.get_height()), 1.0f));
                float aL = clockTexture.sample(textureSampler, cleanPerspectiveUV - float2(texStep.x * 2.5f, 0.0f)).a;
                float aR = clockTexture.sample(textureSampler, cleanPerspectiveUV + float2(texStep.x * 2.5f, 0.0f)).a;
                float aT = clockTexture.sample(textureSampler, cleanPerspectiveUV - float2(0.0f, texStep.y * 2.5f)).a;
                float aB = clockTexture.sample(textureSampler, cleanPerspectiveUV + float2(0.0f, texStep.y * 2.5f)).a;
                float2 glassNormal2D = float2(aR - aL, aB - aT);

                // Optical liquid glass refraction of the 3D-warped background behind the digits
                float2 refractOffset = glassNormal2D * 0.022f;
                float2 refractUV = clamp(finalUV - refractOffset, 0.0f, 1.0f);
                float4 refSharp = screenTexture.sample(textureSampler, refractUV);
                float4 refBlur = blurredTexture.sample(textureSampler, refractUV);
                float3 glassBg = mix(refSharp.rgb, refBlur.rgb, 0.30f);

                // Chromatic dispersion through curved meniscus
                glassBg.r = mix(glassBg.r, screenTexture.sample(textureSampler, clamp(refractUV - glassNormal2D * 0.003f, 0.0f, 1.0f)).r, 0.35f);
                glassBg.b = mix(glassBg.b, screenTexture.sample(textureSampler, clamp(refractUV + glassNormal2D * 0.003f, 0.0f, 1.0f)).b, 0.35f);

                // Specular skylight reflection on liquid glass meniscus
                float rimGrad = length(glassNormal2D);
                float3 N = normalize(float3(-glassNormal2D * 1.8f, 1.0f));
                float3 L = normalize(float3(0.0f, -0.7f, 0.7f));
                float spec = pow(max(dot(N, L), 0.0f), 10.0f) * 0.28f;
                float rim = smoothstep(0.12f, 0.65f, rimGrad) * 0.22f;

                float3 liquidGlassColor = mix(glassBg, clockPixel.rgb, 0.62f) + float3(spec + rim);
                float clockAlpha = clockPixel.a * uniforms.clockProgress;
                frameColor.rgb = mix(frameColor.rgb, liquidGlassColor, clockAlpha);
            }
        }
    }

    // 11. Calibrator Overlay in Perspective (Rendered over/on top of frosted glass and clock for crisp readability)
    if (uniforms.showCalibrator > 0.5f) {
        if (cleanPerspectiveUV.x >= 0.0f && cleanPerspectiveUV.x <= 1.0f &&
            cleanPerspectiveUV.y >= 0.0f && cleanPerspectiveUV.y <= 1.0f) {
            float4 calib = calibratorTexture.sample(textureSampler, cleanPerspectiveUV);
            frameColor.rgb = frameColor.rgb * (1.0f - calib.a) + calib.rgb;
        }
    }

    return frameColor;
}

// MARK: - External Display Shader (Zoom Out, Progressive Blur, and Darken)
struct ExternalDisplayUniforms {
    float angle;            // Lid angle in radians
    float settleProgress;   // 0.0 (active) to 1.0 (settled back to flat 1:1)
    float maxZoomOut;       // Max zoom-out factor (e.g. 0.10)
    float maxBlur;          // Max blur factor (0.0 to 1.0)
    float maxDarken;        // Max darken factor (0.0 to 1.0)
    float aspect;           // Display aspect ratio
    float pad0;
    float pad1;
};

fragment float4 fragment_external_display(RasterizerData in [[stage_in]],
                                         texture2d<float> screenTexture [[texture(0)]],
                                         texture2d<float> blurredTexture [[texture(1)]],
                                         sampler textureSampler [[sampler(0)]],
                                         constant ExternalDisplayUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.texCoords;
    const float uprightRad = 1.5707963f; // 90° in radians

    // When fully settled, return clean original
    if (uniforms.settleProgress >= 0.999f) {
        return screenTexture.sample(textureSampler, uv);
    }

    // Blend target angle toward upright 90° when settling
    float targetAngle = mix(uniforms.angle, uprightRad, clamp(uniforms.settleProgress, 0.0f, 1.0f));
    float currentTheta = min(targetAngle, uprightRad);
    float delta = uprightRad - currentTheta;

    if (delta <= 0.0001f) {
        return screenTexture.sample(textureSampler, uv);
    }

    // Normalized progress: 0.0 at 90°, 1.0 at 15°
    float progress = clamp(delta / (75.0f * (3.14159265f / 180.0f)), 0.0f, 1.0f);
    float smoothP = smoothstep(0.0f, 1.0f, progress);

    // Settle factor: 1.0 when active, ramps to 0.0 during settle tween
    float settleFactor = 1.0f - clamp(uniforms.settleProgress, 0.0f, 1.0f);
    float activeProgress = smoothP * settleFactor;

    // 1. Progressive Zoom Out from screen center (no perspective / keystone)
    float zoomOutAmount = clamp(uniforms.maxZoomOut, 0.02f, 0.35f) * activeProgress;
    float scale = max(1.0f - zoomOutAmount, 0.40f);
    float2 centeredUV = (uv - 0.5f) / scale + 0.5f;

    // Progressive blur intensity
    float blurFactor = clamp(activeProgress * uniforms.maxBlur, 0.0f, 1.0f);

    // Dynamic rounded corner radius and soft optical blur falloff
    // cornerRadius provides a smooth Apple-style rounded window boundary
    // edgeBlurSpread softens the perimeter into a seamless Gaussian blur halo
    float cornerRadius = mix(0.002f, 0.090f, activeProgress);
    float edgeBlurSpread = mix(0.002f, 0.070f, blurFactor);

    // Aspect-corrected rounded box SDF (sdRoundedBox)
    // Eliminates diagonal miter creases by evaluating true circular Euclidean distance at corners
    float2 aspectScale = float2(uniforms.aspect, 1.0f);
    float2 p = abs(centeredUV - 0.5f) * aspectScale;
    float2 halfSize = float2(0.5f * uniforms.aspect, 0.5f);
    float2 q = p - halfSize + float2(cornerRadius);

    float outsideDist = length(max(q, float2(0.0f)));
    float insideDist = min(max(q.x, q.y), 0.0f);
    float sdf = outsideDist + insideDist - cornerRadius;

    // Early exit if completely beyond the soft blurred edge falloff
    if (sdf > edgeBlurSpread) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    // 2. Progressive Blur: sample textures with clamped coordinates to allow seamless outward edge bleed
    float2 sampleUV = clamp(centeredUV, 0.0f, 1.0f);
    float4 sharpCol = screenTexture.sample(textureSampler, sampleUV);
    float4 blurCol = blurredTexture.sample(textureSampler, sampleUV);
    float4 col = mix(sharpCol, blurCol, blurFactor);

    // 3. Progressive Darkening & Vignette
    float darkenFactor = clamp(activeProgress * uniforms.maxDarken, 0.0f, 0.85f);
    float2 vignetteOffset = (uv - 0.5f) * float2(uniforms.aspect, 1.0f);
    float vignetteDist = length(vignetteOffset);
    float vignette = smoothstep(0.35f, 1.15f, vignetteDist) * 0.20f * activeProgress;

    col.rgb *= (1.0f - darkenFactor) * (1.0f - vignette);

    // 4. Soft Rounded Edge Blur Falloff
    // Smoothly blends from full opacity inside to zero opacity outside along the rounded contour
    float edgeAlpha = 1.0f - smoothstep(-edgeBlurSpread, edgeBlurSpread, sdf);
    col.rgb = mix(float3(0.0f, 0.0f, 0.0f), col.rgb, edgeAlpha);

    return col;
}

