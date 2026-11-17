#version 440
// Orpheus "Reference" deck: one chrome piano key and its status LED. The key
// is a polished block standing out of the key slot: a flat top that mirrors
// the studio (bright sky, the dark horizon band that makes chrome read as
// chrome, the floor), a rolled front lip, side bevels, and a shadow on the
// slot floor that shortens as it goes down. The LED above sits in the plate
// (it does not travel): a domed lens, dark and faintly tinted when off, a hot
// core and a halo when lit.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float press;     // 0..1 travel
    float hover;     // 0..1
    float led;       // 0..1 lit
    float bloomAmt;
    float keyTop;    // px, key top at rest
    float keyH;      // px
    float travel;    // px at full press
    float ledR;      // px
    vec4 ledC;       // LED centre (x, y), -, -
    vec4 ledCol;     // its colour
    vec4 tint;       // chrome tint
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float sdRBox(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

// The studio as chrome sees it: t = the reflected ray's height, -1 floor .. 1 sky.
float env(float t) {
    float sky = mix(0.62, 1.0, smoothstep(0.15, 0.95, t));
    float ground = mix(0.16, 0.46, smoothstep(-1.0, -0.05, t));
    float v = mix(ground, sky, smoothstep(-0.04, 0.06, t));
    v -= 0.38 * exp(-pow((t - 0.16) / 0.05, 2.0));      // the dark band above the horizon
    v += 0.25 * exp(-pow((t - 0.62) / 0.05, 2.0));      // a softbox catch-light
    return v;
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    vec4 o = vec4(0.0);
    float lt = light;
    vec3 tn = tint.rgb / max(max(tint.r, max(tint.g, tint.b)), 0.05);
    vec3 chromeTint = mix(vec3(1.0), tn, 0.22);

    // ---- the key --------------------------------------------------------------------
    float ky = keyTop + press * travel;
    float kx0 = 0.5, kx1 = res.x - 0.5;
    vec2 kc = vec2((kx0 + kx1) * 0.5, ky + keyH * 0.5);
    vec2 kb = vec2((kx1 - kx0) * 0.5, keyH * 0.5);
    float rr = 2.2 * sc;
    // its shadow on the slot floor
    {
        float sh = 4.0 * sc * (1.0 - 0.7 * press);
        float d = sdRBox(p - kc - vec2(0.0, sh), kb, rr);
        float a = 0.65 * exp(-max(d, 0.0) / (2.5 * sc)) * step(ky, p.y);
        o = vec4(0.0, 0.0, 0.0, clamp(a, 0.0, 0.65));
    }
    float d = sdRBox(p - kc, kb, rr);
    float a = clamp(0.5 - d, 0.0, 1.0);
    if (a > 0.0) {
        float v = (p.y - ky) / keyH;                    // 0 top .. 1 bottom
        float u = (p.x - kx0) / (kx1 - kx0);
        float lipH = 0.20;                               // the rolled front lip
        float bev = 1.6 * sc;
        float dx = min(p.x - kx0, kx1 - p.x);
        float t;                                          // reflected height
        if (v < 0.07) t = mix(0.98, 0.80, v / 0.07);                 // the top arris, facing up
        else if (v < 1.0 - lipH) t = mix(0.78, -0.02, (v - 0.07) / (0.93 - lipH)) - 0.12 * press;
        else t = mix(-0.08, -0.9, (v - (1.0 - lipH)) / lipH);      // rolling down and toward us
        float e = env(t);
        // the side bevels lean out: they see the darker sides of the room
        float side = 1.0 - smoothstep(0.0, bev, dx);
        e = mix(e, e * 0.55 + 0.05, side);
        // a slow left-to-right falloff of the softbox
        e *= mix(1.06, 0.92, u);
        e = mix(e, e * 0.88 + 0.06, lt * 0.0);
        vec3 col = vec3(e) * chromeTint;
        // fine polish streaks, vertical (the keys are polished front to back)
        col *= 0.97 + 0.03 * hash(vec2(floor(p.x), 7.0));
        col *= mix(0.86, 1.0, lt);
        col *= 1.0 + 0.10 * hover - 0.08 * press;
        // the top arris: one line of white
        col += vec3(0.35) * exp(-pow((p.y - ky - 0.8 * sc) / (0.55 * sc), 2.0)) * (1.0 - side);
        o = over(o, col, a);
    }

    // ---- the LED -----------------------------------------------------------------------
    {
        vec2 lv = p - ledC.xy;
        float r = length(lv);
        float on = led;
        vec3 lc = ledCol.rgb;
        // halo on the plate (light, so alpha 0)
        float halo = exp(-r * r / (pow(ledR * 2.8, 2.0))) * on * (0.25 + 0.75 * bloomAmt);
        float aL = clamp(ledR - r + 0.5, 0.0, 1.0);
        if (aL > 0.0) {
            float rn = r / ledR;
            vec3 off = lc * 0.16 + vec3(0.02);
            vec3 lens = mix(off, mix(lc, vec3(1.0), 0.55 * (1.0 - rn * rn)) * (0.9 + 0.1 * on), on);
            // a dome: a tiny window reflection top-left
            float spec = exp(-dot(lv / ledR - vec2(-0.32, -0.38), lv / ledR - vec2(-0.32, -0.38)) / 0.05);
            lens += vec3(0.55) * spec * (1.0 - 0.6 * on);
            lens *= 1.0 - 0.35 * rn * rn * (1.0 - on);
            o = over(o, lens, aL);
        }
        o.rgb += lc * halo * (1.0 - aL) * 0.8;
    }
    fragColor = o * qt_Opacity;
}
