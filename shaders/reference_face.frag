#version 440
// Orpheus "Reference" deck (WidgetReference.qml): the faceplate. One still
// frame of machined metal -- no clock, cached in a layer, redrawn only on a
// resize or a theme change. Horizontally brushed aluminium (black anodised on
// a dark theme, silver on a light one, both tinted by the theme), a diamond-cut
// chamfer round the edge, the wells the display, the art, the knob and the key
// row sit in (each with a bright cut lip and a shaded wall), hex-socket cap
// screws in the corners, a recessed model plate, a lathe-turned spot face under
// the knob and the engraved, paint-filled position dial round it.
//
// Pixel space, y down. Light from the top left, a little in front. The moving
// specular band is a separate overlay (reference_sheen.frag) so this one never
// has to redraw. Premultiplied output.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;        // the deck's scale (1 at 400 px wide)
    float light;     // 1 on a light theme
    vec4 metal;      // the faceplate's base colour
    vec4 ink;        // paint fill for engravings
    vec4 well;       // the floor of a recess
    vec4 vfdR;       // well rects, px (x, y, w, h)
    vec4 artR;
    vec4 knobR;      // cx, cy, knob radius, dial radius
    vec4 keysR;
    vec4 plateR;
    vec4 ledA;       // x of the LEDs 0..3
    vec4 ledB;       // x of LED 4, LED y, LED radius, -
};

const float PI = 3.14159265;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
// Horizontal brushing: long strands, thin across. 0..1, mean ~0.5.
float brush(vec2 p) {
    float a = vnoise(vec2(p.x * 0.0035, p.y * 1.25));
    float b = vnoise(vec2(p.x * 0.012 + 17.0, p.y * 2.3));
    float c = vnoise(vec2(p.x * 0.06 + 41.0, p.y * 3.1));
    return a * 0.5 + b * 0.32 + c * 0.18;
}

float sdRBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float sdRect(vec2 p, vec4 R, float r) { return sdRBox(p - (R.xy + R.zw * 0.5), R.zw * 0.5, r); }
// The outward direction of a rounded box at p (good enough near the edge).
vec2 nRect(vec2 p, vec4 R, float r) {
    vec2 c = R.xy + R.zw * 0.5;
    vec2 d = p - c;
    vec2 q = abs(d) - R.zw * 0.5 + r;
    vec2 s = vec2(d.x < 0.0 ? -1.0 : 1.0, d.y < 0.0 ? -1.0 : 1.0);
    if (max(q.x, q.y) > 0.0) { vec2 m = max(q, 0.0); return s * m / max(length(m), 1e-4); }
    return q.x > q.y ? vec2(s.x, 0.0) : vec2(0.0, s.y);
}

const vec3 L = vec3(-0.38, -0.78, 0.5);   // normalised below; y down = light from above
vec3 Ln() { return normalize(L); }

// A tilted facet lit by the key light: n2 is the in-plane tilt direction,
// t how far it leans (0 flat, 1 vertical). Returns diffuse, spec.
vec2 shade(vec2 n2, float t) {
    vec3 n = normalize(vec3(n2 * t, 1.0 - 0.55 * t));
    vec3 l = Ln();
    float d = max(dot(n, l), 0.0);
    vec3 h = normalize(l + vec3(0, 0, 1));
    float s = pow(max(dot(n, h), 0.0), 40.0);
    return vec2(d, s);
}

vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

// A machined pocket: a bright cut lip just outside, a shaded wall, a dark floor
// with a contact shadow under the top edge. Returns the new colour.
vec3 pocket(vec3 col, vec2 p, vec4 R, float r, float wall, float depth) {
    float d = sdRect(p, R, r);
    if (d > 2.5 * sc) return col;
    vec2 n = nRect(p, R, r);
    // diamond-cut lip (a 45° chamfer facing out and up)
    float lipW = 1.3 * sc;
    float lip = clamp(1.0 - abs(d - lipW * 0.5) / (lipW * 0.5 + 0.5), 0.0, 1.0);
    vec2 sl = shade(n, 0.75);
    vec3 lipC = col * (0.55 + 0.6 * sl.x) + vec3(sl.y * 0.9 + 0.12 * sl.x);
    col = mix(col, lipC, lip * step(-0.5, d));
    // the wall, facing in
    float inWall = clamp(0.5 - d, 0.0, 1.0) * clamp(d + wall + 0.5, 0.0, 1.0);
    vec2 sw = shade(-n, 0.9);
    vec3 wallC = well.rgb * 0.6 + col * (0.15 + 0.55 * sw.x) + vec3(sw.y * 0.25);
    col = mix(col, wallC, inWall);
    // the floor
    float inFloor = clamp(-(d + wall) + 0.5, 0.0, 1.0);
    float top = p.y - R.y - wall;
    float sh = 1.0 - depth * exp(-max(top, 0.0) / (5.0 * sc)) - 0.25 * depth * exp(-max(-(d + wall), 0.0) / (3.0 * sc));
    col = mix(col, well.rgb * sh, inFloor);
    return col;
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float lt = light;
    vec4 o = vec4(0.0);

    // ---- the body --------------------------------------------------------------
    vec4 body = vec4(0.0, 0.0, res);
    float rb = 3.0 * sc;
    float dB = sdRect(p, body, rb);
    float aB = clamp(0.5 - dB, 0.0, 1.0);
    if (aB <= 0.0) { fragColor = vec4(0.0); return; }

    vec3 m = metal.rgb;
    float b = brush(p);
    float fine = hash(vec2(floor(p.y * 1.0), floor(p.x * 0.08)));
    // the room's light falls from above: a broad soft gradient, a little
    // brighter to the left, a cool sky in the polish
    float yN = p.y / res.y, xN = p.x / res.x;
    float room = mix(1.10, 0.84, yN) * mix(1.04, 0.97, xN);
    vec3 col = m * room * (0.90 + 0.22 * b + 0.04 * fine);
    // the polish: anisotropic, so it streaks along the strands
    float aniso = 0.5 + 0.5 * (b - 0.5) * 2.6;
    float soft = exp(-pow((xN - 0.22) / 0.42, 2.0)) * mix(1.0, 0.55, yN);
    col += vec3(mix(0.030, 0.075, lt)) * soft * max(aniso, 0.0);
    col += vec3(mix(0.012, 0.03, lt)) * (b - 0.5);

    // ---- the outer edge: a diamond-cut chamfer -------------------------------
    {
        float ch = 2.2 * sc;
        float t = clamp((dB + ch) / ch, 0.0, 1.0);          // 0 inside .. 1 at the edge
        if (dB > -ch - 1.0) {
            vec2 n = nRect(p, body, rb);
            vec2 s = shade(n, 0.8);
            vec3 cc = m * (0.45 + 0.75 * s.x) + vec3(s.y * 0.85 + 0.10 * s.x);
            col = mix(col, cc, smoothstep(0.0, 0.25, t));
            // the arris: one hair of white where the chamfer meets the face
            col += vec3(0.10 + 0.25 * lt) * exp(-pow((dB + ch) / (0.6 * sc), 2.0)) * clamp(-n.y * 0.6 - n.x * 0.4 + 0.5, 0.0, 1.0);
        }
    }

    // ---- the model plate: a shallow recessed strip ---------------------------
    {
        float d = sdRect(p, plateR, 1.5 * sc);
        if (d < 2.0 * sc) {
            vec3 plate = mix(m * 0.62, m * 0.86, lt);
            float pb = vnoise(vec2(p.x * 0.01, p.y * 2.2));
            vec3 floorC = plate * (0.96 + 0.08 * pb) * mix(1.06, 0.94, (p.y - plateR.y) / max(plateR.w, 1.0));
            vec2 n = nRect(p, plateR, 1.5 * sc);
            float lipW = 1.0 * sc;
            float lip = clamp(1.0 - abs(d - lipW * 0.5) / (lipW * 0.5 + 0.5), 0.0, 1.0) * step(-0.5, d);
            vec2 sl = shade(n, 0.75);
            col = mix(col, col * (0.55 + 0.6 * sl.x) + vec3(sl.y * 0.8 + 0.1 * sl.x), lip);
            float wallW = 1.2 * sc;
            float inWall = clamp(0.5 - d, 0.0, 1.0) * clamp(d + wallW + 0.5, 0.0, 1.0);
            vec2 sw = shade(-n, 0.9);
            col = mix(col, floorC * (0.35 + 0.6 * sw.x) + vec3(sw.y * 0.2), inWall);
            float inF = clamp(-(d + wallW) + 0.5, 0.0, 1.0);
            float top = p.y - plateR.y - wallW;
            col = mix(col, floorC * (1.0 - 0.35 * exp(-max(top, 0.0) / (2.5 * sc))), inF);
        }
    }

    // ---- the wells ----------------------------------------------------------------
    col = pocket(col, p, vfdR, 2.5 * sc, 3.0 * sc, 0.5);
    col = pocket(col, p, keysR, 2.0 * sc, 2.0 * sc, 0.55);

    // the art: a pocket, then a half-round polished chrome bezel inside it
    {
        vec4 R = artR;
        float bz = 6.0 * sc, wl = 1.2 * sc;
        vec4 W = vec4(R.xy - bz, R.zw + 2.0 * bz);
        col = pocket(col, p, W, 2.0 * sc, wl, 0.6);
        float d = sdRect(p, W, 2.0 * sc);
        float dIn = sdRect(p, R, 0.5 * sc);
        if (d < -wl + 0.5 && dIn > -0.5) {
            // across the rail the normal rolls from leaning out to leaning in,
            // so it mirrors the room: the sky above, a window to the left, the
            // dark horizon band between
            float u = clamp((-d - wl) / max(bz - wl, 1.0), 0.0, 1.0);   // 0 outer .. 1 inner
            vec2 n = nRect(p, R, 0.5 * sc);
            float th = (0.5 - u) * 1.5;
            vec3 nn = normalize(vec3(n * sin(th), cos(th)));
            float ry = -nn.y, rx = nn.x;
            float env = 0.34 + 0.62 * smoothstep(-0.45, 0.55, ry);
            env -= 0.30 * exp(-pow((ry + 0.02) / 0.10, 2.0)) * (1.0 - smoothstep(0.2, 0.6, abs(rx)));
            env += 0.30 * smoothstep(-0.05, -0.6, rx);
            env -= 0.18 * smoothstep(0.1, 0.6, rx);
            vec3 l = Ln();
            vec3 h = normalize(l + vec3(0, 0, 1));
            float sp = pow(max(dot(nn, h), 0.0), 60.0);
            vec3 tn = m / max(max(m.r, max(m.g, m.b)), 0.05);
            vec3 chrome = vec3(env) * mix(vec3(1.0), tn, 0.18) + vec3(sp * 0.9);
            chrome *= mix(0.82, 0.95, lt);
            float a = clamp(-d - wl + 0.5, 0.0, 1.0) * clamp(dIn + 0.5, 0.0, 1.0);
            col = mix(col, chrome, a);
            // the shadow line where the art meets the bezel
            col *= 1.0 - 0.55 * exp(-pow(dIn / (0.7 * sc), 2.0));
        }
        if (dIn < 0.0) col = well.rgb * 0.7;
    }

    // ---- the knob: a lathe-turned spot face, and the dial round it -------------
    {
        vec2 c = knobR.xy;
        float rk = knobR.z, rd = knobR.w;
        vec2 v = p - c;
        float r = length(v);
        float th = atan(v.x, -v.y);                  // 0 up, clockwise
        float rs = rk + 7.0 * sc;                    // the spot face
        if (r < rs + 2.0 * sc) {
            float d = r - rs;
            vec2 n = v / max(r, 1e-3);
            // the cut lip
            float lip = clamp(1.0 - abs(d - 0.6 * sc) / (0.6 * sc + 0.5), 0.0, 1.0) * step(-0.5, d);
            vec2 sl = shade(n, 0.75);
            col = mix(col, col * (0.55 + 0.6 * sl.x) + vec3(sl.y * 0.9 + 0.12 * sl.x), lip);
            // turned floor: fine rings, and the circular polish shows as a
            // bow tie pointing at the light
            float inF = clamp(0.5 - d, 0.0, 1.0);
            float rings = vnoise(vec2(r * 1.7, 3.0)) * 0.6 + vnoise(vec2(r * 0.45, 9.0)) * 0.4;
            float la = atan(Ln().x, -Ln().y);
            float bow = pow(abs(cos(th - la)), 18.0);
            vec3 sf = m * mix(0.80, 0.95, lt) * (0.92 + 0.16 * rings) + vec3(mix(0.05, 0.10, lt)) * bow * (0.4 + rings);
            sf *= 1.0 - 0.45 * exp(-max(-d, 0.0) / (1.2 * sc)) * clamp(0.5 - n.y, 0.0, 1.0);
            col = mix(col, sf, inF);
        }
        // the dial: 41 engraved, paint-filled ticks across 270°, a long one
        // every quarter; the groove's lower lip catches the light
        float a0 = -0.75 * PI, span = 1.5 * PI;
        float f = (th - a0) / span;
        if (f > -0.03 && f < 1.03 && r > rd - 12.0 * sc && r < rd + 2.0 * sc) {
            float n41 = 40.0;
            float k = floor(f * n41 + 0.5);
            k = clamp(k, 0.0, n41);
            float ta = a0 + span * k / n41;
            vec2 dir = vec2(sin(ta), -cos(ta));
            vec2 tg = vec2(cos(ta), sin(ta));
            bool major = mod(k, 10.0) < 0.5;
            bool mid = mod(k, 5.0) < 0.5;
            float r0 = major ? rd - 10.0 * sc : mid ? rd - 7.0 * sc : rd - 5.0 * sc;
            float hw = (major ? 0.9 : 0.68) * sc;
            float along = dot(v, dir), across = dot(v, tg);
            float dl = max(abs(across) - hw, max(r0 - along, along - rd));
            float a = clamp(0.5 - dl, 0.0, 1.0);
            // highlight on the lower side of the cut
            float dh = max(abs(across - 0.0) - hw, max(r0 - along, along - rd));
            vec2 off = vec2(0.0, 1.0) * sc;
            vec2 v2 = v - off;
            float al2 = dot(v2, dir), ac2 = dot(v2, tg);
            float dl2 = max(abs(ac2) - hw, max(r0 - al2, al2 - rd));
            float hi = clamp(0.5 - dl2, 0.0, 1.0) * (1.0 - a);
            col = mix(col, col + vec3(0.10 + 0.08 * lt), hi * 0.6);
            col = mix(col, ink.rgb * mix(0.85, 1.0, lt), a * (major ? 1.0 : 0.85));
        }
        // a hairline arc under the ticks
        {
            float arcA = clamp(1.0 - abs(r - (rd + 0.0)) / (0.45 * sc + 0.5), 0.0, 1.0) * step(-0.001, f) * step(f, 1.001);
            col = mix(col, ink.rgb, arcA * 0.35);
        }
    }

    // ---- the LED bezels over the keys ---------------------------------------------
    {
        float ly = ledB.y, lr = ledB.z;
        for (int i = 0; i < 5; i++) {
            float lx = i < 4 ? ledA[i] : ledB.x;
            vec2 v = p - vec2(lx, ly);
            float r = length(v);
            float rr = lr + 1.6 * sc;
            if (r < rr + 1.5) {
                vec2 n = v / max(r, 1e-3);
                // a polished chrome ring standing proud of the plate
                float ring = clamp(rr - r + 0.5, 0.0, 1.0) * clamp(r - lr + 0.5, 0.0, 1.0);
                vec2 s = shade(n, 0.7);
                vec3 rc = vec3(0.25 + 0.75 * s.x) * mix(0.75, 1.0, lt) + vec3(s.y);
                col = mix(col, rc, ring);
                // its shadow on the plate below
                float sh = clamp(r - rr, 0.0, 3.0 * sc) / (3.0 * sc);
                col *= 1.0 - 0.25 * (1.0 - sh) * step(rr, r) * clamp(n.y + 0.3, 0.0, 1.0);
                if (r < lr) col = well.rgb * 0.5;
            }
        }
    }

    // ---- hex-socket cap screws -------------------------------------------------
    {
        float sr = 5.0 * sc;
        float ins = 11.5 * sc;
        vec2 cs[4] = vec2[](vec2(ins, ins), vec2(res.x - ins, ins), vec2(ins, res.y - ins), vec2(res.x - ins, res.y - ins));
        float rot[4] = float[](0.3, 1.1, 0.75, 0.05);
        for (int i = 0; i < 4; i++) {
            vec2 v = p - cs[i];
            float r = length(v);
            if (r > sr + 3.0 * sc) continue;
            // counterbore shadow ring
            float cb = clamp(1.0 - abs(r - sr - 0.7 * sc) / (1.2 * sc), 0.0, 1.0);
            col *= 1.0 - 0.55 * cb;
            float lipR = sr + 1.8 * sc;
            float lip = clamp(1.0 - abs(r - lipR) / (0.6 * sc + 0.5), 0.0, 1.0);
            vec2 sl = shade(v / max(r, 1e-3), 0.7);
            col = mix(col, col * (0.6 + 0.6 * sl.x) + vec3(0.5 * sl.y), lip * 0.8);
            if (r < sr + 0.5) {
                // the domed head
                float rn = r / sr;
                vec2 n2 = v / max(r, 1e-3);
                vec2 s = shade(n2, rn * rn * 0.9);
                vec3 head = mix(vec3(0.58), vec3(0.66), lt) * (0.35 + 0.80 * s.x) + vec3(s.y * 0.8);
                head = mix(head, head * mix(vec3(1.0), m / max(max(m.r, max(m.g, m.b)), 0.05), 0.35), 0.5);
                // fine turning marks
                head *= 0.94 + 0.06 * vnoise(vec2(r * 3.0, 1.0));
                // the hex socket
                float a = rot[i];
                vec2 q = mat2(cos(a), -sin(a), sin(a), cos(a)) * v;
                vec2 qa = abs(q);
                float hex = max(dot(qa, vec2(0.8660254, 0.5)), qa.y) - 2.1 * sc;
                float inHex = clamp(0.5 - hex, 0.0, 1.0);
                vec3 sock = vec3(0.03) + vec3(0.07) * clamp(q.y / (2.1 * sc), 0.0, 1.0);
                head = mix(head, sock, inHex);
                // the socket's top wall in light, bottom in shade
                head += vec3(0.25) * clamp(1.0 - abs(hex + 0.4 * sc) / (0.5 * sc), 0.0, 1.0) * clamp(q.y / (1.9 * sc) + 0.2, 0.0, 1.0) * inHex;
                col = mix(col, head, clamp(sr - r + 0.5, 0.0, 1.0));
            }
        }
    }

    // a whisper of grain so the gradients never band
    col += vec3((hash(p + 0.37) - 0.5) / 255.0);
    fragColor = vec4(col * aB, aB) * qt_Opacity;
}
