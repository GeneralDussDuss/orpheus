#version 440
// Orpheus "Scope": an oscilloscope ribbon. The spectrum is played back as a
// sum of eight standing waves (one per group of four bands), so the bass bends
// the line in long slow swells and the treble shivers along it. Three strands
// in the theme colours weave around each other, each dragging a fading
// phosphor trail behind it, over a faint CRT graticule. Kicks flash the beam.

//#common

const float PI = 3.14159265;

// Wave height (in units of the view height) and its slope at x (0..1).
// amp holds the eight band groups; ph shifts every harmonic's phase.
vec2 wave(float x, float amp[8], float ph, float speed) {
    float y = 0.0, dy = 0.0;
    for (int k = 0; k < 8; k++) {
        float fk = float(k);
        float f = (1.0 + fk * 1.65) * 2.0 * PI;              // spatial frequency
        float w = time * speed * (0.6 + fk * 0.35) + ph * (1.0 + fk * 0.5);
        float a = amp[k] * (0.13 / (1.0 + fk * 0.45));        // treble ripples are smaller
        y += a * sin(f * x + w);
        dy += a * f * cos(f * x + w);
    }
    // Pin the ends like a plucked string: envelope e = sin(pi x)^0.6.
    float s = max(sin(PI * x), 1e-3);
    float e = pow(s, 0.6);
    float de = 0.6 * pow(s, -0.4) * PI * cos(PI * x);
    return vec2(y * e, dy * e + y * de);
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    px = rotateAround(px, res * 0.5, camRoll() * 0.5);
    float H = res.y;
    float x = px.x / res.x;
    float yc = res.y * 0.5 + camBob(res.y);

    float amp[8] = float[8](dot(b0, vec4(0.25)), dot(b1, vec4(0.25)), dot(b2, vec4(0.25)), dot(b3, vec4(0.25)),
                            dot(b4, vec4(0.25)), dot(b5, vec4(0.25)), dot(b6, vec4(0.25)), dot(b7, vec4(0.25)));
    // A little idle motion so the line is never dead flat in silence.
    for (int k = 0; k < 8; k++) amp[k] = amp[k] * (1.0 + beat * 0.5) + 0.012;

    vec4 col = vec4(0.0);    // premultiplied

    // Graticule: a 10x8 grid of hairlines with tick marks on the centre axes.
    vec2 g = px / vec2(res.x / 10.0, res.y / 8.0);
    vec2 gd = abs(fract(g + 0.5) - 0.5) * vec2(res.x / 10.0, res.y / 8.0);
    float grid = max(1.0 - smoothstep(0.3, 1.2, gd.x), 1.0 - smoothstep(0.3, 1.2, gd.y)) * 0.07;
    float axis = (1.0 - smoothstep(0.3, 1.2, abs(px.y - yc))) * 0.10;
    float ticks = (1.0 - smoothstep(0.3, 1.2, abs(fract(px.x / (res.x / 50.0) + 0.5) - 0.5) * (res.x / 50.0)))
                * step(abs(px.y - yc), H * 0.008) * 0.18;
    float gr = (grid + axis + ticks) * (1.0 - 0.5 * light);
    col.rgb += gr * mix(c2.rgb, fg.rgb, 0.3);
    col.a += gr;

    vec3 cs[3] = vec3[3](c1.rgb, c2.rgb, c3.rgb);
    for (int s = 0; s < 3; s++) {
        float fs = float(s);
        float ph = fs * 2.1;
        float sc = 1.0 - fs * 0.18;                          // back strands are a little quieter
        // Trail: the same strand a moment earlier, dimmer and softer each step.
        for (int j = 2; j >= 0; j--) {
            float fj = float(j);
            vec2 w = wave(x, amp, ph - fj * 0.10, 1.0 + fs * 0.25) * H * sc;
            float d = abs(px.y - (yc + w.x)) / sqrt(1.0 + (w.y / res.x) * (w.y / res.x));
            float width = 1.1 + (1.0 - fs * 0.25) * (0.6 + energy * 1.4) - fj * 0.45;
            float core = clamp(width - d + 0.5, 0.0, 1.0) * (j == 0 ? 1.0 : 0.38 / fj);
            float halo = lit(glow(d, H * (0.010 + energy * 0.012 + beat * 0.010))) * (0.30 + beat * 0.5) * (1.0 - fj * 0.3);
            vec3 hc = mix(cs[s], fg.rgb, 0.35 * (1.0 - light) * (1.0 - fj * 0.5));
            col.rgb += (1.0 - col.a) * core * hc + halo * cs[s] * 0.6;
            col.a += (1.0 - col.a) * core + halo * 0.35;
        }
    }

    // Edge vignette: the beam fades into the bezel at both ends.
    float edge = smoothstep(0.0, 0.04, x) * smoothstep(1.0, 0.96, x);
    col *= edge;

    // Beam flash: a wide wash along the centre line on kicks.
    float wash = lit(glow(px.y - yc, H * 0.18) * beat * 0.18 * edge);
    col.rgb += wash * c2.rgb;
    col.a += wash * 0.5;

    col.a = clamp(col.a, 0.0, 1.0);
    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
