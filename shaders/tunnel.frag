#version 440
// Orpheus "Tunnel": flying forward through rings of light. Each ring bends
// with the spectrum and glows by depth; warp streaks fly past; speed follows
// the energy and every kick flashes the vanishing point and pulses the rings.

//#common

void main() {
    vec2 p = (vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) - 0.5) * res / min(res.x, res.y);
    // The tube turns: the vanishing point drifts, more so deeper in (small r).
    vec2 turn = vec2(sin(time * 0.37), sin(time * 0.29 + 1.1)) * (0.07 + energy * 0.05);
    float r0 = length(p);
    p -= turn * smoothstep(0.6, 0.0, r0);
    float r = length(p) + 1e-4;
    // ...and spins, faster with the bass.
    float ang = atan(p.y, p.x) + time * (0.08 + bass * 0.25) + camRoll();
    float mirrored = abs(ang) / 3.14159265;

    float z = 0.25 / r;                                      // depth into the tunnel
    float travel = flow * 1.9;
    float lvl = band(mirrored);

    vec4 col = vec4(0.0);

    // Rings: glowing lines at regular depths, pushed outward by the spectrum.
    float zz = z - travel;
    float ringZ = zz * 1.5 + lvl * 0.35 * smoothstep(3.0, 0.5, z);
    float cell = floor(ringZ);
    float dz = abs(fract(ringZ) - 0.5);
    float aa = fwidth(ringZ) + 1e-4;
    float line = 1.0 - smoothstep(0.0, aa * 1.6, dz);
    float halo = lit(glow(dz, 0.06 + beat * 0.04)) * 0.6;
    float depthFade = smoothstep(9.0, 1.0, z);
    vec3 rc = pal(fract(cell * 0.17));
    float a = (line * (0.5 + lvl * 1.2) + halo * (0.3 + lvl)) * depthFade * (1.0 + beat * 0.6);
    col = over(col, rc, clamp(a, 0.0, 1.0));

    // Warp streaks: hairline radial dashes racing outward (1px wide at any radius).
    float sectors = 48.0;
    float sx = ang * sectors / 6.2831853;
    float sl = floor(sx);
    float seed = hash(vec2(sl, 3.0));
    float widthPx = abs(fract(sx) - 0.5) * (6.2831853 * r / sectors) * min(res.x, res.y);
    float hair = 1.0 - smoothstep(0.4, 1.4, widthPx);
    float sp = fract(seed + flow * 0.5 * (0.5 + seed));
    float dash = glow(r - sp * 0.85, 0.035 + energy * 0.03) * step(0.55, seed);
    col = over(col, c3.rgb, lit(hair * dash) * 0.8);

    // Vanishing point: dark core, bass glow, kick flash.
    float core = lit(glow(r, 0.08) * (0.25 + bass * 0.9 + beat * 1.2));
    col = over(col, mix(c1.rgb, fg.rgb, beat * 0.5), clamp(core, 0.0, 1.0));
    col.a *= smoothstep(0.012, 0.05, r) + core;

    col.a = clamp(col.a, 0.0, 1.0);
    fragColor = vec4(col.rgb * col.a + dither(p * 999.0) * col.a, col.a) * qt_Opacity;
}
