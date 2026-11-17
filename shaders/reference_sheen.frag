#version 440
// Orpheus "Reference" deck: the moving specular band on the brushed faceplate.
// Horizontal brushing spreads a reflection across the strands, so the highlight
// is a tall soft band that streaks along each strand -- the same strands
// reference_face.frag paints, so the band lights them. Pure added light
// (premultiplied, alpha 0) over the cached face; the pockets and the plate are
// masked out. Only this cheap pass moves: it drifts while the music plays and
// leans toward the pointer, like turning the unit in the light.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float bandX;     // band centre, px
    float bandW;     // band half-width, px
    float amt;       // strength 0..1
    float lift;      // a breath of extra light (the downbeat), 0..1
    vec4 tint;       // the light's colour (white leaning to the theme)
    vec4 vfdR; vec4 artR; vec4 knobR; vec4 keysR; vec4 plateR;
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float brush(vec2 p) {
    float a = vnoise(vec2(p.x * 0.0035, p.y * 1.25));
    float b = vnoise(vec2(p.x * 0.012 + 17.0, p.y * 2.3));
    float c = vnoise(vec2(p.x * 0.06 + 41.0, p.y * 3.1));
    return a * 0.5 + b * 0.32 + c * 0.18;
}
float inRect(vec2 p, vec4 R, float pad) {
    vec2 d = max(R.xy - pad - p, p - (R.xy + R.zw + pad));
    return step(max(d.x, d.y), 0.0);
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    // the band leans: a reflection in a slightly tilted plate is not upright
    float x = p.x - bandX + (p.y - res.y * 0.5) * 0.18;
    float g = exp(-(x * x) / (bandW * bandW));
    float core = exp(-(x * x) / (bandW * bandW * 0.08));
    float w = (0.55 * g + 0.45 * core) * (0.65 + 0.35 * (1.0 - p.y / res.y));
    if (w < 0.004) { fragColor = vec4(0.0); return; }
    float m = 1.0 - max(max(inRect(p, vfdR, 0.0), inRect(p, artR, 0.0)), max(inRect(p, keysR, 0.0), inRect(p, plateR, 0.0)));
    float kr = length(p - knobR.xy);
    m *= step(knobR.z + 6.0 * sc, kr);
    m *= step(1.5 * sc, min(min(p.x, res.x - p.x), min(p.y, res.y - p.y)));
    if (m <= 0.0) { fragColor = vec4(0.0); return; }
    float b = brush(p);
    float strand = pow(clamp(b * 1.25 - 0.1, 0.0, 1.0), 2.2);
    float I = w * (0.25 + 1.6 * strand) * amt * (1.0 + 0.35 * lift);
    I *= mix(0.30, 0.26, light);
    fragColor = vec4(tint.rgb * I * m, 0.0) * qt_Opacity;
}
