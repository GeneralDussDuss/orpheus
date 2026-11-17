#version 440
// Orpheus Monolith deck: the album art, set into its recessed well under a
// glass cover. Two covers cross-fade (the art's swap layers), cropped to fill
// the square. The well's wall nearest the light shades the art's top-left
// edge; the glass adds a fresnel rim, a broad reflection of the room and a
// fine specular line where it meets the lip. No art: the well's anodised floor
// with a machined hatch.
//
// Redrawn only when a cover swaps or the deck resizes. Premultiplied, opaque.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float rad;
    float wA;        // layer A's share
    float wB;        // layer B's share
    vec4 metal;
    vec4 accent;
};
layout(binding = 1) uniform sampler2D srcA;
layout(binding = 2) uniform sampler2D srcB;

const vec2 TOL = vec2(-0.59, -0.80);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float sdRBox(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
// cover-crop a texture into the square
vec3 cover(sampler2D t, vec2 uv) {
    vec2 ts = vec2(textureSize(t, 0));
    float ar = ts.x / max(1.0, ts.y);
    vec2 k = ar > 1.0 ? vec2(1.0 / ar, 1.0) : vec2(1.0, ar);
    vec4 c = texture(t, (uv - 0.5) * k + 0.5);
    return c.a > 0.0 ? c.rgb / c.a : vec3(0.0);
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float s = sc;
    vec2 uv = qt_TexCoord0;
    vec2 h = res * 0.5;
    float d = sdRBox(p - h, h, rad);

    // the empty well: dark anodised floor with a fine diagonal hatch
    vec3 M = metal.rgb;
    vec3 floorC = M * 0.30 + 0.02;
    float hatch = ss(0.9, 0.0, abs(mod(p.x + p.y, 7.0 * s) - 3.5 * s) - 0.35 * s);
    floorC += M * 0.10 * hatch;
    floorC *= 0.85 + 0.3 * (1.0 - uv.y);
    vec3 col = floorC;
    float w = clamp(wA + wB, 0.0, 1.0);
    if (w > 0.0) {
        vec3 art = vec3(0.0);
        if (wA > 0.0) art += cover(srcA, uv) * wA;
        if (wB > 0.0) art += cover(srcB, uv) * wB;
        art /= max(w, 1e-3);
        col = mix(col, art, w);
    }

    // the well's wall shades the art's top and left edges
    float sh = ss(-7.0 * s, 1.0, sdRBox(p - h + TOL * 5.0 * s, h, rad));
    col *= 1.0 - 0.62 * sh;
    // ambient occlusion right at the wall all round
    col *= 1.0 - 0.45 * exp(d / (1.8 * s));

    // ---- the glass cover ----------------------------------------------------
    // fresnel: more of the room toward the rim
    float rim = exp(d / (5.0 * s));
    col = mix(col, col * 0.85 + vec3(0.10), rim * 0.35);
    // a broad soft reflection, a softbox up and to the left
    vec2 dir = normalize(vec2(1.0, -0.75));
    float across = dot(uv - vec2(0.18, 0.12), vec2(-dir.y, dir.x));
    float refl = ss(0.28, -0.05, across) * ss(-0.55, -0.05, across);
    col += vec3(1.0) * refl * 0.075;
    // a crisp streak across the corner
    float st = dot(uv - vec2(0.26, 0.26), vec2(-dir.y, dir.x));
    col += vec3(1.0) * exp(-st * st / 0.00045) * 0.05 * ss(0.9, 0.2, uv.x + uv.y);
    // the glass edge catching the light along the top and left, its rounded rim facing it
    float edge = ss(1.4 * s, 0.0, -d);
    vec2 n = normalize(vec2(p.x - h.x, p.y - h.y) / h + 1e-5);
    col += vec3(1.0) * edge * 0.28 * pow(clamp(dot(n, TOL) * 0.5 + 0.5, 0.0, 1.0), 2.0);

    col += (hash(p) - 0.5) / 255.0;
    float a = clamp(0.5 - d, 0.0, 1.0);
    fragColor = vec4(col * a, a) * qt_Opacity;
}
