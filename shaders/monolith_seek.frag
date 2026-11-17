#version 440
// Orpheus Monolith deck: the seek slot's contents. A light pipe along the
// slot's floor, lit in the accent up to the play head (the slot walls keep
// the glow in, the lips catch a little), and the puck: a small machined
// aluminium slider riding in the slot, chamfered, with an engraved index line
// that lights while it is held or hovered, and its shadow on the face.
//
// Updates once a second while playing (or as the puck is dragged).
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float bloomAmt;
    float frac;
    float hot;       // hover / drag 0..1
    float on;        // 1 when there is a track to seek
    vec4 slot;       // the slot's floor, item px
    vec4 metal;
    vec4 accent;
};

const vec3 LDIR = vec3(-0.50, -0.68, 0.53);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float sdRBox(vec2 p, vec4 r, float rad) {
    vec2 h = r.zw * 0.5;
    vec2 q = abs(p - r.xy - h) - h + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}
vec3 shade(vec3 alb, vec3 n, float gloss, float specAmt) {
    vec3 L = normalize(LDIR);
    float wrap = clamp((dot(n, L) + 0.35) / 1.35, 0.0, 1.0);
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float sp = pow(max(dot(n, H), 0.0), gloss);
    return alb * (0.30 + 0.86 * wrap) + mix(vec3(1.0), alb, 0.3) * sp * specAmt;
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float s = sc;
    vec3 M = metal.rgb;
    vec3 A = accent.rgb;
    vec4 o = vec4(0.0);

    // ---- the light pipe ------------------------------------------------------
    float cy = slot.y + slot.w * 0.5;
    float x0 = slot.x + slot.w * 0.5;
    float x1 = slot.x + slot.z - slot.w * 0.5;
    float hx = mix(x0, x1, clamp(frac, 0.0, 1.0));
    float dSlot = sdRBox(p, slot, slot.w * 0.5);
    float inSlot = ss(0.6, -0.6, dSlot);
    if (on > 0.0) {
        float lineH = max(1.0, 1.1 * s);
        float dl = max(abs(p.y - cy) - lineH, 0.0);
        float along = p.x <= hx ? 1.0 : 0.0;
        // the lit run: hot at its core, a soft glow filling the slot
        float core = ss(1.0, 0.0, dl) * along;
        float glow = exp(-dl * dl / (9.0 * s * s)) * along;
        // the pipe ahead of the head: unlit, a frosted line
        float ahead = ss(1.0, 0.0, dl) * (1.0 - along) * step(x0 - 2.0, p.x);
        vec3 c = mix(A, vec3(1.0), 0.35) * core + A * glow * (0.35 + 0.4 * bloomAmt) + M * 0.35 * ahead;
        // the glow brightens toward the head
        c *= 0.65 + 0.35 * ss(x0, hx + 1.0, p.x);
        o = vec4(c * inSlot, inSlot * max(core, max(glow * 0.9, ahead * 0.6)));
        // a little light escapes onto the lips above and below
        float spill = exp(-max(dSlot, 0.0) / (3.0 * s)) * step(0.0, dSlot) * bloomAmt
                      * ss(x0 - 6.0 * s, hx, p.x) * step(p.x, hx + 4.0 * s);
        o.rgb += A * spill * 0.18;
        o.a = max(o.a, spill * 0.18);
    }

    // ---- the puck -------------------------------------------------------------
    float pw = 30.0 * s, ph = 16.0 * s;
    vec4 pr = vec4(hx - pw * 0.5, cy - ph * 0.5 - 1.0 * s * hot, pw, ph);
    float prad = 4.5 * s;
    // its shadow on the face
    float dS = sdRBox(p - vec2(1.3, 2.6) * s * (1.0 + 0.5 * hot), pr, prad);
    float sa = 0.5 * exp(-max(dS, 0.0) / (2.6 * s)) * mix(1.0, 0.65, light);
    o = vec4(o.rgb * (1.0 - sa), o.a + sa * (1.0 - o.a));
    float d = sdRBox(p, pr, prad);
    if (d < 0.5) {
        vec2 e = vec2(0.5, 0.0);
        vec2 g = normalize(vec2(sdRBox(p + e.xy, pr, prad) - sdRBox(p - e.xy, pr, prad),
                                sdRBox(p + e.yx, pr, prad) - sdRBox(p - e.yx, pr, prad)) + 1e-6);
        float cw = 2.2 * s;
        float t = clamp(-d / cw, 0.0, 1.0);
        float slope = t < 1.0 ? mix(1.5, 0.8, t) : 0.0;
        vec3 n = normalize(vec3(g * slope, 1.0));
        // the puck is bare machined aluminium: brighter and greyer than the body
        vec3 alb = mix(M, vec3(dot(M, vec3(0.333))) + mix(0.42, 0.22, light), mix(0.6, 0.45, light));
        // a fine lathe finish on its top: concentric rings about its centre
        vec2 lp = p - (pr.xy + pr.zw * 0.5);
        float lathe = sin(length(lp * vec2(1.0, 1.6)) * 3.1) * 0.025;
        alb *= 1.0 + lathe + (hash(floor(p)) - 0.5) * 0.03;
        vec3 col = shade(alb, n, t < 1.0 ? 26.0 : 9.0, t < 1.0 ? 0.8 : 0.22);
        // a broad sheen on the top face, from the key light
        vec2 puv = (p - pr.xy) / pr.zw;
        col += vec3(1.0) * 0.07 * exp(-pow(puv.x * 0.8 + puv.y - 0.55, 2.0) / 0.05) * step(1.0, t);
        col *= 1.04 - 0.14 * puv.y;
        // the index line, engraved across the middle: lights in the accent
        float il = ss(0.8 * s, 0.0, abs(lp.x)) * step(abs(lp.y), ph * 0.5 - 3.6 * s);
        vec3 ink = mix(M * 0.35, mix(A, vec3(1.0), 0.3), max(hot, 0.35 * on));
        col = mix(col, ink, il);
        col += A * ss(3.0 * s, 0.0, abs(lp.x)) * step(abs(lp.y), ph * 0.5 - 3.0 * s) * hot * 0.25 * bloomAmt;
        col += (hash(p + 1.3) - 0.5) / 255.0;
        float a = clamp(0.5 - d, 0.0, 1.0);
        o = vec4(col * a, a) + o * (1.0 - a);
    }
    fragColor = o * qt_Opacity;
}
