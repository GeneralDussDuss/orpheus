#version 440
// Orpheus boot screen (Boot.qml): the whole boot layer passes through here.
//   power   0 -> 1  CRT power-on: the picture opens out of a lit line across
//                   the middle; outside the opening is the plain background
//   flick           brightness wobble for the first frames (1 = steady)
//   scan            faint scanlines, fading out as the screen warms up
//   reveal  0 -> 1  the boot screen dissolves cell by cell (one text cell
//                   each), left to right with a ragged front: each cell
//                   blinks to an accent block, then goes clear to show the
//                   library underneath
// Output is premultiplied; cleared cells are fully transparent.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;        // px
    vec2 cell;       // px, one text cell
    float power;
    float flick;
    float scan;
    float reveal;
    float seed;
    float light;     // 1 on light themes: the lit line becomes ink
    vec4 bg;
    vec4 accent;
};
layout(binding = 1) uniform sampler2D source;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * res;
    vec4 src = texture(source, uv);

    // ---- power-on ---------------------------------------------------------
    float p = clamp(power, 0.0, 1.0);
    float open = p * p * (3.0 - 2.0 * p);
    float halfH = mix(1.0, res.y * 0.5 + 2.0, open);          // px, half the opening
    float dy = abs(px.y - res.y * 0.5);
    float inside = 1.0 - smoothstep(halfH - 1.0, halfH + 1.0, dy);
    vec4 col = mix(bg, src * flick + bg * (1.0 - flick), inside);
    // the lit edge of the opening, gone once the screen is fully open
    float edge = exp(-pow((dy - halfH) / 1.6, 2.0)) * (1.0 - open);
    float core = exp(-pow(dy / 1.2, 2.0)) * (1.0 - p) * 0.8;  // the first line
    float lit = clamp(edge + core, 0.0, 1.0);
    vec3 hot = mix(mix(accent.rgb, vec3(1.0), 0.45), accent.rgb, light);
    col.rgb = mix(col.rgb, hot, lit);

    // ---- scanlines (dark themes only; QML passes 0 on light ones) ----------
    float sl = 0.5 + 0.5 * cos(px.y * 3.14159265);
    col.rgb *= 1.0 - clamp(scan, 0.0, 1.0) * 0.09 * sl;

    // ---- reveal -----------------------------------------------------------
    if (reveal > 0.0) {
        vec2 id = floor(px / max(cell, vec2(1.0)));
        float cols = max(1.0, res.x / max(cell.x, 1.0));
        float rows = max(1.0, res.y / max(cell.y, 1.0));
        // mostly left to right, a little from the middle row out, ragged
        float th = (id.x / cols) * 0.70 + abs(id.y / rows - 0.5) * 0.10 + hash(id + seed) * 0.20;
        const float blink = 0.07;
        float r = reveal * 1.04;               // th tops out near 0.95, + the blink
        float f = clamp((r - th) / blink, 0.0, 1.0);         // 0 untouched .. 1 gone
        if (f >= 1.0) {
            col = vec4(0.0);
        } else if (f > 0.0) {
            // the blink: an accent block that drains away
            float a = 1.0 - f;
            vec3 blk = mix(col.rgb, accent.rgb, 0.85);
            col = vec4(blk * a, a);
        }
    }
    fragColor = col * qt_Opacity;
}
