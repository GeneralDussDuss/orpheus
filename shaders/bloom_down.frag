#version 440
// Bloom: dual-Kawase downsample (half resolution, 5 taps over a 4x4 footprint).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;        // one source texel
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 s = texture(source, uv).rgb * 4.0;
    s += texture(source, uv - texel).rgb;
    s += texture(source, uv + texel).rgb;
    s += texture(source, uv + vec2(texel.x, -texel.y)).rgb;
    s += texture(source, uv - vec2(texel.x, -texel.y)).rgb;
    fragColor = vec4(s / 8.0, 1.0);
}
