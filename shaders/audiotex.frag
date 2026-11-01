#version 440
// The audio texture user shaders read as iChannel0 (and iChannel2/3), in the
// shape Shadertoy's music input has: 512x2, row 0 the spectrum, row 1 the wave.
// Orpheus is handed 32 bands and no samples, so row 0 is real data (the bands,
// log-spaced and smoothly resampled over 512 texels, as every Orpheus style
// maps them) and row 1 is a plausible wave the bands drive.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 b0; vec4 b1; vec4 b2; vec4 b3; vec4 b4; vec4 b5; vec4 b6; vec4 b7;
    float time;
    float energy;
    float kick;
};

float bandAt(int i) {
    vec4 v[8] = vec4[8](b0, b1, b2, b3, b4, b5, b6, b7);
    i = clamp(i, 0, 31);
    return v[i / 4][i % 4];
}
float band(float x) {
    float f = clamp(x, 0.0, 1.0) * 31.0;
    int i = int(floor(f));
    return mix(bandAt(i), bandAt(i + 1), smoothstep(0.0, 1.0, fract(f)));
}

void main() {
    vec2 uv = qt_TexCoord0;
    float v;
    if (uv.y < 0.5) {
        v = pow(clamp(band(uv.x), 0.0, 1.0), 0.8);
    } else {
        float w = 0.0;
        float wk[8] = float[8](0.5, 0.4, 0.3, 0.25, 0.2, 0.15, 0.1, 0.1);
        for (int k = 0; k < 8; k++) {
            float fk = float(k);
            w += wk[k] * bandAt(4 * k) * sin(6.2832 * uv.x * (1.0 + 1.7 * fk) + time * (3.1 + 2.3 * fk));
        }
        w /= max(0.2, energy * 2.0);
        w += kick * 0.3 * sin(6.2832 * uv.x * 0.5);
        v = 0.5 + 0.45 * clamp(w, -1.0, 1.0);
    }
    fragColor = vec4(v, v, v, 1.0) * qt_Opacity;
}
