layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
    vec2 res;
    vec4 b0; vec4 b1; vec4 b2; vec4 b3; vec4 b4; vec4 b5; vec4 b6; vec4 b7;
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5; vec4 p6; vec4 p7;
    vec4 c1;
    vec4 c2;
    vec4 c3;
    vec4 bg;
    vec4 fg;
    float bass;
    float energy;
    float light;
    float beat;      // 0..1 kick transient (bass jumping above its own average), decays fast
    float flow;      // distance the world has travelled toward the camera, in world
                     // units. Integrated on the CPU from a tempo-driven speed, so
                     // use this (never time * speed) for anything that comes at you:
                     // changing pace then bends the motion instead of teleporting it.
    float tempo;     // beat pace, 1.0 = 120 BPM, confidence-weighted toward rest
    float kick;      // 0..1 low-end onset: instant attack, ~0.22 s release (slower than beat)
    float snap;      // 0..1 mid/high onset (snares, hats): instant attack, ~0.12 s release
    float swell;     // 0..1 loudness envelope: ~0.2 s attack, ~1.4 s release (for camera push-in)
    float kicks;     // kick counter, whole steps wrapping at 1024: hash(vec2(kicks)) varies per kick
    vec4 kickAge;    // seconds since each of the last three kicks, newest first (x, y, z), capped
                     // at 8.0; w = strength (0..1) of the newest. Lets kick effects layer.
    float bloomAmt;  // 0 = no post bloom over this view, 0.6 subtle, 1.0 full (Viz.qml / Bloom.qml)
    // ---- the director (Service.qml): beat grid and song structure ----
    float beatPhase;      // 0..1 position inside the current beat, 0 = ON the beat. Predicted
                          // (lookahead-compensated), so effects keyed to it land with the music
    float barPhase;       // 0..1 position inside the 4-beat bar, 0 = the downbeat
    float downbeat;       // 0..1 pulse on beat 1 of each bar: 1 at the downbeat, ~0.25 s release
    float beatConfidence; // 0..1 how sure the beat grid is; fade phase-driven effects by it
    float build;          // 0..1 tension of a build-up (rising energy and hats, sub-bass gone)
    float drop;           // 0..1 pulse when a build resolves on a downbeat: 1 at the drop, ~1.5 s release
    float section;        // 0 intro, 1 build, 2 drop, 3 breakdown, 4 steady (whole numbers)
};

// 32 cava bands packed as 8 vec4s; band(x) samples them smoothly over 0..1.
float bandAt(int i) {
    vec4 v[8] = vec4[8](b0, b1, b2, b3, b4, b5, b6, b7);
    i = clamp(i, 0, 31);
    return v[i / 4][i % 4];
}
float peakAt(int i) {
    vec4 v[8] = vec4[8](p0, p1, p2, p3, p4, p5, p6, p7);
    i = clamp(i, 0, 31);
    return v[i / 4][i % 4];
}
float band(float x) {
    float f = clamp(x, 0.0, 1.0) * 31.0;
    int i = int(floor(f));
    return mix(bandAt(i), bandAt(i + 1), smoothstep(0.0, 1.0, fract(f)));
}

vec3 pal(float x) {
    x = clamp(x, 0.0, 1.0);
    if (x < 0.5) return mix(c1.rgb, c2.rgb, x * 2.0);
    return mix(c2.rgb, c3.rgb, (x - 0.5) * 2.0);
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// ---- premium helpers ---------------------------------------------------------

// 1px anti-aliased coverage of the axis-aligned box lo..hi at pixel p.
float boxAA(vec2 p, vec2 lo, vec2 hi) {
    vec2 d = min(p - lo, hi - p);
    return clamp(min(d.x, d.y) + 0.5, 0.0, 1.0);
}

// Coverage of a parallelogram: x in [x0 + t*dx, x0 + w + t*dx] for t = (y - y0) / dy in 0..1.
float shearAA(vec2 p, float x0, float y0, float w, float dx, float dy) {
    float t = (p.y - y0) / dy;
    float edgeY = min(p.y - y0, y0 + dy - p.y);
    float lx = p.x - (x0 + t * dx);
    float edgeX = min(lx, w - lx);
    return clamp(min(edgeX, edgeY) + 0.5, 0.0, 1.0);
}

// Soft glow falloff: 1 at d = 0, fading over `r` pixels.
float glow(float d, float r) { return exp(-(d * d) / (r * r)); }

// Blend `src` over `dst` (both premultiplied-free rgb + coverage a).
vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(mix(dst.rgb, rgb, a), dst.a + a * (1.0 - dst.a)); }

// Tiny ordered noise so gradients don't band on 8-bit output.
vec3 dither(vec2 p) { return vec3((hash(p) - 0.5) / 255.0); }

// Additive light that switches off on light themes (glow reads as smudge there).
float lit(float x) { return x * (1.0 - 0.85 * light); }

// A shader-drawn halo that the real bloom pass now also draws: dialled down by
// `k` (0..1) at full bloom, so the two don't stack into white. With bloom off
// (the setting, light themes, auto quality's last step) it is untouched.
float faux(float x, float k) { return x * (1.0 - k * bloomAmt); }

// ---- camera: one slow, shared motion so every style feels alive --------------
// Roll angle (radians): a slow wander, nudged by kicks.
float camRoll() { return sin(time * 0.17) * 0.035 + sin(time * 0.071 + 1.7) * 0.02 + beat * 0.012 * sin(time * 9.0); }
// Bob: a gentle up/down drift in pixels for a view `h` tall.
float camBob(float h) { return (sin(time * 0.31) * 0.008 + sin(time * 0.13 + 0.6) * 0.006) * h; }
// Rotate pixel p around `pivot` by `a`.
vec2 rotateAround(vec2 p, vec2 pivot, float a) {
    vec2 d = p - pivot;
    return pivot + vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a));
}
// Road bend: how far (as a fraction of the width) a row at depth `z` rows is
// pushed sideways. Quadratic in depth, so the road curves away; the bend
// itself wanders slowly and swings wider when the music is loud.
float roadBend(float z) {
    float b = sin(time * 0.23) * 0.9 + sin(time * 0.11 + 1.3) * 0.6;
    return b * (0.6 + energy * 0.8) * z * z * 0.00014;
}
