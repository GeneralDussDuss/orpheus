#version 440
// Orpheus album art for the shaders: the outgoing and incoming covers,
// crossfaded. Alpha says whether there is a cover at all, so a style can
// fall back to its own look where it is 0 (no art, or art switched off).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float artMix;    // 0 = all artPrev, 1 = all artCur
    float curOk;     // 1 when artCur has loaded
    float prevOk;
};
layout(binding = 1) uniform sampler2D artCur;
layout(binding = 2) uniform sampler2D artPrev;

void main() {
    vec2 uv = qt_TexCoord0;
    vec4 a = vec4(texture(artPrev, uv).rgb, 1.0) * prevOk;
    vec4 b = vec4(texture(artCur, uv).rgb, 1.0) * curOk;
    fragColor = mix(a, b, artMix);
}
