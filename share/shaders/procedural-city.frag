//! name: Night City
//! time: flow
const float THEME_FOLLOW = 0.45;   // 0 = original palette, 1 = fully the Omarchy theme
// Parcel -> mass -> setback -> roof -> facade. Original texture-free city at blue hour.
// 3x3 neighbor checks plus an unvisited-cell distance cap prevent taller remote blocks being skipped.
// Windows are filtered material fields; their emission is illustrative, not global illumination.
// @render time=4.0
// @variant DEBUG_MODE=2
// @variant DEBUG_MODE=3
// @variant DEBUG_MODE=4
// @variant DEBUG_MODE=5
#define DEBUG_MODE 0 // 0 beauty | 2 normals | 3 parcel IDs | 4 steps | 5 window mask

// Library code below is bundled from shader-skills (MIT): https://github.com/gokayfem/shader-skills
// ---- shader-skills library: common ----
const float PI  = 3.14159265358979;

// ---- shader-skills library: hash ----
// PCG-style 1D integer hash.
uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
// 3D integer hash, three decorrelated outputs.
uvec3 pcg3d(uvec3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}
// Map a uint to [0,1) using the top 24 bits, so the result can never round up to 1.0.
float uintToUnit(uint h) { return float(h >> 8u) * (1.0 / 16777216.0); }
vec2 uintToUnit(uvec2 h) { return vec2(h >> 8u) * (1.0 / 16777216.0); }
vec3 uintToUnit(uvec3 h) { return vec3(h >> 8u) * (1.0 / 16777216.0); }
vec4 uintToUnit(uvec4 h) { return vec4(h >> 8u) * (1.0 / 16777216.0); }
// Random float in [0,1) for an integer-valued 2D input.
float hash12(vec2 p) {
    uvec2 q = uvec2(ivec2(floor(p)));
    return uintToUnit(pcgHash(q.x + pcgHash(q.y)));
}
// Random float in [0,1) for an integer-valued 3D input.
float hash13(vec3 p) {
    uvec3 q = uvec3(ivec3(floor(p)));
    return uintToUnit(pcgHash(q.x + pcgHash(q.y + pcgHash(q.z))));
}
// Random vec2 in [0,1)^2 for an integer-valued 2D input.
vec2 hash22(vec2 p) {
    ivec2 q = ivec2(floor(p));
    return uintToUnit(pcg3d(uvec3(q.x, q.y, 0x2545u))).xy;
}
// Random vec3 in [0,1)^3 for an integer-valued 3D input.
vec3 hash33(vec3 p) { return uintToUnit(pcg3d(uvec3(ivec3(floor(p))))); }
// Random vec3 in [0,1)^3 for an integer-valued 2D input.
vec3 hash32(vec2 p) {
    ivec2 q = ivec2(floor(p));
    return uintToUnit(pcg3d(uvec3(q.x, q.y, 0x9E37u)));
}

// ---- shader-skills library: pattern ----
// Box-filtered stripes along x with period 1 and duty cycle 0.5. Returns 0..1.
float filteredStripes(float x, float w) {
    w = max(w, 1e-4);
    float a = x + 0.5 * w, b = x - 0.5 * w;
    float ia = floor(a) * 0.5 + max(fract(a) - 0.5, 0.0);
    float ib = floor(b) * 0.5 + max(fract(b) - 0.5, 0.0);
    return (ia - ib) / w;
}

// ---- shader-skills library: sdf3d ----
// Axis-aligned box with half-extents b.
float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}
// Box with rounded edges. The outer size stays b; r is the edge radius (r <= min(b)).
float sdRoundBox(vec3 p, vec3 b, float r) {
    vec3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}
// Capsule: segment a-b swept by radius r.
float sdCapsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// ---- shader-skills library: sdf2d ----
// Axis-aligned rectangle with half-extents b.
float sdBox(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// ---- shader-skills library: domain ----
// Cell index for repetition with period s (integer-valued; use with hash functions).
float domRepeatId(float p, float s) { return floor(p / s + 0.5); }
vec2 domRepeatId(vec2 p, vec2 s) { return floor(p / s + 0.5); }
vec3 domRepeatId(vec3 p, vec3 s) { return floor(p / s + 0.5); }
// Infinite repetition with period s. Returns the local coordinate centered in its cell. Exact only while each instance stays inside its own cell. For instances that vary per cell or overhang, evaluate the 2 or 3 neighboring cells too (see references/sdf-library-guide.md).
float domRepeat(float p, float s) { return p - s * floor(p / s + 0.5); }
vec2 domRepeat(vec2 p, vec2 s) { return p - s * floor(p / s + 0.5); }
vec3 domRepeat(vec3 p, vec3 s) { return p - s * floor(p / s + 0.5); }

// ---- shader-skills library: architecture ----
// Stable building profile: vec4(height, half-width, half-depth, roof style 0/1/2) from an integer parcel ID. Height and half-width ranges are ordered, positive world-space values. The same ID always gives the same profile.
vec4 buildingProfile(vec2 parcel, vec2 heightRange, vec2 halfWidthRange) {
    vec3 h = hash32(parcel);
    return vec4(mix(heightRange.x,heightRange.y,h.x*h.x),
                mix(halfWidthRange.x,halfWidthRange.y,h.y),
                mix(halfWidthRange.x,halfWidthRange.y,h.z),
                floor(3.0*hash12(parcel+vec2(83.0,19.0))));
}
// Box-filtered rectangular windows centered on integer facade coordinates. fill is the opening fraction per cell in [0,1]; footprint is the pixel's width/height in cell units. At large footprints it converges to fill.x*fill.y.
float facadeWindowMask(vec2 uv, vec2 fill, vec2 footprint) {
    fill = clamp(fill,0.0,1.0);
    vec2 w = max(footprint,vec2(0.0001));
    vec2 a = uv + 0.5*fill + 0.5*w;
    vec2 b = uv + 0.5*fill - 0.5*w;
    vec2 ia = floor(a)*fill + min(fract(a),fill);
    vec2 ib = floor(b)*fill + min(fract(b),fill);
    vec2 coverage = clamp((ia-ib)/w,0.0,1.0);
    return coverage.x*coverage.y;
}

// ---- shader-skills library: raymarch ----
#define ZERO (min(iFrame, 0))
vec2 map(vec3 p);
const int RAYMARCH_MAX_STEPS = 256;
// Sphere-trace from ro along unit rd between tmin and tmax. Returns vec3(t, materialId, stepCount). t is -1 on a miss. The hit threshold grows with t (about one pixel's footprint), so distant surfaces don't burn steps. stepScale is 1 for exact or bound fields. Use < 1 (e.g. 0.6) when map() has Lipschitz > 1 (displacement, warps, twist).
vec3 raymarch(vec3 ro, vec3 rd, float tmin, float tmax, float stepScale) {
    float t = tmin;
    for (int i = ZERO; i < RAYMARCH_MAX_STEPS; i++) {
        vec2 h = map(ro + rd * t);
        if (abs(h.x) < max(0.0002 * t, 1e-5)) return vec3(t, h.y, float(i));
        t += h.x * stepScale;
        if (t > tmax) break;
    }
    return vec3(-1.0, -1.0, float(RAYMARCH_MAX_STEPS));
}
// Surface normal from 4 tetrahedral samples (cheaper than 6 central differences, and still centered). eps should scale with distance, e.g. 0.0005 * t: that filters distant detail and avoids sparkling.
vec3 calcNormal(vec3 p, float eps) {
    vec3 n = vec3(0.0);
    for (int i = ZERO; i < 4; i++) {
        vec3 e = 0.5773 * (2.0 * vec3((((i + 3) >> 1) & 1), ((i >> 1) & 1), (i & 1)) - 1.0);
        n += e * map(p + e * eps).x;
    }
    return normalize(n);
}
// Soft shadow toward a light along unit rd. k controls sharpness (k is about 1 / light angular size: 8 soft, 32 hard). Uses the "closest approach between samples" estimate, which removes banding from sharp-cornered occluders. Returns 0 (full shadow) .. 1 (lit).
float softShadow(vec3 ro, vec3 rd, float tmin, float tmax, float k) {
    float res = 1.0;
    float t = tmin;
    float ph = 1e10;
    for (int i = ZERO; i < 64; i++) {
        float h = map(ro + rd * t).x;
        if (h < 0.0001) return 0.0;
        float y = h * h / (2.0 * ph);
        float d = sqrt(max(h * h - y * y, 0.0));
        res = min(res, k * d / max(t - y, 1e-4));
        ph = h;
        t += clamp(h, 0.005, 0.5);
        if (res < 0.001 || t > tmax) break;
    }
    res = clamp(res, 0.0, 1.0);
    return res * res * (3.0 - 2.0 * res);
}
// Ambient occlusion from 5 distance samples along the normal. Compares the expected distance with the actual one. scale is the sampling reach in scene units (about 0.12 for a unit-sized object). Returns 0 (occluded) .. 1 (open).
float calcAO(vec3 p, vec3 n, float scale) {
    float occ = 0.0;
    float weight = 1.0;
    for (int i = ZERO; i < 5; i++) {
        float h = 0.01 + scale * float(i) / 4.0;
        float d = map(p + h * n).x;
        occ += (h - d) * weight;
        weight *= 0.95;
    }
    return clamp(1.0 - 3.0 * occ / max(scale / 0.12, 1e-3), 0.0, 1.0);
}

// ---- shader-skills library: camera ----
// Camera-to-world matrix looking from ro toward ta, with roll in radians. Columns are (right, up, forward).
mat3 cameraMatrix(vec3 ro, vec3 ta, float roll) {
    vec3 w = normalize(ta - ro);
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 u = normalize(cross(w, up));
    vec3 v = cross(u, w);
    return mat3(u, v, w);
}
// Primary ray direction for screen point uv. focal is about 1.5-2.5 for natural framing (see fovToFocal).
vec3 cameraRay(mat3 cam, vec2 uv, float focal) {
    return normalize(cam * vec3(uv, focal));
}

// ---- shader-skills library: shading ----
// Schlick Fresnel. u is VoH for lights and NoV for environment reflections and rims. f0 = 0.04 for dielectrics (plastic, skin, stone, water ~0.02); for metals f0 = base color.
vec3 fresnelSchlick(float u, vec3 f0) {
    float m = clamp(1.0 - u, 0.0, 1.0);
    float m2 = m * m;
    return f0 + (1.0 - f0) * (m2 * m2 * m);
}
// GGX / Trowbridge-Reitz normal distribution. alpha = roughness^2.
float distributionGGX(float NoH, float alpha) {
    float a2 = alpha * alpha;
    float d = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}
// Height-correlated Smith visibility. Already contains the 1 / (4 NoL NoV) term.
float visibilitySmithGGX(float NoV, float NoL, float alpha) {
    float a2 = alpha * alpha;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-6);
}
// Microfacet specular for one light: pi * D * V * F * NoL (artist units). roughness is perceptual, in [0,1].
vec3 specularGGX(vec3 n, vec3 v, vec3 l, float roughness, vec3 f0) {
    vec3 h = normalize(v + l);
    float NoL = clamp(dot(n, l), 0.0, 1.0);
    float NoV = max(dot(n, v), 1e-4);
    float NoH = clamp(dot(n, h), 0.0, 1.0);
    float VoH = clamp(dot(v, h), 0.0, 1.0);
    float alpha = max(roughness, 0.045);
    alpha *= alpha;
    return PI * distributionGGX(NoH, alpha) * visibilitySmithGGX(NoV, NoL, alpha) * fresnelSchlick(VoH, f0) * NoL;
}
// Complete metallic-roughness shading for one light (diffuse + specular, NoL included, artist units). Multiply by light color and shadow. Keep albedo around 0.05-0.7 (linear); brighten lights, not albedo.
vec3 shadePBR(vec3 n, vec3 v, vec3 l, vec3 albedo, float roughness, float metallic) {
    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    float NoL = clamp(dot(n, l), 0.0, 1.0);
    vec3 F = fresnelSchlick(max(dot(n, v), 0.0), f0);
    vec3 diffuse = albedo * (1.0 - metallic) * (1.0 - F) * NoL;
    return diffuse + specularGGX(n, v, l, roughness, f0);
}
// Hemisphere light: sky color from above blended to ground color from below.
vec3 hemisphereLight(vec3 n, vec3 skyColor, vec3 groundColor) {
    return mix(groundColor, skyColor, 0.5 + 0.5 * n.y);
}

// ---- shader-skills library: color ----
// Exact sRGB encode (OETF): linear -> display [0,1]. Apply exactly once, after tonemapping. pow(c, 1/2.2) is visibly wrong near black (0.001 encodes to 0.013 here vs 0.043 with 2.2).
vec3 linearToSrgb(vec3 c) {
    c = max(c, 0.0);
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// ---- shader-skills library: tonemap ----
// AgX: log encoding plus a sigmoid inside an inset/outset gamut. Mid-grey 0.18 maps to about 0.5 display. Minimal implementation after Troy Sobotka's AgX and Benjamin Wrensch's polynomial fit (both MIT).
vec3 tonemapAgX(vec3 c) {
    const mat3 inset = mat3(0.842479062253094, 0.0423282422610123, 0.0423756549057051,
                            0.0784335999999992, 0.878468636469772, 0.0784336,
                            0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    const mat3 outset = mat3(1.19687900512017, -0.0528968517574562, -0.0529716355144438,
                             -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
                             -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    const float minEv = -12.47393, maxEv = 4.026069;
    c = inset * max(c, 0.0);
    c = clamp((log2(max(c, 1e-10)) - minEv) / (maxEv - minEv), 0.0, 1.0);
    vec3 x2 = c * c, x4 = x2 * x2;
    c = 15.5 * x4 * x2 - 40.14 * x4 * c + 31.96 * x4 - 6.868 * x2 * c + 0.4298 * x2 + 0.1191 * c - 0.00232;
    c = outset * c;
    return pow(max(c, 0.0), vec3(2.2));
}

// ---- shader-skills library: volume ----
// Analytic height fog for density a * exp(-b * y) along the ray segment [0, t]. Thick near the ground, thin above. Returns the fog amount in [0,1].
float heightFog(vec3 ro, vec3 rd, float t, float a, float b) {
    float base = a * exp(-ro.y * b);
    float amount = (abs(rd.y) < 1e-4) ? base * t
                                       : base * (1.0 - exp(-t * rd.y * b)) / (rd.y * b);
    return 1.0 - exp(-max(amount, 0.0));
}

// ---- shader-skills library: post ----
// Subpixel offset in [-0.5, 0.5)^2 for sample i of a supersampling loop (R2 low-discrepancy sequence). Better coverage than a regular grid for any sample count.
vec2 aaOffset(int i) {
    return fract(0.5 + float(i) * vec2(0.7548776662, 0.5698402910)) - 0.5;
}
// Triangular-PDF dither of +-1 LSB for 8-bit output. Add AFTER linearToSrgb, right before writing fragColor.
vec3 ditherTPDF(vec2 fragCoord, int frame) {
    vec2 r = hash22(vec2(floor(fragCoord) + 7919.0 * float(frame % 1024)));
    return vec3((r.x + r.y - 1.0) / 255.0);
}

// ---- shader-skills library: debug ----
// Heat ramp for a value in [0,1]: black, blue, magenta, orange, yellow, white.
vec3 debugHeat(float t) {
    t = clamp(t, 0.0, 1.0);
    return clamp(vec3(1.5 * t, 1.6 * t * t * t - 0.1, 0.9 * sin(PI * t) + 0.2 * t * t), 0.0, 1.0);
}

// ---- shader ----
const float PARCEL = 3.6;
const vec3 CITY_SUN = normalize(vec3(-0.6,0.6,0.4));
const int AA = 1; // set 4 for stills

vec4 cityProfile(vec2 id) {
    vec4 b = buildingProfile(id,vec2(2.8,13.0),vec2(0.75,1.13));
    if (length(id)<0.5) b=vec4(18.0,1.15,1.15,2.0);
    return b;
}

vec2 map(vec3 p) {
    vec2 id=domRepeatId(p.xz,vec2(PARCEL));
    vec2 local=p.xz-id*PARCEL;
    vec2 res=vec2(p.y,0.0);
    for(int z=-1;z<=1;z++) for(int x=-1;x<=1;x++) {
        vec2 cell=id+vec2(float(x),float(z));
        vec4 b=cityProfile(cell);
        vec3 q=p-vec3(cell.x*PARCEL,0.0,cell.y*PARCEL);
        float body=sdRoundBox(q-vec3(0.0,b.x*0.38,0.0),vec3(b.y,b.x*0.38,b.z)-0.035,0.035);
        float upper=sdRoundBox(q-vec3(0.0,b.x*0.83,0.0),vec3(b.y*0.72,b.x*0.17,b.z*0.72)-0.025,0.025);
        float podium=sdBox(q-vec3(0.0,0.35,0.0),vec3(b.y+0.15,0.35,b.z+0.15));
        float d=min(podium,min(body,upper));
        if(b.w>0.5) d=min(d,sdBox(q-vec3(0.0,b.x+0.22,0.0),vec3(b.y*0.45,0.22,b.z*0.5)));
        if(b.w>1.5) d=min(d,sdCapsule(q,vec3(0.0,b.x,0.0),vec3(0.0,b.x+1.1,0.0),0.035));
        if(d<res.x)res=vec2(d,1.0);
    }
    float unvisited=min(1.5*PARCEL-abs(local.x),1.5*PARCEL-abs(local.y));
    res.x=min(res.x,unvisited);
    return res;
}

vec3 citySky(vec3 rd) {
    float h=smoothstep(-0.12,0.7,rd.y);
    vec3 c=mix(vec3(0.10,0.12,0.19),vec3(0.012,0.028,0.07),h);
    c+=vec3(0.12,0.055,0.025)*pow(max(dot(rd,CITY_SUN),0.0),12.0);
    return c;
}

vec3 renderCity(vec2 coord) {
    vec2 uv=(2.0*coord-iResolution.xy)/iResolution.y;
    float orbit=0.5+0.035*iTime;
    vec3 ro=vec3(32.0*sin(orbit),17.0,32.0*cos(orbit));
    vec3 rd=cameraRay(cameraMatrix(ro,vec3(0.0,6.0,0.0),0.0),uv,1.85);
    vec3 sky=citySky(rd);
    vec3 hit=raymarch(ro,rd,0.05,110.0,0.95);
#if DEBUG_MODE == 4
    return debugHeat(hit.z/256.0);
#endif
    if(hit.x<0.0)return sky;
    vec3 p=ro+rd*hit.x;
    vec3 n=calcNormal(p,max(0.001,hit.x*0.00015));
    vec2 id=domRepeatId(p.xz,vec2(PARCEL));
    vec4 b=cityProfile(id);
    float variation=hash12(id);
    float fp=2.0*hit.x/(iResolution.y*1.85);
    fp/=max(abs(dot(n,rd)),0.15);
    vec3 albedo=mix(vec3(0.16,0.19,0.21),vec3(0.32,0.29,0.25),variation);
    float windows=0.0;
    vec3 emission=vec3(0.0);
    if(hit.y>0.5 && n.y<0.6) {
        vec2 facade=vec2(abs(n.x)>abs(n.z)?p.z:p.x,p.y);
        vec2 grid=facade/vec2(0.30,0.43);
        windows=facadeWindowMask(grid,vec2(0.62,0.65),vec2(fp*3.8,fp*2.5));
        float occupied=step(0.42,hash13(vec3(floor(grid+0.5),variation*100.0)));
        float keep=1.0-smoothstep(0.3,1.2,fp/0.30);
        occupied=mix(0.58,occupied,keep);
        vec3 glass=vec3(0.018,0.035,0.055)+citySky(reflect(rd,n))*0.3;
        albedo=mix(albedo,glass,windows);
        float flicker=step(0.55,hash13(vec3(floor(grid+0.5),kicks)));
        emission=windows*occupied*mix(vec3(0.6,0.22,0.055),vec3(1.2,0.74,0.33),variation)
                *(0.55+0.35*swell+0.9*kick*flicker+0.5*drop);
    } else if(hit.y<0.5) {
        albedo=vec3(0.045,0.05,0.06);
        vec2 streets=abs(domRepeat(p.xz,vec2(PARCEL)));
        float marking=(1.0-smoothstep(0.025,0.025+fp,abs(streets.x-PARCEL*0.5)))
                     *filteredStripes(p.z*1.3,fp*1.3);
        albedo=mix(albedo,vec3(0.42,0.32,0.13),marking);
    }
    float ao=calcAO(p,n,0.18);
    float shadow=softShadow(p+n*0.015,CITY_SUN,0.02,20.0,10.0);
    vec3 col=shadePBR(n,-rd,CITY_SUN,albedo,0.4,0.15)*vec3(0.9,0.75,0.6)*shadow;
    col+=albedo*hemisphereLight(n,vec3(0.30,0.43,0.66),vec3(0.07,0.065,0.055))*ao;
    col+=emission;
#if DEBUG_MODE == 2
    return n*0.5+0.5;
#elif DEBUG_MODE == 3
    return hash33(vec3(id,0.0));
#elif DEBUG_MODE == 5
    return vec3(windows);
#endif
    float haze=heightFog(ro,rd,hit.x,0.006,0.055);
    return mix(col,citySky(normalize(vec3(rd.x,0.06,rd.z))),haze);
}

void mainImage(out vec4 fragColor,in vec2 fragCoord) {
    vec3 col=vec3(0.0);
    for(int i=0;i<AA;i++) {
        vec3 sampleColor=renderCity(fragCoord+(AA>1?aaOffset(i):vec2(0.0)));
#if DEBUG_MODE == 0
        sampleColor=tonemapAgX(sampleColor*1.05*(1.0+0.12*swell+0.30*drop-0.10*build));
#endif
        col+=sampleColor/float(AA);
    }
#if DEBUG_MODE == 0
    col=linearToSrgb(col);
    // Omarchy theme grade: keep the image's light, lean its color to the
    // theme (pal() is the active theme's c1->c2->c3 ramp). Light themes
    // keep more of the original so daylight scenes stay daylight.
    float themeL = clamp(dot(col, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    col = mix(col, pal(themeL) * (0.15 + 1.10 * themeL), THEME_FOLLOW * (1.0 - 0.6 * light));
    col += ditherTPDF(fragCoord,iFrame);
#endif
    fragColor=vec4(col,1.0);
}
