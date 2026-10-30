#version 440
// Bloom: dual-Kawase upsample (8-tap tent from the level below), blended with
// this level's own downsample so the halo keeps a tight core inside a wide tail.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;        // one texel of `low`
    float keep;        // weight of this level's own downsample
};
layout(binding = 1) uniform sampler2D low;
layout(binding = 2) uniform sampler2D here;

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 o = texel;
    vec3 s = texture(low, uv + vec2(-o.x, 0.0)).rgb + texture(low, uv + vec2(o.x, 0.0)).rgb
           + texture(low, uv + vec2(0.0, -o.y)).rgb + texture(low, uv + vec2(0.0, o.y)).rgb;
    s += (texture(low, uv + o * 0.5).rgb + texture(low, uv - o * 0.5).rgb
        + texture(low, uv + vec2(o.x, -o.y) * 0.5).rgb + texture(low, uv + vec2(-o.x, o.y) * 0.5).rgb) * 2.0;
    s /= 12.0;
    fragColor = vec4(mix(s, texture(here, uv).rgb, keep), 1.0);
}
