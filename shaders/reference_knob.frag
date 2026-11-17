#version 440
// Orpheus "Reference" deck: the big position knob. A knurled skirt (straight
// knurl, each ridge two lit facets) round a spun-metal cap: lathe rings, the
// circular polish's bow-tie highlight pointing at the light, a bright chamfer
// between them. An accent light pipe set into the cap is the indicator; it
// glows onto the cap. The ridges and the indicator turn with `angle`; the
// light, and so the cap's highlights, stay put -- that is what sells it as a
// turned object. A soft contact shadow lands on the spot face below.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float angle;     // rad, 0 up, clockwise
    float rk;        // knob radius px
    float glowAmt;   // indicator glow 0..1
    float hover;     // 0..1
    float grab;      // 0..1 while dragged
    float bloomAmt;
    vec4 skirt;      // anodised skirt colour
    vec4 cap;        // spun cap tint
    vec4 phos;       // indicator
};

const float PI = 3.14159265;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
vec3 Ln() { return normalize(vec3(-0.38, -0.78, 0.5)); }
vec2 shadeN(vec3 n, float shin) {
    vec3 l = Ln();
    float d = max(dot(n, l), 0.0);
    vec3 h = normalize(l + vec3(0, 0, 1));
    return vec2(d, pow(max(dot(n, h), 0.0), shin));
}
vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

void main() {
    vec2 c = res * 0.5;
    vec2 p = qt_TexCoord0 * res;
    vec2 v = p - c;
    float r = length(v);
    float th = atan(v.x, -v.y);
    vec2 rad = v / max(r, 1e-3);
    vec2 tan2 = vec2(-rad.y, rad.x);
    vec4 o = vec4(0.0);

    // contact shadow, cast down and to the right of the light
    {
        vec2 sv = v - vec2(1.8, 4.5) * sc;
        float d = length(sv) - rk;
        float a = 0.55 * exp(-max(d, 0.0) / (5.0 * sc)) * smoothstep(-rk, 0.0, -max(d, -rk * 0.2));
        a *= clamp(1.0 - (-min(d, 0.0)) / rk, 0.0, 1.0) + step(d, 0.0);
        o = vec4(0.0, 0.0, 0.0, clamp(a, 0.0, 0.6) * mix(1.0, 0.7, light));
    }
    float rc = rk * 0.70;               // cap radius
    float rch = rc + 1.6 * sc;          // chamfer outer edge
    float aK = clamp(rk - r + 0.5, 0.0, 1.0);
    if (aK > 0.0) {
        vec3 col;
        if (r > rch) {
            // ---- the knurled skirt -------------------------------------------------
            float N = floor(rk * 1.35 / max(sc, 0.5) * 1.25) * 1.0;   // ridges, ~3.5 px apart at 1x
            float u = (th - angle) / (2.0 * PI) * N;
            float f = fract(u) - 0.5;
            // a triangular ridge: the two flanks lean ±tangentially; the top
            // of the skirt also rolls off outward toward its rim
            float flank = f < 0.0 ? -1.0 : 1.0;
            float ridge = 1.0 - abs(f) * 2.0;
            float tq = (r - rch) / max(rk - rch, 1.0);   // 0 inner .. 1 rim
            vec2 n2 = tan2 * flank * 0.75 + rad * (0.15 + 0.85 * smoothstep(0.65, 1.0, tq));
            vec3 n = normalize(vec3(n2, 0.9));
            vec2 s = shadeN(n, 14.0);
            // anti-alias the ridges where they crowd (the width of one ridge in px)
            float ridgePx = 2.0 * PI * r / N;
            float aa = smoothstep(1.6, 3.2, ridgePx);
            vec2 sAvg = shadeN(normalize(vec3(rad * (0.15 + 0.85 * smoothstep(0.65, 1.0, tq)), 0.9)), 14.0);
            s = mix(sAvg, s, aa);
            vec3 base = skirt.rgb;
            // facets that face up mirror the bright room above
            float sky = smoothstep(0.1, -0.7, n.y) * mix(0.12, 0.2, light);
            col = base * (0.30 + 0.95 * s.x) + vec3(s.y * mix(0.75, 0.8, light) + sky * aa);
            col *= 0.88 + 0.12 * smoothstep(0.0, 0.5, ridge);     // the valleys
            // the rim chamfer, polished
            float rim = smoothstep(rk - 1.6 * sc, rk - 0.4 * sc, r);
            vec2 sr = shadeN(normalize(vec3(rad * 0.8, 0.6)), 20.0);
            col = mix(col, base * (0.4 + 0.9 * sr.x) + vec3(sr.y * 0.9), rim);
        } else if (r > rc) {
            // ---- the bright chamfer between skirt and cap --------------------------
            vec2 s = shadeN(normalize(vec3(rad * 0.75, 0.66)), 24.0);
            col = cap.rgb * (0.30 + 0.85 * s.x) + vec3(s.y * 1.0);
        } else {
            // ---- the spun cap ----------------------------------------------------
            float rn = r / rc;
            float rings = vnoise(vec2(r * 2.1 / max(sc, 0.5), 3.0)) * 0.55 + vnoise(vec2(r * 0.6 / max(sc, 0.5), 7.0)) * 0.45;
            float la = atan(Ln().x, -Ln().y);
            float bow = pow(abs(cos(th - la)), 10.0);
            float bowTight = pow(abs(cos(th - la)), 60.0);
            // a whisper of dish: brighter toward the far side from the light
            float dish = 0.94 + 0.08 * dot(rad, -Ln().xy) * rn;
            vec3 base = cap.rgb * dish * (0.80 + 0.20 * rings);
            col = base + vec3(0.30 * bow + 0.35 * bowTight) * (0.45 + 0.75 * rings) * mix(0.9, 1.0, light);
            // concentric reflections: a couple of broad bright rings
            col += vec3(0.05) * smoothstep(0.08, 0.0, abs(rn - 0.62)) + vec3(0.04) * smoothstep(0.06, 0.0, abs(rn - 0.30));
            // the centre dimple
            col *= 1.0 - 0.18 * smoothstep(0.10, 0.0, rn);
            // the indicator: a light pipe set in the cap near its edge
            vec2 dir = vec2(sin(angle), -cos(angle));
            vec2 tg = vec2(cos(angle), sin(angle));
            float along = dot(v, dir), across = dot(v, tg);
            float r0 = rc * 0.50, r1 = rc * 0.86, hw = 1.35 * sc;
            float dl = max(abs(across) - hw, max(r0 - along, along - r1));
            float cut = clamp(0.5 - (dl - 0.8 * sc), 0.0, 1.0);
            col = mix(col, col * 0.25, cut);               // the slot it sits in
            float pipe = clamp(0.5 - dl, 0.0, 1.0);
            float g = glowAmt;
            vec3 pc = phos.rgb * (0.65 + 0.35 * g) + vec3(0.25 * g) * (1.0 - 0.6 * light);
            col = mix(col, pc, pipe);
            float dg = max(dl, 0.0);
            col += phos.rgb * exp(-dg * dg / (9.0 * sc * sc)) * (0.25 + 0.45 * bloomAmt) * g * (1.0 - pipe);
        }
        // hover and grab: a touch more light on the metal
        col *= 1.0 + 0.06 * hover + 0.04 * grab;
        o = over(o, col, aK);
    }
    // the indicator's light spills over the rim a little (bloom only)
    fragColor = o * qt_Opacity;
}
