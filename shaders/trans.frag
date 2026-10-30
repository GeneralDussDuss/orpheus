#version 440
// Orpheus style transition: the outgoing style (a) and the incoming one (b),
// both live, blended through one of four moves while `prog` runs 0 -> 1.
//   0 glitch slice   bands of the screen tear sideways and flip over one by one
//   1 zoom through   the old view rushes past the camera and the new one flies in after it
//   2 radial dissolve  the new style grows out of the centre behind a lit, ragged front
//   3 chroma split   both views tear into their colour channels and cross over
// Only runs while a transition is in flight.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float prog;      // 0..1, eased
    float kind;
    float seed;
    float light;
    vec4 c1;
    vec4 c2;
    vec4 c3;
};
layout(binding = 1) uniform sampler2D a;
layout(binding = 2) uniform sampler2D b;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 x) {
    vec2 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
vec4 tap(sampler2D s, vec2 uv) {
    vec2 e = step(vec2(0.0), uv) * step(uv, vec2(1.0));
    return texture(s, clamp(uv, 0.0, 1.0)) * e.x * e.y;
}
// Light added on top, premultiplied: dimmed to ink on light themes.
vec4 lightUp(vec4 c, vec3 rgb, float k) {
    k = clamp(k, 0.0, 1.0) * (1.0 - 0.6 * light);
    return vec4(c.rgb + (1.0 - c.rgb) * rgb * k, max(c.a, k));
}

void main() {
    vec2 uv = qt_TexCoord0;
    float p = clamp(prog, 0.0, 1.0);
    float mid = sin(3.14159265 * p);                  // 0 at both ends, 1 halfway
    vec2 asp = vec2(res.x / max(res.y, 1.0), 1.0);
    vec4 o;

    if (kind < 0.5) {
        // ---- glitch slice ----
        float rows = 9.0 + floor(hash(vec2(seed, 1.0)) * 10.0);
        float y = uv.y * rows;
        float id = floor(y + vnoise(vec2(uv.x * 3.0, seed)) * 0.4);
        float hs = hash(vec2(id, seed));
        float t = smoothstep(hs * 0.7, hs * 0.7 + 0.3, p);          // this band's own moment
        float tear = (hash(vec2(id, seed + 7.0)) - 0.5) * 0.22 * sin(3.14159265 * t);
        float jit = (hash(vec2(id, floor(p * 24.0) + seed)) - 0.5) * 0.03 * mid;
        vec2 ua = uv + vec2(tear + jit, 0.0);
        vec2 ub = uv - vec2(tear * 0.6 - jit, 0.0);
        float split = 0.012 * sin(3.14159265 * t);
        vec4 A = vec4(tap(a, ua + vec2(split, 0.0)).r, tap(a, ua).g, tap(a, ua - vec2(split, 0.0)).b, tap(a, ua).a);
        vec4 B = vec4(tap(b, ub - vec2(split, 0.0)).r, tap(b, ub).g, tap(b, ub + vec2(split, 0.0)).b, tap(b, ub).a);
        o = mix(A, B, step(0.5, t));
        // A thin hot seam on the bands that are mid-flip.
        float seam = (1.0 - smoothstep(0.0, 0.06, abs(fract(y) - 0.5) - 0.44)) * step(0.05, t) * step(t, 0.95);
        o = lightUp(o, mix(c1.rgb, c3.rgb, hs), seam * 0.5 * mid);
    } else if (kind < 1.5) {
        // ---- zoom through ----
        vec2 c = vec2(0.5);
        float za = 1.0 + 2.4 * p * p;                                // old view rushes past
        float zb = 1.0 + 0.7 * (1.0 - smoothstep(0.0, 1.0, p));      // the new one is already close, and settles
        vec4 A = vec4(0.0), B = vec4(0.0);
        for (int i = 0; i < 4; i++) {                                // a little radial blur for the speed
            float f = float(i) / 3.0;
            A += tap(a, c + (uv - c) / (za * (1.0 + f * 0.06 * mid)));
            B += tap(b, c + (uv - c) / (zb * (1.0 + f * 0.04 * mid)));
        }
        A *= 0.25; B *= 0.25;
        float w = smoothstep(0.25, 0.75, p);
        o = A * (1.0 - w) + B * w;
        float r = length((uv - c) * asp);
        o = lightUp(o, mix(c2.rgb, vec3(1.0), 0.3), exp(-r * r * 6.0) * mid * mid * 0.35);
    } else if (kind < 2.5) {
        // ---- radial dissolve ----
        vec2 d = (uv - 0.5) * asp;
        float r = length(d);
        float ang = atan(d.y, d.x);
        float n = vnoise(vec2(ang * 2.5 + seed * 13.0, r * 6.0 - p * 3.0)) * 0.6 + vnoise(vec2(ang * 7.0, seed + p * 2.0)) * 0.4;
        float R = p * 1.25 - 0.12 + (n - 0.5) * 0.22;
        float edge = (R - r) / 0.025;
        float w = clamp(edge * 0.5 + 0.5, 0.0, 1.0);
        // The front bends the old view outward as it passes.
        vec2 push = d / max(r, 1e-3) * 0.025 * exp(-pow((r - R) / 0.08, 2.0)) / asp;
        o = mix(tap(a, uv - push), tap(b, uv), w);
        float front = exp(-pow((r - R) / 0.012, 2.0)) * smoothstep(0.0, 0.1, p) * smoothstep(1.0, 0.85, p);
        o = lightUp(o, mix(c1.rgb, c2.rgb, n), front * 0.8);
    } else {
        // ---- chroma split ----
        vec2 dir = normalize(vec2(hash(vec2(seed, 3.0)) - 0.5, hash(vec2(seed, 5.0)) - 0.5) + 1e-3) / asp;
        float s = 0.035 * mid;
        vec4 A = vec4(tap(a, uv + dir * s * 1.6).r, tap(a, uv + dir * s * 0.4).g, tap(a, uv - dir * s).b, tap(a, uv).a);
        vec4 B = vec4(tap(b, uv - dir * s).r, tap(b, uv - dir * s * 0.4).g, tap(b, uv + dir * s * 1.6).b, tap(b, uv).a);
        // Channels cross over at slightly different moments: red leads, blue trails.
        vec3 w = smoothstep(vec3(0.25, 0.35, 0.45), vec3(0.55, 0.65, 0.75), vec3(p));
        o = vec4(mix(A.rgb, B.rgb, w), mix(A.a, B.a, w.g));
        // Scanline shimmer at the peak of the split.
        float sl = 0.5 + 0.5 * sin(uv.y * res.y * 1.2);
        o.rgb *= 1.0 - 0.12 * mid * sl;
    }
    fragColor = clamp(o, 0.0, 1.0) * qt_Opacity;
}
