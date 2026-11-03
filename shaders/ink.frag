#version 440
// Orpheus "Ink": dye in water, driven by the music. The fluid itself lives in
// a smaller half-float buffer (inkstate.frag, advanced every frame in
// Viz.qml); this pass only looks at it. Density becomes colour, thin wisps
// stay translucent and dense cores turn rich, and the density's gradient is
// read as a surface: a soft key light from the upper left shades every fold
// and a small specular glint sits on the steepest ones, so the dye reads as a
// physical, slightly glossy liquid rather than a flat gradient.
// Dark themes: luminous dye over deep water. Light themes: ink on paper, dark
// pigment that pools at its edges like a wash.

//#common

layout(binding = 1) uniform sampler2D inkState;

float lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float mx(vec3 c) { return max(c.r, max(c.g, c.b)); }

// Thickness of the dye at uv, 0..1.
float thick(vec2 uv) { return 1.0 - exp(-texture(inkState, uv).a * 1.1); }

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = vec2(uv.x, 1.0 - uv.y) * res;
    // About one state texel (the buffer is ~0.4 of the view, at most 1280 wide).
    float sw = min(res.x * 0.4, 1280.0);
    vec2 ts = vec2(1.0 / sw, res.x / (sw * res.y));

    vec4 S = texture(inkState, uv);
    float d = S.a;
    float T = 1.0 - exp(-d * 1.1);
    // Mixed dyes average their colour; restore the palette's brightness so
    // overlaps stay vivid instead of going grey.
    vec3 dye = S.rgb / max(d, 1e-4);
    float palMax = (mx(c1.rgb) + mx(c2.rgb) + mx(c3.rgb)) / 3.0;
    dye = dye / max(mx(dye), 1e-3) * mix(mx(dye), palMax, 0.75);
    dye = clamp(dye, 0.0, 1.0);

    // ---- the dye as a surface: normal from the thickness gradient -------------
    float tx = thick(uv + vec2(ts.x, 0.0)) - thick(uv - vec2(ts.x, 0.0));
    float ty = thick(uv + vec2(0.0, ts.y)) - thick(uv - vec2(0.0, ts.y));
    vec2 g = vec2(tx, -ty);                      // y up
    vec3 n = normalize(vec3(-g * 2.2, 1.0));
    vec3 L = normalize(vec3(-0.45, 0.55, 0.75));
    float diff = clamp(dot(n, L), 0.0, 1.0);
    float shade = 1.0 + 0.9 * (diff - L.z);      // 1 on flat dye, lighter/darker on folds
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float spec = pow(clamp(dot(n, H), 0.0, 1.0), 60.0) * smoothstep(0.02, 0.18, length(g));
    float edge = smoothstep(0.03, 0.25, length(g));

    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.25, 0.9, length(vq * vec2(1.0, 0.85)));
    float loud = clamp(max(swell, energy), 0.0, 1.0);

    vec3 col;
    if (light < 0.5) {
        // Deep water: the theme background pushed down, a faint palette cast
        // pooled low in the frame, darker at the corners.
        vec3 deep = bg.rgb * 0.42 + c1.rgb * 0.025 * (1.0 - uv.y) + c3.rgb * 0.02 * uv.y;
        deep *= 1.0 - vig * 0.55;
        // Luminous dye: thin wisps translucent and deeper toned, thick cores
        // rich and a touch hotter. Light scattered inside it glows a little.
        vec3 body = dye * mix(0.55, 1.0, T) * shade;
        body += dye * dye * smoothstep(0.6, 1.0, T) * 0.15;
        col = mix(deep, body, T);
        col += dye * faux(T * T * 0.14 * (0.6 + loud * 0.6), 0.8);
        col += vec3(spec) * lit(0.35) * (0.4 + 0.6 * T) * (1.0 - 0.5 * bloomAmt);
    } else {
        // Ink on paper: the background as the sheet, a hint of fibre, the dye
        // darkened to pigment that collects at the edges of each wash.
        float fibre = hash(floor(px * 0.5)) * 0.018 + sin(px.y * 0.21 + sin(px.x * 0.013) * 4.0) * 0.004;
        vec3 paper = mix(bg.rgb, vec3(1.0), 0.25) - fibre;
        paper *= 1.0 - vig * 0.08;
        vec3 pig = pow(dye, vec3(1.6)) * 0.62;
        float cover = clamp(T * 0.88 + edge * 0.12 * T, 0.0, 0.96);
        vec3 inked = pig * mix(1.15, 0.85, diff) * mix(1.0, 0.7, edge);
        col = mix(paper, inked, cover);
        col += vec3(spec) * 0.12 * T;
    }

    fragColor = vec4(col + dither(px), 1.0) * qt_Opacity;
}
