#version 440
// Bloom, last pass: the blurred light added back over the visualizer, screen
// blended (so stacked light rolls off instead of clipping to white). The
// visualizer stays premultiplied; the glow raises alpha a little so it still
// reads over a transparent window.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;        // one texel of `glowTex`
    float strength;
    float taps;        // 4 = smoothed upsample, 1 = a single bilinear tap
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D glowTex;

void main() {
    vec2 uv = qt_TexCoord0;
    vec4 c = texture(source, uv);
    c = clamp(c, 0.0, 1.0);
    vec3 b;
    if (taps > 2.0) {
        vec2 o = texel * 0.5;
        b = (texture(glowTex, uv + o).rgb + texture(glowTex, uv - o).rgb
           + texture(glowTex, uv + vec2(o.x, -o.y)).rgb + texture(glowTex, uv + vec2(-o.x, o.y)).rgb) * 0.25;
    } else {
        b = texture(glowTex, uv).rgb;
    }
    vec3 add = 1.0 - exp(-b * strength);
    vec3 rgb = c.rgb + add * (1.0 - c.rgb);                  // screen
    float a = clamp(c.a + max(add.r, max(add.g, add.b)) * 0.6 * (1.0 - c.a), 0.0, 1.0);
    fragColor = vec4(rgb, a) * qt_Opacity;
}
