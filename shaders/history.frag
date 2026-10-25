#version 440
// Orpheus spectrum history, kept on the GPU. A 32x24 target that samples its
// own previous frame: every row moves one step back, and row 0 takes the
// current spectrum. Prism reads this as its city.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 b0; vec4 b1; vec4 b2; vec4 b3; vec4 b4; vec4 b5; vec4 b6; vec4 b7;
    float rows;
};

layout(binding = 1) uniform sampler2D prev;

float bandAt(int i) {
    vec4 v[8] = vec4[8](b0, b1, b2, b3, b4, b5, b6, b7);
    i = clamp(i, 0, 31);
    return v[i / 4][i % 4];
}

void main() {
    vec2 uv = qt_TexCoord0;
    float row = floor(uv.y * rows);
    float v;
    if (row < 0.5) {
        v = bandAt(int(floor(uv.x * 32.0)));
    } else {
        // Sample the centre of the row in front of us from the previous frame.
        v = texture(prev, vec2(uv.x, (row - 0.5) / rows)).r;
    }
    fragColor = vec4(v, v, v, 1.0);
}
