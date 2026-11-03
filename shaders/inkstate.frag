#version 440
// Orpheus "Ink", the water: a dye buffer that renders from its own previous
// frame (a recursive source in Viz.qml, at reduced resolution, half float).
// rgb = pigment (colour x amount), a = amount, so mixing dyes mixes colours.
//
// Every frame the dye is carried along a divergence-free curl-noise flow
// (the curl of a drifting noise potential: it swirls but never piles up, so
// no pressure solve is needed) with a Catmull-Rom back-trace, which keeps
// filaments sharp far longer than a bilinear one. On top of that flow:
//   kicks  - a drop of dye from one of three wandering emitters, pushed out
//            in a ring and fired along the emitter's heading
//   bass   - the whole flow runs faster
//   snap   - a counter-rotating vortex pair tears the dye near an emitter
//   build  - a finer, faster octave of turbulence rises in
//   drop   - a burst of all three colours from the middle
// Quiet music: the emitters only weep a little and the flow slows, so what
// is there settles into marbling and fades over half a minute.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
    float asp;       // width / height of the view
    float dt;        // seconds per frame (1 / fps)
    vec2 texel;      // 1 / state size
    vec4 c1;
    vec4 c2;
    vec4 c3;
    float bass;
    float energy;
    float swell;
    float snap;
    float build;
    float drop;
    float kicks;
    vec4 kickAge;    // x = seconds since the newest kick, w = its strength
    float fresh;     // 1 = clear the water (the buffer just went live)
    float intro;     // 1 -> 0 over the first second: a welcome burst
};
layout(binding = 1) uniform sampler2D prev;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// Value noise with its analytic gradient (xy) and value (z).
vec3 noised(vec2 x) {
    vec2 i = floor(x), f = fract(x);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float a = hash(i), b = hash(i + vec2(1.0, 0.0)), c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));
    float k1 = b - a, k2 = c - a, k4 = a - b - c + d;
    return vec3(du * vec2(k1 + k4 * u.y, k2 + k4 * u.x), a + k1 * u.x + k2 * u.y + k4 * u.x * u.y);
}
// Curl of one octave of potential at frequency f, normalised to ~unit speed.
vec2 curlAt(vec2 p, float f, vec2 drift) {
    vec2 g = noised(p * f + drift).xy;
    return vec2(g.y, -g.x) * 0.55;
}

vec3 pal(float x) {
    x = fract(x) * 3.0;
    if (x < 1.0) return mix(c1.rgb, c2.rgb, x);
    if (x < 2.0) return mix(c2.rgb, c3.rgb, x - 1.0);
    return mix(c3.rgb, c1.rgb, x - 2.0);
}

// Emitter j (0..2) at time t: wanders slowly over the whole view (aspect units, y down).
vec2 emitterAt(float j, float t) {
    t = t * (0.11 + j * 0.017) + j * 2.1;
    return vec2(asp * (0.5 + 0.40 * sin(t * 1.3 + j) * cos(t * 0.37)),
                0.5 + 0.32 * sin(t * 0.9 + 1.7 * j));
}
vec2 emitter(float j) { return emitterAt(j, time); }
// Which way it is wandering.
vec2 heading(float j) {
    vec2 d = emitterAt(j, time + 0.5) - emitterAt(j, time);
    return d / max(length(d), 1e-4);
}

// The kick being injected right now: emitter index and colour.
float kickEmitter() { return floor(hash(vec2(kicks, 3.7)) * 3.0); }
// Where it lands: its emitter, nudged a little differently every kick.
vec2 kickPos(float j) {
    return emitter(j) + (vec2(hash(vec2(kicks, 1.3)), hash(vec2(kicks, 5.9))) - 0.5) * 0.12;
}

// The flow at p (aspect units per second).
vec2 velocity(vec2 p) {
    float loud = clamp(max(swell, energy), 0.0, 1.0);
    float speed = 0.05 + 0.16 * bass + 0.06 * loud + 0.10 * build + 0.22 * drop;
    vec2 v = curlAt(p, 1.4, vec2(time * 0.045, -time * 0.03)) * 1.0
           + curlAt(p, 3.1, vec2(-time * 0.08, time * 0.1) + 7.3) * 0.6;
    // Build: a finer octave rises in and churns faster.
    float tb = 0.25 + build * 1.1 + drop * 0.5;
    v += curlAt(p, 6.5, vec2(time * 0.2, time * 0.14) + 3.1) * 0.5 * tb;
    v *= speed;

    // The newest kick: its dye blooms outward in a ring and is fired along the
    // emitter's heading, both only for the moment after the hit.
    float j = kickEmitter();
    vec2 e = kickPos(j);
    vec2 d = p - e;
    float kw = kickAge.w * exp(-kickAge.x / 0.18);
    float rr = 0.06 + 0.05 * kickAge.w;
    float gk = exp(-dot(d, d) / (rr * rr * 2.2));
    v += d / rr * gk * kw * 0.55;
    v += heading(j) * gk * kw * 0.30;

    // Snares: a counter-rotating vortex pair beside the newest emitter.
    if (snap > 0.01) {
        vec2 h = heading(j);
        vec2 side = vec2(-h.y, h.x) * 0.07;
        vec2 da = p - (e + side), db = p - (e - side);
        float rv = 0.075;
        v += vec2(-da.y, da.x) / rv * exp(-dot(da, da) / (rv * rv)) * snap * 0.55;
        v -= vec2(-db.y, db.x) / rv * exp(-dot(db, db) / (rv * rv)) * snap * 0.55;
    }

    // The drop: everything is thrown outward from the middle.
    vec2 dc = p - vec2(asp * 0.5, 0.5);
    v += dc * exp(-dot(dc, dc) / 0.2) * drop * drop * 1.8;
    return v;
}

// Catmull-Rom sampling from 9 bilinear taps (exact for the cubic): far less
// smearing than plain bilinear, so filaments survive many frames of transport.
vec4 sampleCR(vec2 uv) {
    vec2 size = 1.0 / texel;
    vec2 sp = uv * size;
    vec2 tc = floor(sp - 0.5) + 0.5;
    vec2 f = sp - tc;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 o12 = w2 / w12;
    vec2 t0 = (tc - 1.0) * texel, t3 = (tc + 2.0) * texel, t12 = (tc + o12) * texel;
    vec4 r = vec4(0.0);
    r += texture(prev, vec2(t0.x,  t0.y))  * w0.x  * w0.y;
    r += texture(prev, vec2(t12.x, t0.y))  * w12.x * w0.y;
    r += texture(prev, vec2(t3.x,  t0.y))  * w3.x  * w0.y;
    r += texture(prev, vec2(t0.x,  t12.y)) * w0.x  * w12.y;
    r += texture(prev, vec2(t12.x, t12.y)) * w12.x * w12.y;
    r += texture(prev, vec2(t3.x,  t12.y)) * w3.x  * w12.y;
    r += texture(prev, vec2(t0.x,  t3.y))  * w0.x  * w3.y;
    r += texture(prev, vec2(t12.x, t3.y))  * w12.x * w3.y;
    r += texture(prev, vec2(t3.x,  t3.y))  * w3.x  * w3.y;
    // Clamp to the four texels around the point: the cubic's overshoot would
    // otherwise ring, and ringing compounds frame after frame into ripples.
    vec4 a = texture(prev, tc * texel), b = texture(prev, (tc + vec2(1.0, 0.0)) * texel);
    vec4 c = texture(prev, (tc + vec2(0.0, 1.0)) * texel), d = texture(prev, (tc + 1.0) * texel);
    return clamp(r, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
}

// A soft splat of radius r at c, its edge broken up by noise so drops are not discs.
float splat(vec2 p, vec2 c, float r, float seed) {
    vec2 d = p - c;
    float n = noised(d / r * 1.7 + seed * 13.0).z;
    float q = dot(d, d) / (r * r) * (0.7 + 0.6 * n);
    return exp(-q * 2.0);
}

void main() {
    vec2 uv = qt_TexCoord0;
    if (fresh > 0.5) { fragColor = vec4(0.0); return; }
    vec2 A = vec2(asp, 1.0);
    vec2 p = uv * A;

    // ---- transport: trace back along the flow (midpoint), sample there -------
    vec2 v1 = velocity(p);
    vec2 v2 = velocity(p - v1 * dt * 0.5);
    // The view's edges are the tank's walls: the flow turns along them instead
    // of dragging dye out (or smearing the border back in).
    vec2 wall = smoothstep(vec2(0.0), vec2(0.06), min(uv, 1.0 - uv) * A);
    v2 *= wall;
    vec2 src = uv - v2 * dt / A;
    vec4 S = sampleCR(src);
    // Outside the view is clean water.
    vec2 inb = smoothstep(vec2(0.0), texel * 2.0, src) * smoothstep(vec2(0.0), texel * 2.0, 1.0 - src);
    S *= inb.x * inb.y;
    S = max(S, 0.0);

    // ---- dissipation: quiet music keeps its marbling for longer ----------------
    float loud = clamp(max(swell, energy), 0.0, 1.0);
    float life = mix(0.035, 0.14, loud) + drop * 0.10;
    S *= exp(-life * dt);
    // Dye that drifts against a wall thins out there instead of piling into a hard rim.
    float rim = wall.x * wall.y;
    S *= exp(-(1.0 - rim) * 2.5 * dt);

    // ---- injection --------------------------------------------------------------
    // Rates are per second, so the total laid down does not depend on fps.
    float j = kickEmitter();
    float hk = hash(vec2(kicks, 9.1));
    vec3 kc = j < 0.5 ? c1.rgb : (j < 1.5 ? c2.rgb : c3.rgb);
    kc = mix(kc, pal(hk), 0.3);
    // The newest kick: ~0.05 s of pour, integrating to its strength.
    float pour = kickAge.w * exp(-kickAge.x / 0.05) / 0.05;
    if (kickAge.x < 0.4) {
        float r = 0.028 + 0.022 * kickAge.w;
        float m = splat(p, kickPos(j) + heading(j) * kickAge.x * 0.08, r, kicks) * pour * 1.3 * dt;
        S += vec4(kc, 1.0) * m;
    }
    // A slow weep from every emitter, more with the music: keeps the water alive between hits.
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        vec3 ec = i == 0 ? c1.rgb : (i == 1 ? c2.rgb : c3.rgb);
        float m = splat(p, emitter(fi), 0.014 + 0.008 * loud, fi + floor(time * 0.5)) * (0.2 + 0.6 * loud) * dt;
        S += vec4(ec, 1.0) * m;
    }
    // The drop: a burst in all three colours from the middle, coloured by angle.
    if (drop > 0.02) {
        vec2 dc = p - vec2(asp * 0.5, 0.5);
        float ang = atan(dc.y, dc.x) / 6.2831853 + 0.5;
        float m = splat(p, vec2(asp * 0.5, 0.5), 0.09 + 0.08 * drop, floor(time)) * drop * drop * drop * 12.0 * dt;
        S += vec4(pal(ang + hk), 1.0) * m;
    }
    // Welcome: when the water first goes live, each emitter lets out a cloud.
    if (intro > 0.01) {
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            vec3 ec = i == 0 ? c1.rgb : (i == 1 ? c2.rgb : c3.rgb);
            S += vec4(ec, 1.0) * splat(p, emitter(fi), 0.08, fi) * intro * 4.0 * dt;
        }
    }

    // Keep it bounded: thick dye saturates instead of growing forever.
    float a = S.a;
    float cap = 2.5;
    if (a > cap) S *= cap / a;
    fragColor = S;
}
