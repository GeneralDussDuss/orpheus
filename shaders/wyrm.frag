#version 440
// Orpheus "Wyrm": gliding through the ribcage of a dead titan, forever.
// The spine runs beneath you — a chain of vertebrae following a slow
// serpentine, half-drowned in a drift of sand — and from every vertebra a
// rib rises and closes overhead, so the realm is an endless vaulted cage of
// bone, vast enough to lose the roof in the fog. The bone is old: pitted,
// grown in rings like a tree, split by hairline fractures — and about one
// rib in six is snapped, a jagged stump and a healed knob of callus where
// the arch gave way. The bones are lit only by what still lives here: each
// rib hums with its band of the spectrum (ribs you pass are bass, ribs
// ahead treble — a chord stands in the skeleton as depth), a cold
// marrow-light that seeps OUT through the fractures. Kicks run a pulse of
// light rib to rib away down the cage, like a nerve firing one last time.
// Cold sheets of light fall slanted through the gaps between the ribs, dust
// turning in them, each sheet answering its own part of the spectrum. The
// build starves the glow and tightens the fog until only knuckles of light
// remain — the drop-map wind-up sets the deep chest glimmering — and ahead,
// suspended in the chest, hangs the heart: a dim, vein-laced organ that
// stirs on the downbeat and, on the drop, lights ONCE, a huge red-gold
// blaze that silhouettes every rib in front of it and fades like an
// afterimage. `flow` carries you down the spine at a glide.
// Light themes: the museum hall — pale bone on paler air, shade-drawn.
// Cost: 54 steps of an analytic DE (torus ribs + sphere vertebrae + sand
// drift + blobbed heart), 3 analytic light sheets per step, no textures;
// value-noise surface detail is evaluated once per pixel, at the hit.

//#common

const float PI = 3.14159265;
const int STEPS = 54;
const float TMAX = 30.0;
const float SPEED = 1.7;
const float RIBZ = 2.2;        // one rib every RIBZ down the spine
const float RIBR = 3.6;        // rib cage radius
const float BONE = 0.19;       // rib thickness
const float RRAD = RIBR / 1.9; // rib ring radius in its own (ellipse) space
const float RCY = RIBR * 0.62; // height of the ring centre above the spine
const float XSC = 1.25;        // the cage is wider than a circle...
const float YSC = 1.18;        // ...and taller
const float SANDY = 0.95;      // sand drift level above the spine line
const float VY = 0.72;         // the spine knuckles ride this high

// the heart's tilt
const mat2 HROT = mat2(0.92, -0.39, 0.39, 0.92);

// globals written by map(), read by the march and the shading
float gMat = 0.0;       // 0 rib, 1 spine, 2 sand, 3 heart
vec2 gSp = vec2(0.0);   // spine position at the last sampled depth
vec3 gHeart = vec3(0.0);
float gHeartK = 1.0;

// The spine's serpentine path: where the backbone sits at depth z.
vec2 spinePath(float z) {
    return vec2(0.9 * sin(z * 0.14) + 0.4 * sin(z * 0.057 + 1.2),
                -1.15 + 0.25 * sin(z * 0.09 + 0.5));
}

float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float hash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }

// Value noise with its analytic gradient: .x value, .yzw d/dp.
vec4 vnoise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    vec3 u = f * f * (3.0 - 2.0 * f);
    vec3 du = 6.0 * f * (1.0 - f);
    float a = hash3(i);
    float b = hash3(i + vec3(1.0, 0.0, 0.0));
    float c = hash3(i + vec3(0.0, 1.0, 0.0));
    float d = hash3(i + vec3(1.0, 1.0, 0.0));
    float e = hash3(i + vec3(0.0, 0.0, 1.0));
    float f1 = hash3(i + vec3(1.0, 0.0, 1.0));
    float g = hash3(i + vec3(0.0, 1.0, 1.0));
    float h = hash3(i + vec3(1.0, 1.0, 1.0));
    float k1 = b - a, k2 = c - a, k3 = e - a;
    float k4 = a - b - c + d, k5 = a - c - e + g, k6 = a - b - e + f1;
    float k7 = -a + b + c - d + e - f1 - g + h;
    float v = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z
            + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
    vec3 gr = du * vec3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
                        k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
                        k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
    return vec4(v, gr);
}

// The heart: a few blended lumps hanging in the chest.
float heartD(vec3 p) {
    vec3 q = (p - gHeart) / gHeartK;
    q.xy = HROT * q.xy;
    float a = length(q - vec3(0.15, -0.15, 0.0)) - 0.85;     // left ventricle
    float b = length(q - vec3(-0.5, 0.05, 0.1)) - 0.6;       // right ventricle
    float c = length(q - vec3(0.35, 0.7, -0.2)) - 0.45;      // atrium
    float d = length(q - vec3(-0.15, 0.95, 0.15)) - 0.3;     // the aorta's root
    float h = smin(smin(a, b, 0.4), smin(c, d, 0.3), 0.35);
    return h * gHeartK;
}

// Distance to the cage at p. Also returns the rib index for lighting.
float map(vec3 p, out float ribI) {
    vec2 sp = spinePath(p.z);
    gSp = sp;
    vec3 q = vec3(p.xy - sp, p.z);
    // which rib slab are we in
    float seg = floor(q.z / RIBZ + 0.5);
    float lz = q.z - seg * RIBZ;
    ribI = seg;
    // the rib: a torus in the plane of this segment, centred above the spine,
    // an ellipse (taller than wide) like a true ribcage
    vec2 ell = vec2(q.x / XSC, (q.y - RCY) / YSC);
    float ang = atan(ell.x, ell.y);                          // 0 at the crown
    float ring = abs(length(ell) - RRAD) * 1.1;
    float thick = BONE * (1.0 + 0.25 * sin(seg * 2.7))
                * (0.8 + 0.4 * smoothstep(0.0, 2.6, abs(ang)));   // stouter at the root
    float rib = length(vec2(ring, lz)) - thick;
    // about one rib in six has snapped in the upper arc
    if (hash(vec2(seg, 7.3)) < 0.17) {
        float h2 = hash(vec2(seg, 3.1));
        float h3 = hash(vec2(seg, 9.7));
        float bc = (h2 * 2.0 - 1.0) * 0.8;                   // where it broke
        float gw = 0.30 + 0.22 * h3;                         // how much is gone
        float jag = 0.06 * sin(lz * 21.0 + ring * 17.0 + seg)
                  + 0.035 * sin(lz * 47.0 - ring * 31.0);    // splintered edge
        float cut = (gw + jag - abs(ang - bc)) * RRAD;
        rib = max(rib, cut * 0.8);
        // a knob of callus at one stump
        float ae = bc + (h3 > 0.5 ? 1.0 : -1.0) * (gw - 0.1);
        vec3 kd = vec3(q.xy, lz) - vec3(XSC * RRAD * sin(ae), RCY + YSC * RRAD * cos(ae), 0.0);
        float knob = length(kd) - thick * 1.55 + 0.05 * sin(kd.x * 23.0) * sin(kd.y * 19.0 + kd.z * 13.0);
        rib = smin(rib, knob, 0.1);
    }
    // the vertebra: a knuckle at the spine every segment
    vec3 qs = vec3(q.x, q.y - VY, lz);
    float vert = length(qs) - 0.5;
    // the spinal column between knuckles
    float col = length(qs.xy) - 0.24;
    // the sand drift: a soft heightfield that swallows the ribs' roots
    float dune = 0.3 * sin(p.x * 0.45 + p.z * 0.23) + 0.12 * sin(p.z * 0.71 - p.x * 0.9 + 1.3);
    float fl = (p.y - sp.y - SANDY - dune) * 0.75;

    float bone = min(rib, min(vert, col));
    float d = smin(bone, fl, 0.3);
    gMat = fl < bone ? 2.0 : (rib <= min(vert, col) ? 0.0 : 1.0);
    if (abs(p.z - gHeart.z) < 2.0) {
        float hd = heartD(p);
        if (hd < d) { d = hd; gMat = 3.0; }
    }
    return d;
}

float mapD(vec3 p) { float r; return map(p, r); }

// Slanted sheets of cold light falling between the ribs. q is spine-relative.
// Returns the band-weighted brightness; `dens` is the unweighted presence.
float shafts(vec3 q, vec3 sb, out float dens) {
    float acc = 0.0;
    dens = 0.0;
    float vert = smoothstep(1.0, 2.0, q.y) * (1.0 - smoothstep(4.2, 5.8, q.y));
    float dz = abs(fract(q.z / RIBZ + 0.5) - 0.5) * RIBZ;    // distance to the nearest rib plane
    float occ = smoothstep(0.15, 0.6, dz);                   // ribs shade the sheet
    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        float sl = k == 0 ? 0.7 : (k == 1 ? -0.55 : 1.15);
        float u = (q.z + q.y * sl) / RIBZ + 0.33 * fk;
        float f = fract(u) - 0.5;
        float s = exp(-f * f / 0.0144);
        float m = smoothstep(0.3, 0.8, hash(vec2(floor(u), fk * 3.1 + 0.7)));
        float lx = (q.x - (fk - 1.0) * 1.3) / 1.9;
        float dk = s * m * exp(-lx * lx) * vert * occ;
        acc += dk * sb[k];
        dens += dk;
    }
    return acc;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float mres = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / mres;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    float conf = clamp(beatConfidence, 0.0, 1.0);
    float hp = downbeat * conf;                              // the heart's slow stir

    // ---- the glide: down the spine, riding its serpentine ----
    float zc = flow * SPEED;
    vec2 sp0 = spinePath(zc);
    vec3 ro = vec3(sp0 + vec2(0.0, 2.1 + 0.15 * sin(zc * 0.11)), zc);
    vec2 spA = spinePath(zc + 4.0);
    vec3 fw = normalize(vec3(spA + vec2(0.0, 2.0), zc + 4.0) - ro);
    float roll = camRoll() + (spA.x - sp0.x) * 0.12;        // bank into the bends
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * 0.92);

    // ---- the heart: suspended ahead in the chest, lighting once on the drop ----
    float hz = zc + 8.5;
    gHeart = vec3(spinePath(hz) + vec2(0.0, 0.0), hz);
    gHeart.y += 2.4 + 0.08 * sin(time * 0.6);
    gHeartK = 1.1 + 0.05 * hp + 0.2 * dr;
    float heartGlow = dr * dr + ant * 0.1 * (0.6 + 0.4 * sin(time * 5.0)) + 0.05 * hp;
    vec3 heartC = mix(c3.rgb, pal(0.95), 0.5);

    // ---- the light sheets: one per region of the spectrum ----
    vec3 sb = vec3(0.0);
    for (int k = 0; k < 3; k++) {
        float bk = pow(clamp(band(0.08 + 0.32 * float(k)), 0.0, 1.0), 0.7);
        sb[k] = (0.12 + 1.0 * bk) * (1.0 - 0.5 * bd) * (1.0 + 0.2 * ant);
    }
    vec3 shaftCol = mix(c1.rgb, fg.rgb, 0.55);
    vec3 moteCol = mix(fg.rgb, shaftCol, 0.3);

    // ---- march ----
    float jit = hash(px + fract(time) * 61.7);
    float t = 0.05 + jit * 0.3;
    float ribI = 0.0;
    bool hitS = false;
    float fogK = 0.10 + 0.05 * bd - 0.02 * loud;
    fogK *= 1.0 - 0.12 * downbeat * conf;
    vec3 airGlow = vec3(0.0);
    vec3 shaftAcc = vec3(0.0);
    for (int i = 0; i < STEPS; i++) {
        vec3 p = ro + rd * t;
        float d = map(p, ribI);
        if (d < 0.004 * t + 0.003) { hitS = true; break; }
        float st = min(d * 0.85, 0.8);
        // the heart's light fills the dust while it burns
        if (heartGlow > 0.01) {
            float hd = length(p - gHeart);
            airGlow += heartC * exp(-hd * 0.4) * heartGlow * 0.035 * min(d, 0.6);
        }
        // the light sheets, and the dust turning in them
        float shD;
        float sw = shafts(vec3(p.xy - gSp, p.z), sb, shD);
        float att = 1.0 / (1.0 + t * 0.1);
        shaftAcc += shaftCol * sw * st * att * 0.28;
        if (shD > 0.03) {
            vec3 pp = vec3(p.x + 0.3 * sin(p.y * 1.7 + flow * 0.4), p.y + flow * 0.35, p.z) * 1.4;
            vec3 cc = floor(pp);
            float hm = hash(vec2(cc.x * 1.7 + mod(cc.z, 97.0) * 13.1, cc.y * 2.3 + mod(cc.z, 97.0) * 7.7));
            if (hm > 0.9) {
                vec3 cen = cc + 0.2 + 0.6 * fract(hm * vec3(37.1, 113.3, 71.9));
                float mote = smoothstep(0.3, 0.0, length(pp - cen))
                           * (0.7 + 0.3 * sin(time * 3.0 + hm * 40.0));
                shaftAcc += moteCol * mote * sw * st * att * 1.6;
            }
        }
        t += st;
        if (t > TMAX) break;
    }
    hitS = hitS && t < TMAX;
    float matH = gMat;

    // ---- colours ----
    vec3 fogCol = mix(bg.rgb * 0.35, pal(0.4) * 0.07, 0.35) * dark + bg.rgb * light;
    fogCol += heartC * dr * dr * 0.22 * dark;               // the afterimage in the dust

    vec3 col = fogCol;
    if (hitS) {
        vec3 p = ro + rd * t;
        vec2 e2 = vec2(1.0, -1.0) * 0.01 * max(t, 0.4);
        vec3 n = normalize(e2.xyy * mapD(p + e2.xyy) + e2.yyx * mapD(p + e2.yyx)
                         + e2.yxy * mapD(p + e2.yxy) + e2.xxx * mapD(p + e2.xxx));
        float ndv = abs(dot(n, -rd));
        float rim = pow(1.0 - ndv, 2.2);
        float fogMul = 1.0;
        vec3 surf;

        if (matH > 2.5) {
            // ---- the heart: dim, veined, stirring; a furnace at the drop ----
            vec3 lp = p - gHeart;
            vec4 hn = vnoise(lp * 2.4 + 3.0);
            vec4 hn2 = vnoise(lp * 6.0 + 8.0);
            vec3 gh = hn.yzw * 1.2 + hn2.yzw * 0.7;
            n = normalize(n - 0.12 * (gh - n * dot(gh, n)));
            float ndh = abs(dot(n, -rd));
            float rimh = pow(1.0 - ndh, 2.0);
            float vein = 1.0 - smoothstep(0.012, 0.05, abs(hn.x - 0.5) / (length(hn.yzw) + 0.25));
            float vein2 = 1.0 - smoothstep(0.01, 0.035, abs(hn2.x - 0.5) / (length(hn2.yzw) + 0.25));
            vein = max(vein, 0.6 * vein2);
            float blaze = dr * dr;
            vec3 hot = mix(heartC, fg.rgb, 0.4);
            vec3 sH = heartC * (0.10 + 0.08 * ndh) * (0.7 + 0.5 * hn.x)
                    + heartC * rimh * (0.30 + 0.7 * hp)
                    + heartC * vein * (0.16 + 1.3 * hp + 0.8 * ant)
                    + hot * blaze * (2.6 + 2.2 * vein + 1.2 * rimh);
            vec3 sLH = mix(bg.rgb, heartC * 0.75, 0.6 + 0.25 * vein + 0.3 * blaze) * (0.65 + 0.35 * ndh);
            surf = mix(sH, sLH, light);
            fogMul = 0.4;
        } else {
            // ---- bone and sand ----
            vec2 spH = spinePath(p.z);
            vec3 q = vec3(p.xy - spH, p.z);
            float lzh = q.z - ribI * RIBZ;
            float hs = hash(vec2(ribI, 1.3));

            // this rib's voice: how far ahead of the camera it stands
            float ahead = clamp((ribI * RIBZ - zc) * 0.035 + 0.1, 0.0, 1.0);
            float e = pow(clamp(band(ahead), 0.0, 1.0), 0.6) * (0.5 + 0.8 * swell);
            // marrow-light seeps up the bone from the spine; starved by the build
            float upBone = clamp((p.y - spH.y) / (RIBR * 1.6), 0.0, 1.0);
            float starve = 1.0 - 0.6 * bd;
            float marrow = (1.0 - upBone * 0.75) * e * starve;
            // the nerve: kick pulses racing rib to rib away down the cage
            float nerve = 0.0;
            for (int j = 0; j < 3; j++) {
                float age = kickAge[j];
                if (age < 2.2) {
                    float front = zc + 1.0 + age * 10.0;         // the pulse's rib position
                    nerve += exp(-pow((ribI * RIBZ - front) / 1.3, 2.0)) * exp(-age * 1.4)
                           * (j == 0 ? kickAge.w : 0.55);
                }
            }
            // the heart silhouettes bones in front of it
            float hd = length(p - gHeart);
            vec3 heartLit = heartC * exp(-hd * 0.3) * heartGlow * (0.4 + 0.6 * rim) * 2.2;

            // ---- surface life: pitting, growth rings, fractures ----
            bool isSand = matH > 1.5;
            vec3 tp = isSand ? vec3(q.x, q.y, mod(q.z, 40.0))
                             : vec3(q.x, q.y, lzh) + vec3(hs * 31.0, hs * 17.0, hs * 23.0);
            float lodK = clamp(1.0 - t * 0.07, 0.0, 1.0);        // fine grain fades with distance
            vec4 n1 = vnoise(tp * 3.0);
            vec4 n2 = vnoise(tp * 8.5 + 11.0);
            vec4 n3 = vnoise(tp * 21.0 + 5.0);
            vec3 g = n1.yzw * 1.5 + n2.yzw * 2.1 + n3.yzw * 2.1 * lodK;
            float ridge = 1.0;
            float cracks = 0.0;
            if (isSand) {
                g *= 0.5;
                float ph = dot(p.xz, vec2(0.9, 0.5)) * 7.0 + n1.x * 3.0;
                g += vec3(0.9, 0.0, 0.5) * cos(ph) * 0.14;       // wind ripples
            } else {
                if (matH < 0.5) {
                    // growth rings: periodic grooves running around the rib
                    vec2 ell = vec2(q.x / XSC, (q.y - RCY) / YSC);
                    float a = atan(ell.x, ell.y);
                    float ph = a * RRAD * 14.0 + n1.x * 2.5;
                    float rr = 0.5 + 0.5 * sin(ph);
                    ridge = rr * rr;
                    float dridge = rr * cos(ph) * 14.0;
                    g += normalize(vec3(XSC * cos(a), -YSC * sin(a), 0.0)) * dridge * 0.5;
                }
                // hairline fractures: thin ridged veins, a second set branching off the first
                vec4 n4 = vnoise(tp * vec3(1.5, 1.5, 2.2) + 3.7);
                vec4 n5 = vnoise(tp * 4.1 + n4.yzw * 0.9 + 9.1);
                float d1 = abs(n4.x - 0.5) / (length(n4.yzw) + 0.25);
                float d2 = abs(n5.x - 0.5) / (length(n5.yzw) + 0.25);
                cracks = max(1.0 - smoothstep(0.008, 0.03, d1),
                             0.65 * (1.0 - smoothstep(0.012, 0.04, d2)));
                cracks *= smoothstep(0.3, 0.7, n2.x) * (1.0 - smoothstep(8.0, 20.0, t));
            }
            float bumpK = 0.11 / (1.0 + t * 0.1);
            n = normalize(n - bumpK * (g - n * dot(g, n)));
            ndv = abs(dot(n, -rd));
            rim = pow(1.0 - ndv, 2.2);

            float ao = mix(0.55, 1.0, smoothstep(0.25, 0.75, n1.x * 0.6 + n2.x * 0.4));
            ao *= mix(0.65, 1.0, ridge) * (1.0 - 0.5 * cracks);

            // bone must READ pale against the dark, even in silence: a visible
            // matte base, cold skylight on the up-faces, and a floor to the marrow
            vec3 boneC = mix(bg.rgb * 0.6, fg.rgb, 0.45) * (0.45 + 0.45 * ndv) * (0.8 + 0.35 * n1.x);
            vec3 sandC = mix(mix(bg.rgb * 0.5, fg.rgb, 0.3), pal(0.3) * 0.5, 0.25) * (0.3 + 0.6 * ndv);
            vec3 baseC = (isSand ? sandC : boneC) * ao;
            float skyAmb = clamp(n.y, 0.0, 1.0) * 0.14 + 0.05;
            vec3 lc = pal(clamp(0.2 + 0.6 * ahead, 0.0, 1.0));
            float marrowF = (0.1 + 0.9 * marrow) * (isSand ? 0.15 : 1.0);
            // the marrow seeps out through the fractures
            float seep = e * starve * (0.55 + 0.45 * (1.0 - upBone));
            vec3 crackGlow = lc * cracks * (0.18 + 2.4 * seep + 2.0 * nerve) * faux(1.0, 0.3)
                           + heartC * ant * 0.35 * cracks;
            // sheets of light falling on the surface
            float shDh;
            float swh = shafts(q, sb, shDh);
            vec3 shLit = shaftCol * swh * (isSand ? 0.8 * clamp(n.y, 0.0, 1.0) : 0.25 * ndv) * faux(1.0, 0.3);

            vec3 sDark = baseC * (0.55 + 0.45 * rim) + fg.rgb * skyAmb * ao
                       + lc * (marrowF * (0.3 + 0.7 * rim) * 0.6 + nerve * (0.4 + 0.8 * rim)) * faux(1.0, 0.3)
                       + crackGlow + shLit + heartLit;
            // museum hall: bone reads as pale form, light as warm tint
            vec3 sLight = mix(bg.rgb, fg.rgb * 0.4, 0.35 + 0.35 * (1.0 - ndv)) * (0.75 + 0.25 * ao);
            sLight = mix(sLight, lc * 0.6, (marrow + nerve) * 0.4);
            sLight = mix(sLight, lc * 0.55, clamp(cracks * (0.4 + e), 0.0, 1.0) * 0.6);
            sLight = mix(sLight, heartC * 0.6, clamp(heartLit, 0.0, 1.0).r * 0.5);
            surf = mix(sDark, sLight, light);
        }

        float fogA = (1.0 - exp(-t * fogK)) * fogMul;
        fogA = fogA * fogA * (3.0 - 2.0 * fogA);
        col = mix(surf, fogCol, fogA);
    }

    col += airGlow * dark;                                   // the dust the heart lit
    col += shaftAcc * dark * faux(1.0, 0.3);                 // cold sheets and the motes in them
    col += pal(0.5) * lit(0.012 + 0.025 * loud + 0.03 * kick) * faux(1.0, 0.4);

    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.28, 0.9, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.9, light), vig * mix(0.5, 0.16, light));
    col = max(col, vec3(0.0));
    col = col / (1.0 + col * 0.12);
    fragColor = vec4(max(col + dither(px), vec3(0.0)), 1.0) * qt_Opacity;
}
