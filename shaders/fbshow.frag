#version 440
// Orpheus feedback, display: this frame at full resolution, with the trails
// from the (smaller) feedback buffer showing through wherever they are
// brighter than it. The buffer already holds this frame too, softened by its
// lower resolution, so only what exceeds the crisp frame counts as trail.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float gain;      // how much of the trails shows (the feedback level, and less on light themes)
    float light;     // light theme: trails are laid over as ink; dark: screened on as light
};
layout(binding = 1) uniform sampler2D fresh;
layout(binding = 2) uniform sampler2D trail;

void main() {
    vec4 F = texture(fresh, qt_TexCoord0);
    vec4 C = texture(trail, qt_TexCoord0) * gain;
    vec4 o;
    if (light < 0.5) {
        // Light: only what the trails add beyond this frame, screened on.
        vec3 T = max(C.rgb - F.rgb, 0.0);
        float ta = max(T.r, max(T.g, T.b));
        o = vec4(F.rgb + T * (1.0 - min(F.rgb, 1.0)), F.a + ta * (1.0 - F.a));
    } else {
        // Ink: the trail's coverage beyond this frame's, laid under it.
        float k = clamp((C.a - F.a) / max(C.a, 1e-3), 0.0, 1.0);
        o = F + C * k * (1.0 - F.a);
    }
    fragColor = clamp(o, 0.0, 1.0) * qt_Opacity;
}
