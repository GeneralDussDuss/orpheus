#version 440
// Orpheus feedback, MilkDrop style: last frame's composite, warped (zoom,
// rotation, swirl, ripple, smoke, drift around a per-style centre), decayed
// and pulled a little toward the theme palette, with this frame's visualizer
// laid over it. Renders into its own previous output (a recursive source), in
// half float so slow decays fade all the way out instead of sticking at 1/255.
// Premultiplied throughout, so trails fade to transparent (the background).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;        // the view's size (for aspect)
    vec4 warpA;      // x zoom per frame (>1 pushes outward), y rotation (rad/frame), z swirl (rad/frame at the centre), w ripple
    vec4 warpB;      // xy drift (uv/frame, +y = up), z decay (linear light, per frame), w palette pull per frame
    vec4 warpC;      // xy centre (uv), z radial smear, w smoke turbulence
    vec4 c1;
    vec4 c2;
    vec4 c3;
    float time;
    float amount;    // 0 = clear (feedback just switched on, or off)
    float light;     // light theme: trails are ink (coverage) instead of light
};
layout(binding = 1) uniform sampler2D prev;
layout(binding = 2) uniform sampler2D fresh;

vec3 pal(float x) {
    x = fract(x) * 3.0;
    if (x < 1.0) return mix(c1.rgb, c2.rgb, x);
    if (x < 2.0) return mix(c2.rgb, c3.rgb, x - 1.0);
    return mix(c3.rgb, c1.rgb, x - 2.0);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec4 F = texture(fresh, uv);
    if (amount <= 0.0) { fragColor = F; return; }

    vec2 asp = vec2(res.x / max(res.y, 1.0), 1.0);
    vec2 ctr = warpC.xy;
    vec2 d = (uv - ctr) * asp;
    float r = length(d);

    // Zoom: sample nearer the centre, so the image grows outward.
    d /= warpA.x;
    // Rotation, plus a swirl that turns the middle faster than the edges.
    float a = warpA.y + warpA.z * exp(-r * r * 6.0);
    float ca = cos(a), sa = sin(a);
    d = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
    // Ripple: a radial wave travelling outward bends the sample point in and out.
    if (warpA.w > 0.0) d *= 1.0 - warpA.w * sin(r * 34.0 - time * 5.0) * smoothstep(0.02, 0.15, r);
    // Smoke: a slow curling flow field.
    if (warpC.w > 0.0) {
        vec2 q = uv * vec2(5.0, 4.0);
        d += warpC.w * vec2(sin(q.y * 1.7 + time * 0.9) + 0.5 * sin(q.y * 4.1 - time * 1.3 + q.x),
                            cos(q.x * 1.9 - time * 0.7) + 0.5 * cos(q.x * 3.7 + time * 1.1 + q.y));
    }
    vec2 suv = ctr + d / asp - vec2(warpB.x, -warpB.y);

    vec4 P = texture(prev, suv);
    // Radial smear: two more taps toward the centre stretch streaks outward.
    if (warpC.z > 0.0) {
        vec2 st = (suv - ctr) * warpC.z;
        P = P * 0.5 + texture(prev, suv - st) * 0.3 + texture(prev, suv - st * 2.0) * 0.2;
    }
    vec2 edge = step(vec2(0.0), suv) * step(suv, vec2(1.0));
    P *= edge.x * edge.y;

    // Decay and palette pull in linear light, then a ceiling, so stacked light
    // can never accumulate to white: a static highlight converges below it.
    vec3 lin = pow(max(P.rgb, 0.0), vec3(2.2));
    float lum = dot(lin, vec3(0.2126, 0.7152, 0.0722));
    float peak = max(lin.r, max(lin.g, lin.b));
    // The palette pull walks the hue with brightness, distance and time, so
    // old light cycles through the theme's colours as it fades (white echoes
    // become coloured ones instead of a grey veil).
    vec3 tgt = pow(pal(lum * 1.5 + r * 0.6 + time * 0.03), vec3(2.2));
    tgt *= peak / max(max(tgt.r, max(tgt.g, tgt.b)), 1e-3);
    lin = mix(lin, tgt, warpB.w);
    lin *= warpB.z;
    lin = min(lin, vec3(0.4));
    lin = max(lin - 0.0006, 0.0);                    // the last whisper of a trail goes to zero
    float pa = max(P.a * pow(warpB.z, 0.4545) - 0.002, 0.0);
    P = vec4(pow(lin, vec3(0.4545)), pa) * amount;

    // Only what stands out of the frame feeds the trails: light on dark
    // themes, ink on light ones. Backgrounds, walls and the vignette would
    // otherwise smear into a grey veil.
    vec3 fc = F.rgb / max(F.a, 1e-3);
    float ink = F.a * (1.0 - dot(fc, vec3(0.2126, 0.7152, 0.0722)));
    float stand = mix(smoothstep(0.30, 0.85, max(F.r, max(F.g, F.b))), smoothstep(0.25, 0.6, ink), light);
    vec4 Fh = F * stand;
    // Lighten, not add: an echo never stacks on another, so a busy frame
    // leaves trails of its brightest moments instead of filling up with haze.
    fragColor = max(Fh, P);
}
