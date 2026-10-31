#version 440
// Orpheus feedback, display: this frame at full resolution, with the trails
// from the (smaller) feedback buffer showing through wherever they are
// brighter than it. The buffer already holds this frame too, softened by its
// lower resolution, so only what exceeds the crisp frame counts as trail.
//
// Drop effects ride on this pass (VizPost.qml turns it on for them): when the
// director's drop fires, a chromatic-aberration burst that dies within about a
// beat, a lens push and a shockwave ring out from the centre, then for the
// drop's tail a vignette that pulses with the kick and film grain that rises
// with loudness. A build tightens the vignette and lays in faint grain; the
// drop releases it. Light themes: no colour split, no ring, a whisper of the
// rest. With `fxOn` 0 this is exactly the plain trails composite.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float gain;      // how much of the trails shows (the feedback level, and less on light themes)
    float light;     // light theme: trails are laid over as ink; dark: screened on as light
    float fxOn;      // drop effects live (VizPost: the setting is on and a build or drop is in play)
    vec2 res;        // pixels (grain size, aspect)
    float time;
    float drop;      // 0..1, 1 at the drop, e^(-age/1.5); VizPost floors its tail to exactly 0
    float build;     // 0..1 tension, floored the same way
    float downbeat;  // 0..1 pulse on beat 1
    float kick;
    float swell;
    vec4 c1;
    vec4 c2;
};
layout(binding = 1) uniform sampler2D fresh;
layout(binding = 2) uniform sampler2D trail;

vec4 compose(vec4 F, vec4 C) {
    vec4 o;
    if (light < 0.5) {
        // Dark: only what the trails add beyond this frame, screened on.
        vec3 T = max(C.rgb - F.rgb, 0.0);
        float ta = max(T.r, max(T.g, T.b));
        o = vec4(F.rgb + T * (1.0 - min(F.rgb, 1.0)), F.a + ta * (1.0 - F.a));
    } else {
        // Ink: the trail's coverage beyond this frame's, laid under it.
        float k = clamp((C.a - F.a) / max(C.a, 1e-3), 0.0, 1.0);
        o = F + C * k * (1.0 - F.a);
    }
    return o;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void main() {
    vec2 uv = qt_TexCoord0;
    if (fxOn < 0.5) {
        fragColor = clamp(compose(texture(fresh, uv), texture(trail, uv) * gain), 0.0, 1.0) * qt_Opacity;
        return;
    }

    float dk = 1.0 - light;                           // dark-theme share
    float age = drop > 1e-4 ? -1.5 * log(drop) : 99.0;
    float tail = sqrt(drop);                          // the drop's afterglow, ~3 s
    float hit = exp(-age / 0.38);                     // the burst, gone within a beat or so
    float b = build * build;
    vec2 asp = vec2(res.x / max(res.y, 1.0), 1.0);
    vec2 dd = uv - 0.5;
    vec2 d = dd * asp;
    float r = length(d);
    vec2 dir = d / max(r, 1e-4) / asp;                // unit radial, back in uv

    // ---- lens: a push in on the drop (and a nudge on each downbeat after), and
    // a shockwave ring travelling out that bends the picture as it passes.
    float lens = mix(0.5, 1.0, dk);
    float push = (0.032 * exp(-age / 0.16) + 0.010 * downbeat * tail) * lens;
    vec2 su = 0.5 + dd * (1.0 - push);
    float R = age * 1.8;
    float w = 0.07 + 0.12 * age;
    float x = (r - R) / w;
    float ring = x * exp(-x * x);                     // + ahead of the front, - behind: a refracting bulge
    float amp = 0.030 * exp(-age / 0.42) * smoothstep(0.0, 0.04, age) * lens;
    su -= dir * amp * ring;

    // ---- chromatic aberration: radial, red out and blue in, none on light themes.
    float ca = (0.9 * hit + 0.16 * kick * tail + 0.10 * b) * dk;
    vec2 sp = dd * 0.008 * ca + dir * amp * ring * 0.35 * dk;   // the ring splits a little too
    vec4 G = texture(fresh, su);
    vec4 F = G;
    if (ca > 0.002) {
        // Two taps per outer channel, so the fringes smear like a lens instead
        // of stacking into three hard copies.
        vec4 Rc = (texture(fresh, su + sp) + texture(fresh, su + sp * 0.5)) * 0.5;
        vec4 Bc = (texture(fresh, su - sp) + texture(fresh, su - sp * 0.5)) * 0.5;
        F = vec4(Rc.r, G.g, Bc.b, max(G.a, max(Rc.a, Bc.a)));
    }
    vec4 o = compose(F, texture(trail, su) * gain);

    // The shockwave's front catches a thin line of the palette's light.
    float front = exp(-x * x * 6.0) * exp(-age / 0.32) * smoothstep(0.0, 0.05, age) * dk;
    vec3 rc = mix(c1.rgb, c2.rgb, 0.5 + 0.5 * dd.x);
    float fk = front * 0.22;
    o = vec4(o.rgb + (1.0 - o.rgb) * rc * fk, max(o.a, fk));

    // ---- vignette: tightens through a build, pulses with the kick in the drop.
    // Laid over as coverage, so it darkens what is behind the visualizer too.
    vec2 q = dd * 2.0;
    float vr = length(q * vec2(1.0, 0.9));
    float inner = 0.85 - 0.30 * build - 0.18 * kick * tail;
    float vig = smoothstep(inner, inner + 0.75, vr);
    float vs = (0.32 * build + (0.18 + 0.30 * kick) * tail) * mix(0.3, 1.0, dk);
    float vk = clamp(vs * vig, 0.0, 0.75);
    vec3 vc = light > 0.5 ? c1.rgb * 0.35 : vec3(0.0);
    o = vec4(o.rgb * (1.0 - vk) + vc * vk, o.a * (1.0 - vk) + vk);

    // ---- film grain: per pixel, per frame, rising with loudness in the drop.
    float g = ((0.016 + 0.040 * swell) * tail + 0.020 * b) * mix(0.3, 1.0, dk);
    float n = hash(floor(uv * res) + fract(time * 7.31) * vec2(113.0, 271.0)) - 0.5;
    n += hash(floor(uv * res) * 1.37 + fract(time * 3.17) * vec2(37.0, 191.0)) - 0.5;   // two taps: less salt, more film
    float gn = n * g;
    o.rgb = max(o.rgb + gn, 0.0);
    o.a = max(o.a, abs(gn));

    fragColor = clamp(o, 0.0, 1.0) * qt_Opacity;
}
