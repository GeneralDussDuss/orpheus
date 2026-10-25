#version 440
// Orpheus bar widget: 16 tiny 2.5D columns (pairs of cava bands averaged),
// anti-aliased, with emissive tops. When nothing plays they settle into a
// faint line that breathes slowly.

//#common

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float n = 16.0;
    float pitch = res.x / n;
    float w = max(1.0, pitch * 0.58);
    float d = max(1.0, pitch * 0.30);
    float base = res.y * 0.18;
    float maxH = res.y * 0.64;
    float idle = 1.0 - smoothstep(0.0, 0.04, energy);

    vec4 col = vec4(0.0);
    for (int i = 0; i < 16; i++) {
        float x0 = float(i) * pitch + (pitch - w - d) * 0.5;
        if (p.x < x0 - 2.0 || p.x > x0 + w + d + 2.0) continue;
        float lvl = 0.5 * (bandAt(i * 2) + bandAt(i * 2 + 1));
        float breath = 0.05 + 0.035 * sin(time * 1.2 + float(i) * 0.5);
        float h = max(1.0, mix(lvl, breath, idle) * maxH);
        vec3 tint = pal(float(i) / 15.0);
        float heat = smoothstep(0.4, 1.0, lvl);
        float alpha = mix(1.0, 0.45, idle);
        float t = clamp((p.y - base) / h, 0.0, 1.0);

        float aS = clamp(min(min(p.x - (x0 + w), x0 + w + d - p.x), min(p.y - (base + (p.x - x0 - w)), base + h + (p.x - x0 - w) - p.y)) + 0.5, 0.0, 1.0);
        float aF = boxAA(p, vec2(x0, base), vec2(x0 + w, base + h));
        float aT = shearAA(p, x0, base + h, w, d, d);
        col = over(col, tint * 0.5, aS * alpha);
        col = over(col, mix(tint * 0.6, mix(tint, vec3(1.0), 0.3 * heat * (1.0 - light)), t), aF * alpha);
        col = over(col, mix(tint, fg.rgb, 0.3 + 0.4 * heat), aT * alpha);
    }
    fragColor = vec4(col.rgb * col.a, col.a) * qt_Opacity;
}
