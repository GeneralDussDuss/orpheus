#version 440
// Orpheus Monolith deck: the status LED in its hole. A domed lens that lights
// in the accent and breathes with the beat while playing, with a halo on the
// face around it (scaled by the bloom budget); dark glass when paused.
// The item is padded round the lens so the halo fits.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float bloomAmt;
    float level;     // 0 dark .. 1 full
    float lens;      // the lens radius, px
    vec4 accent;
    vec4 metal;
};

float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

void main() {
    vec2 p = qt_TexCoord0 * res;
    vec2 c = res * 0.5;
    vec2 d = p - c;
    float r = length(d);
    vec3 A = accent.rgb;
    vec4 o = vec4(0.0);
    // the halo on the face
    float halo = exp(-max(0.0, r - lens) / (lens * 1.1)) * step(lens, r) * level * bloomAmt * 0.8;
    halo = min(halo, 1.0);
    o = vec4(A * halo, halo * 0.9);
    if (r < lens + 0.5) {
        float dome = sqrt(max(0.0, 1.0 - r * r / (lens * lens)));
        vec3 off = mix(metal.rgb * 0.12, A * 0.18, 0.5) * (0.6 + 0.4 * dome);
        vec3 on = mix(A, vec3(1.0), 0.45 * pow(dome, 4.0)) * (0.75 + 0.45 * dome);
        vec3 col = mix(off, on, level);
        // the lens's highlight, lit or not
        col += vec3(1.0) * 0.35 * ss(lens * 0.45, 0.0, length(d - vec2(-0.35, -0.4) * lens));
        // its rim, a hairline of shade
        col *= mix(0.6, 1.0, ss(lens, lens - 1.0, r));
        float a = clamp(lens + 0.5 - r, 0.0, 1.0);
        o = vec4(col * a, a) + o * (1.0 - a);
    }
    fragColor = o * qt_Opacity;
}
