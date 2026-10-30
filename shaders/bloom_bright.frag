#version 440
// Bloom, pass 1: bright pass + first downsample. Each output pixel averages a
// 4x4 block of the source (four bilinear taps), keeping only what is above the
// threshold (soft knee). Taps are Karis-weighted (1 / (1 + luma)) so a single
// hot pixel cannot flare on its own and flicker as it moves.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;        // one source texel
    float threshold;   // brightness where bloom starts (half max channel, half luma)
    float knee;        // soft-knee half width
};
layout(binding = 1) uniform sampler2D source;

vec4 tap(vec2 uv) {
    vec3 c = min(texture(source, uv).rgb, vec3(4.0));   // premultiplied; HDR layer, so it can pass 1
    // Half luma so a pastel wash doesn't veil the whole frame, half max channel
    // so a saturated blue line still counts as bright.
    float br = 0.5 * max(c.r, max(c.g, c.b)) + 0.5 * dot(c, vec3(0.2126, 0.7152, 0.0722));
    float s = clamp(br - threshold + knee, 0.0, 2.0 * knee);
    s = s * s / (4.0 * knee + 1e-4);
    float w = max(s, br - threshold) / max(br, 1e-4);
    float k = 1.0 / (1.0 + dot(c, vec3(0.2126, 0.7152, 0.0722)));
    return vec4(c * w * k, k);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec4 s = tap(uv + vec2(-texel.x, -texel.y)) + tap(uv + vec2(texel.x, -texel.y))
           + tap(uv + vec2(-texel.x, texel.y)) + tap(uv + vec2(texel.x, texel.y));
    fragColor = vec4(s.rgb / s.a, 1.0);
}
