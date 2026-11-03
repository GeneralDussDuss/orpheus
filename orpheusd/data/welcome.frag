//! name: Welcome
//! scale: 0.8
// Your first Orpheus shader, written the Shadertoy way. Edit it and save:
// the stage rebuilds it in about a second, with no transition. A typo keeps
// the last good picture on screen and tells you the line.
//
// Shadertoy names work (mainImage, iTime, iResolution, iMouse, iChannel0..3),
// and so does everything Orpheus knows about the music: band(x) the spectrum,
// kick, snap, swell, beatPhase, build, drop, pal(x) the theme. See README.txt.

// Rings around the centre, each one pushed out by its own slice of the
// spectrum and coloured from the theme's palette.
float rings(vec2 p, float r0) {
    float d = length(p);
    float a = atan(p.y, p.x);
    float acc = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float b = band(0.08 + fi * 0.15);
        float wob = 0.012 * sin(a * (3.0 + fi) + iTime * (0.6 + fi * 0.2)) * (0.4 + b);
        float r = r0 + fi * 0.085 + b * 0.06 + wob;
        float w = 0.0025 + b * 0.006;
        acc += smoothstep(w * 3.0, 0.0, abs(d - r)) * (0.35 + b * 1.4) / (1.0 + fi * 0.25);
    }
    return acc;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;

    // A slow breath with the music, a kick nudge, and a push on the drop.
    float zoom = 1.0 - 0.06 * swell - 0.04 * kick - 0.08 * drop;
    p *= zoom;

    vec3 col = bg.rgb * 0.6;
    float r = rings(p, 0.14 + 0.03 * kick);
    col += pal(clamp(length(p) * 1.6, 0.0, 1.0)) * r;

    // A soft core that blooms on the beat (beatPhase is 0 exactly on it).
    float core = exp(-dot(p, p) * 40.0) * (0.25 + 0.75 * pow(1.0 - beatPhase, 6.0) * beatConfidence + 0.5 * kick);
    col += pal(0.15) * core;

    // The wave: row 1 of iChannel0, Shadertoy's convention (centred on 0.5).
    float wave = texture(iChannel0, vec2(uv.x, 0.75)).x;
    float wy = 0.18 + (wave - 0.5) * 0.22;
    col += pal(uv.x) * smoothstep(0.006, 0.0, abs(uv.y - wy)) * (0.5 + energy);

    // And the spectrum, row 0, as a floor of light along the bottom.
    float fft = texture(iChannel0, vec2(uv.x, 0.25)).x;
    col += pal(0.9) * smoothstep(fft * 0.12, 0.0, uv.y) * 0.35 * fft;

    // The drop: one white flash across the whole frame, fading over ~1.5 s.
    col += vec3(0.9, 0.95, 1.0) * drop * drop * 0.35;

    // Build-ups pull the corners in.
    float vig = smoothstep(1.25, 0.25 - 0.15 * build, length(p));
    col *= mix(0.55, 1.0, vig);

    fragColor = vec4(col, 1.0);
}
