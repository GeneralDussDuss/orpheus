#version 440
// Orpheus Monolith deck: the knurled wheel in its slot on the right edge. A
// roller seen from above: its rim curves away top and bottom (the knurl's
// ridges crowd together there, foreshortened), it turns as it is rolled
// (`turn`), and it stands proud of the block's edge. The ridges are straight
// knurl on bare machined aluminium, lit from the top left.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float turn;      // radians
    float hot;       // hover 0..1
    vec4 metal;
};

const vec3 LDIR = vec3(-0.50, -0.68, 0.53);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

void main() {
    vec2 p = qt_TexCoord0 * res;
    float s = sc;
    vec3 M = metal.rgb;
    // the roller: across x its two faces are chamfered; along y the rim curves
    float R = res.y * 0.5;
    float y = (p.y - R) / R;                 // -1 top .. 1 bottom
    float yc = clamp(y, -0.999, 0.999);
    float z = sqrt(1.0 - yc * yc);            // the rim's height toward us
    float theta = asin(yc);                   // the angle round the axis
    // the knurl: N ridges round the circumference
    const float N = 64.0;
    float ph = (theta + turn) * N / 6.2831853;
    float f = fract(ph);
    // each ridge a small V: its two flanks face up and down the roller
    float flank = f < 0.5 ? -1.0 : 1.0;
    float ridgeH = abs(f - 0.5) * 2.0;        // 1 at the crest, 0 in the root
    // where the ridges crowd past a pixel they blur into the rim's own shade
    float crisp = clamp(1.6 - fwidth(ph) * 2.2, 0.0, 1.0);
    flank *= crisp;
    // the surface normal: the rim's curve, tilted by the flank
    vec3 n = normalize(vec3(0.0, yc, z));
    vec3 nf = normalize(n + vec3(0.0, z, -yc) * flank * 0.55);
    // the side chamfers across x
    float ex = min(p.x, res.x - p.x);
    float side = ss(0.0, 1.8 * s, ex);
    nf = normalize(nf + vec3((p.x < res.x * 0.5 ? -1.0 : 1.0) * (1.0 - side) * 1.2, 0.0, 0.0));

    vec3 L = normalize(LDIR);
    float wrap = clamp((dot(nf, L) + 0.3) / 1.3, 0.0, 1.0);
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float sp = pow(max(dot(nf, H), 0.0), 18.0);
    vec3 alb = mix(M, vec3(dot(M, vec3(0.333))) + 0.30, 0.6) * (0.95 + 0.1 * hash(floor(p)));
    vec3 col = alb * (0.22 + 0.9 * wrap) + vec3(1.0) * sp * 0.55;
    // the roots of the knurl hold shadow
    col *= mix(mix(0.82, 0.55, crisp), 1.0, ss(0.0, 0.35, ridgeH));
    // the rim falls away into the slot top and bottom
    col *= ss(0.05, 0.6, z) * (0.85 + 0.15 * z);
    col *= 1.0 + 0.06 * hot;
    // a soft vertical highlight band where the rim faces up at the light
    col += vec3(1.0) * 0.05 * exp(-pow(y + 0.35, 2.0) / 0.05) * side;

    float a = ss(1.0, 0.92, abs(y));
    col += (hash(p) - 0.5) / 255.0;
    fragColor = vec4(col * a, a) * qt_Opacity;
}
