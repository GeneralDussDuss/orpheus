#version 440
// Orpheus "Halo": the spectrum wrapped into a ring. 64 bars radiate out of a
// glowing circle, mirrored left and right so the bass sits at the bottom and
// the treble meets at the top; each bar casts a shorter reflection inward.
// Peak dots float off the tips, a smooth contour breathes inside the ring,
// the halo sways gently, and every kick throws a shockwave outward.
// Everything is closed-form per pixel (no loops), so it costs about as little
// as a shader can.

//#common

const float PI = 3.14159265;
const float SLOTS = 64.0;    // 32 bands, mirrored

void main() {
    float m = min(res.x, res.y);
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 c = res * 0.5 + vec2(0.0, camBob(res.y));
    vec2 p = rotateAround(px, c, camRoll()) - c;            // pixels from the centre
    float r = length(p) + 1e-4;

    float R0 = m * (0.20 + bass * 0.025 + beat * 0.015);   // the ring breathes with the bass
    float L = m * 0.21;                                      // longest bar, outward
    float spin = sin(time * 0.07) * 0.05;                    // a slow sway; bass stays roughly below

    // Angle from straight down, 0..1 around the circle, then mirrored to 0..1 of the
    // spectrum: bass at the bottom, treble meeting at the top.
    float a = fract(atan(p.x, -p.y) / (2.0 * PI) + 0.5 + spin);
    float slot = floor(a * SLOTS);
    float sf = fract(a * SLOTS);
    float u = abs((slot + 0.5) / SLOTS - 0.5) * 2.0;        // 0 = bass (bottom), 1 = treble (top)
    int bi = int(clamp(floor(u * 32.0), 0.0, 31.0));
    float v = bandAt(bi);
    float pk = peakAt(bi);
    vec3 tint = pal(u);
    float heat = smoothstep(0.35, 1.0, v);
    vec3 hot = mix(tint, vec3(1.0), (0.10 + 0.45 * heat) * (1.0 - light));

    vec4 col = vec4(0.0);    // premultiplied

    // Bars: lateral distance in pixels is the arc length to the slot's centre line.
    float arc = 2.0 * PI * r / SLOTS;
    float lat = abs(sf - 0.5) * arc;
    float halfW = arc * 0.30;
    float latA = clamp(halfW - lat + 0.5, 0.0, 1.0);
    float h = max(2.0, v * L);
    float outA = clamp(min(r - R0, R0 + h - r) + 0.5, 0.0, 1.0) * latA;
    float hIn = max(1.0, v * L * 0.35);
    float inA = clamp(min(R0 - r, r - (R0 - hIn)) + 0.5, 0.0, 1.0) * latA;

    float t = clamp((r - R0) / h, 0.0, 1.0);
    vec3 barCol = mix(tint * 0.55, hot, pow(t, 1.2));
    barCol += lit(smoothstep(h - 3.0, h, r - R0)) * 0.25 * tint;   // bright tip
    col.rgb += (1.0 - col.a) * outA * barCol;
    col.a += (1.0 - col.a) * outA;
    float inFade = 1.0 - clamp((R0 - r) / hIn, 0.0, 1.0);
    float ia = inA * (0.25 + 0.35 * inFade);
    col.rgb += (1.0 - col.a) * ia * tint * 0.8;
    col.a += (1.0 - col.a) * ia;

    // Peak dots: a small cap that floats off each bar's tip.
    float pr = R0 + max(v, pk) * L + m * 0.012;
    float dotA = clamp(min(halfW - lat, m * 0.004 - abs(r - pr)) + 0.5, 0.0, 1.0) * step(0.02, pk);
    col.rgb += (1.0 - col.a) * dotA * mix(tint, fg.rgb, 0.5);
    col.a += (1.0 - col.a) * dotA;

    // Bloom off the bar tips.
    float tipGlow = lit(glow(r - (R0 + h), m * 0.035) * glow(lat, arc * 0.9) * heat * (0.6 + beat * 0.6));
    col.rgb += tipGlow * tint;
    col.a += tipGlow * 0.5;

    // The ring itself: a crisp hairline and a wide soft glow that swells with the bass.
    float ringLine = clamp(1.4 - abs(r - R0), 0.0, 1.0);
    float ringGlow = lit(glow(r - R0, m * (0.03 + bass * 0.04)) * (0.25 + bass * 0.6 + beat * 0.5));
    vec3 ringCol = mix(c1.rgb, c2.rgb, 0.5 + 0.5 * sin(a * 2.0 * PI * 2.0 + time * 0.4));
    col.rgb += (1.0 - col.a) * ringLine * 0.8 * ringCol + ringGlow * ringCol;
    col.a += (1.0 - col.a) * ringLine * 0.8 + ringGlow * 0.4;

    // Inner contour: the spectrum again as one smooth closed line, slowly counter-rotating.
    float a2 = fract(atan(p.x, -p.y) / (2.0 * PI) + 0.5 - spin * 1.6);
    float u2 = abs(a2 - 0.5) * 2.0;
    float rc = R0 * (0.62 + band(u2) * 0.30);
    float cl = 1.0 - smoothstep(0.6, 1.8, abs(r - rc));
    float cg = lit(glow(r - rc, m * 0.02)) * 0.35;
    vec3 cc = mix(c3.rgb, c2.rgb, u2);
    col.rgb += (1.0 - col.a) * cl * 0.75 * cc + cg * cc * (0.4 + energy);
    col.a += (1.0 - col.a) * cl * 0.75 + cg * 0.3;

    // Core: a dim lens that warms with the bass.
    float core = lit(glow(r, R0 * 0.55) * (0.10 + bass * 0.35 + beat * 0.3));
    col.rgb += core * c1.rgb;
    col.a += core * 0.6;

    // Kick shockwave: beat decays from 1 toward 0, so the ring expands as it fades.
    float sw = R0 + L * 0.2 + (1.0 - beat) * m * 0.45;
    float swA = lit(glow(r - sw, m * 0.008 + (1.0 - beat) * m * 0.02) * beat * 0.7);
    col.rgb += swA * mix(c2.rgb, fg.rgb, 0.3);
    col.a += swA * 0.5;

    col.a = clamp(col.a, 0.0, 1.0);
    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
