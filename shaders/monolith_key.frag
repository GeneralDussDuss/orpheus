#version 440
// Orpheus Monolith deck: one soft-touch rubber key, standing in its hole in
// the block. Matte, velvety: a broad diffuse light from the top left, a
// rolled shoulder, a faint sheen at grazing angles (soft-touch coating
// scatters it back), a fine texture, and its shadow on the hole's floor. A
// press sinks it and pulls the shadow in. The play key carries an inner LED
// ring, a light pipe set into its face, that glows through the rubber.
//
// The item is padded round the cap so the shadow and the ring's glow fit.
// Pixel space, y down, premultiplied.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float bloomAmt;
    float rad;       // the cap's corner radius
    float press;     // 0 up .. 1 fully down
    float hover;     // 0..1
    float ring;      // the LED ring: 0 no ring; else 1 + brightness (1 = unlit)
    vec4 cap;        // the cap's rect at rest, item px
    vec4 rubber;     // the rubber's colour
    vec4 glowC;      // the ring's light
};

const vec3 LDIR = vec3(-0.50, -0.68, 0.53);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float sdRBox(vec2 p, vec4 r, float rad) {
    vec2 h = r.zw * 0.5;
    vec2 q = abs(p - r.xy - h) - h + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float s = sc;
    float travel = 2.4 * s * press;
    vec4 r = cap + vec4(0.0, travel, 0.0, 0.0);
    float d = sdRBox(p, r, rad);

    vec4 o = vec4(0.0);
    // ---- the shadow on the hole's floor (and the ring's spill) --------------
    float lift = mix(1.0, 0.25, press);
    float dS = sdRBox(p - vec2(1.2, 2.2) * s * lift, cap + vec4(0.0, travel, 0.0, 0.0), rad);
    float shA = 0.55 * exp(-max(dS, 0.0) / (2.8 * s * lift + 0.6));
    o = vec4(0.0, 0.0, 0.0, shA * mix(1.0, 0.6, light));

    float ringLit = max(0.0, ring - 1.0);
    if (ring > 0.0 && ringLit > 0.0 && bloomAmt > 0.0) {
        // light from the ring escaping round the cap's foot
        float g = exp(-max(d, 0.0) / (5.0 * s)) * step(0.0, d);
        vec3 gl = glowC.rgb * g * 0.35 * ringLit * bloomAmt;
        o.rgb = o.rgb * (1.0 - 0.0) + gl;
        o.a = max(o.a, min(1.0, max(gl.r, max(gl.g, gl.b))));
    }

    if (d < 0.5) {
        // ---- the cap ---------------------------------------------------------
        float sh = min(rad, min(r.z, r.w) * 0.30);      // the rolled shoulder's width
        float t = clamp(-d / sh, 0.0, 1.0);             // 0 at the edge, 1 on the flat
        vec2 e = vec2(0.5, 0.0);
        vec2 g = normalize(vec2(sdRBox(p + e.xy, r, rad) - sdRBox(p - e.xy, r, rad),
                                sdRBox(p + e.yx, r, rad) - sdRBox(p - e.yx, r, rad)) + 1e-6);
        // a quarter-round shoulder into a very slightly dished top
        float slope = (1.0 - t) / max(0.08, sqrt(max(0.0, 1.0 - (1.0 - t) * (1.0 - t))));
        slope = min(slope, 3.0);
        vec2 cc = r.xy + r.zw * 0.5;
        vec2 dish = (p - cc) / max(r.z, r.w) * 0.10;
        vec3 n = normalize(vec3(g * slope - dish, 1.0));

        vec3 L = normalize(LDIR);
        vec3 V = vec3(0.0, 0.0, 1.0);
        float ndl = dot(n, L);
        float wrap = clamp((ndl + 0.45) / 1.45, 0.0, 1.0);
        vec3 alb = rubber.rgb;
        alb *= 1.0 + (vnoise(p * 0.8) - 0.5) * 0.035 + (hash(floor(p)) - 0.5) * 0.025;
        alb *= 1.0 + 0.05 * hover;
        // soft-touch: diffuse, a velvet lift at grazing angles, a very broad sheen
        float nv = clamp(n.z, 0.0, 1.0);
        float velvet = pow(1.0 - nv, 2.0) * clamp(ndl + 0.4, 0.0, 1.0);
        vec3 H = normalize(L + V);
        float sheen = pow(max(dot(n, H), 0.0), 7.0);
        vec3 col = alb * (0.34 + 0.78 * wrap) + vec3(0.9) * velvet * 0.16 + mix(vec3(1.0), alb, 0.5) * sheen * 0.045;
        // the face falls off away from the light
        vec2 kuv = (p - r.xy) / r.zw;
        col *= 1.04 - 0.12 * kuv.y;
        // pressed: deeper in the hole, a touch less light
        col *= 1.0 - 0.10 * press;
        // the cap's foot meets the shadow in its own hole
        col *= mix(0.55, 1.0, ss(0.0, 1.6 * s, -d));

        // ---- the LED ring: a light pipe inset in the face ----------------------
        if (ring > 0.0) {
            float inset = min(r.z, r.w) * 0.17;
            float dr = abs(d + inset) - 0.9 * s;          // the pipe's width
            float pipe = ss(0.6, -0.6, dr);
            // unlit: a dark frosted groove; lit: bright, glowing into the rubber
            vec3 groove = alb * 0.55;
            col = mix(col, groove, pipe * 0.8);
            if (ringLit > 0.0) {
                vec3 lc = mix(glowC.rgb, vec3(1.0), 0.45);
                col += lc * pipe * ringLit * 1.1;
                // subsurface: the rubber either side of the pipe carries the light
                float sub = exp(-max(dr, 0.0) / (2.6 * s));
                col += glowC.rgb * sub * (1.0 - pipe) * ringLit * (0.22 + 0.3 * bloomAmt);
                float bl = exp(-max(dr, 0.0) / (8.0 * s));
                col += glowC.rgb * bl * ringLit * 0.12 * bloomAmt;
            }
        }
        col += (hash(p + 3.7) - 0.5) / 255.0;
        float a = clamp(0.5 - d, 0.0, 1.0);
        o = vec4(col * a, a) + o * (1.0 - a);
    }
    fragColor = o * qt_Opacity;
}
