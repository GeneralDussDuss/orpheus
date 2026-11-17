#version 440
// One layer of a hardware deck's side wall (DeckStage): the device's own
// pixels, darkened, so the extruded edge takes the colour of the body.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float shade;
};
layout(binding = 1) uniform sampler2D src;
void main() {
    vec4 c = texture(src, qt_TexCoord0);
    fragColor = vec4(c.rgb * shade, c.a) * qt_Opacity;
}
