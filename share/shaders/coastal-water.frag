//! name: Coastal Water
//! time: flow
const float THEME_FOLLOW = 0.40;   // 0 = original palette, 1 = fully the Omarchy theme
// Coastal water: analytic finite-depth waves, refracted seabed, reflected land, exact interface Fresnel,
// RGB Beer-Lambert attenuation, scattered-light approximation, shore/crest foam, GGX glints and filtered ripples.
// Single-pass visual study, not fluid simulation: caustics are artistic; reflected waves/multiple scattering are omitted.
// @render time=5.0
// @variant QUALITY=1
// @variant QUALITY=3
// @variant DEBUG_MODE=1
// @variant DEBUG_MODE=2
// @variant DEBUG_MODE=3
// @variant DEBUG_MODE=4
// @variant DEBUG_MODE=5
// @variant DEBUG_MODE=6
#define QUALITY 2 // 1 interactive: sky reflection | 2 high: land reflection | 3 still: 4x AA, more waves/steps
#define DEBUG_MODE 0 // 0 beauty | 1 optical path | 2 normals | 3 foam | 4 primary steps | 5 Fresnel | 6 transmission

// Library code below is bundled from shader-skills (MIT): https://github.com/gokayfem/shader-skills
// ---- shader-skills library: common ----
const float PI  = 3.14159265358979;
const float TAU = 6.28318530717959;

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
// Random vec2 in [0,1)^2 for an integer-valued 2D input.
vec2 hash22(vec2 p) {
    ivec2 q = ivec2(floor(p));
    return uintToUnit(pcg3d(uvec3(q.x, q.y, 0x2545u))).xy;
}
// Random vec3 in [0,1)^3 for an integer-valued 3D input.
vec3 hash33(vec3 p) { return uintToUnit(pcg3d(uvec3(ivec3(floor(p))))); }

// ---- shader-skills library: noise ----
// Quintic fade 6t^5 - 15t^4 + 10t^3: C2-continuous interpolation weights for lattice noise.
vec2 quinticFade(vec2 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
vec3 quinticFade(vec3 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
// Derivative of quinticFade: 30 t^2 (t - 1)^2.
vec2 quinticFadeDeriv(vec2 f) { return 30.0 * f * f * (f * (f - 2.0) + 1.0); }
vec3 quinticFadeDeriv(vec3 f) { return 30.0 * f * f * (f * (f - 2.0) + 1.0); }
// Unit gradient for a 2D lattice point.
vec2 latticeGradient(vec2 cell) {
    float a = TAU * hash12(cell);
    return vec2(cos(a), sin(a));
}
// 2D gradient (Perlin-style) noise with analytic derivatives. Returns vec3(value, d/dx, d/dy). Gradient noise has less grid-aligned blockiness than value noise. Prefer it for fBm.
vec3 gradientNoiseD(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = quinticFade(f), du = quinticFadeDeriv(f);
    vec2 ga = latticeGradient(i);
    vec2 gb = latticeGradient(i + vec2(1.0, 0.0));
    vec2 gc = latticeGradient(i + vec2(0.0, 1.0));
    vec2 gd = latticeGradient(i + vec2(1.0, 1.0));
    float va = dot(ga, f);
    float vb = dot(gb, f - vec2(1.0, 0.0));
    float vc = dot(gc, f - vec2(0.0, 1.0));
    float vd = dot(gd, f - vec2(1.0, 1.0));
    float k = va - vb - vc + vd;
    float value = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    vec2 deriv = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
               + du * (vec2(vb - va, vc - va) + u.yx * k);
    return vec3(value, deriv);
}
// 2D gradient noise.
float gradientNoise(vec2 p) { return gradientNoiseD(p).x; }
// Dot product of a hashed 3D gradient with the offset to its lattice corner.
float latticeGradDot(vec3 cell, vec3 corner, vec3 f) {
    vec3 g = hash33(cell + corner) * 2.0 - 1.0;
    return dot(g, f - corner);
}
// 3D gradient noise.
float gradientNoise(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    vec3 u = quinticFade(f);
    return mix(mix(mix(latticeGradDot(i, vec3(0, 0, 0), f), latticeGradDot(i, vec3(1, 0, 0), f), u.x),
                   mix(latticeGradDot(i, vec3(0, 1, 0), f), latticeGradDot(i, vec3(1, 1, 0), f), u.x), u.y),
               mix(mix(latticeGradDot(i, vec3(0, 0, 1), f), latticeGradDot(i, vec3(1, 0, 1), f), u.x),
                   mix(latticeGradDot(i, vec3(0, 1, 1), f), latticeGradDot(i, vec3(1, 1, 1), f), u.x), u.y), u.z);
}
// 3D gradient noise with analytic derivatives. Returns vec4(value, d/dx, d/dy, d/dz); value equals gradientNoise(p). The trilinear blend is expanded as a polynomial in the fade weights, so the gradient is the same blend of the corner gradients plus the chain-rule term of the fade.
vec4 gradientNoiseD(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    vec3 u = quinticFade(f), du = quinticFadeDeriv(f);
    vec3 g000 = hash33(i) * 2.0 - 1.0;
    vec3 g100 = hash33(i + vec3(1, 0, 0)) * 2.0 - 1.0;
    vec3 g010 = hash33(i + vec3(0, 1, 0)) * 2.0 - 1.0;
    vec3 g110 = hash33(i + vec3(1, 1, 0)) * 2.0 - 1.0;
    vec3 g001 = hash33(i + vec3(0, 0, 1)) * 2.0 - 1.0;
    vec3 g101 = hash33(i + vec3(1, 0, 1)) * 2.0 - 1.0;
    vec3 g011 = hash33(i + vec3(0, 1, 1)) * 2.0 - 1.0;
    vec3 g111 = hash33(i + vec3(1, 1, 1)) * 2.0 - 1.0;
    float v000 = dot(g000, f);
    float v100 = dot(g100, f - vec3(1, 0, 0));
    float v010 = dot(g010, f - vec3(0, 1, 0));
    float v110 = dot(g110, f - vec3(1, 1, 0));
    float v001 = dot(g001, f - vec3(0, 0, 1));
    float v101 = dot(g101, f - vec3(1, 0, 1));
    float v011 = dot(g011, f - vec3(0, 1, 1));
    float v111 = dot(g111, f - vec3(1, 1, 1));
    // value = v000 + kx u.x + ky u.y + kz u.z + kxy u.x u.y + kyz u.y u.z + kzx u.z u.x + kxyz u.x u.y u.z
    float kx = v100 - v000, ky = v010 - v000, kz = v001 - v000;
    float kxy = v000 - v100 - v010 + v110;
    float kyz = v000 - v010 - v001 + v011;
    float kzx = v000 - v100 - v001 + v101;
    float kxyz = -v000 + v100 + v010 - v110 + v001 - v101 - v011 + v111;
    float value = v000 + kx * u.x + ky * u.y + kz * u.z
                + kxy * u.x * u.y + kyz * u.y * u.z + kzx * u.z * u.x + kxyz * u.x * u.y * u.z;
    vec3 grad = g000 + (g100 - g000) * u.x + (g010 - g000) * u.y + (g001 - g000) * u.z
              + (g000 - g100 - g010 + g110) * u.x * u.y
              + (g000 - g010 - g001 + g011) * u.y * u.z
              + (g000 - g100 - g001 + g101) * u.z * u.x
              + (-g000 + g100 + g010 - g110 + g001 - g101 - g011 + g111) * u.x * u.y * u.z
              + du * vec3(kx + kxy * u.y + kzx * u.z + kxyz * u.y * u.z,
                          ky + kxy * u.x + kyz * u.z + kxyz * u.x * u.z,
                          kz + kyz * u.y + kzx * u.x + kxyz * u.x * u.y);
    return vec4(value, grad);
}
const int FBM_MAX_OCTAVES = 12;
// Fractional Brownian motion over 2D gradient noise. Each octave is rotated to hide lattice alignment. persistence 0.5 is the classic look (H = 1). Lower is smoother, higher is rougher.
float fbm(vec2 p, int octaves, float lacunarity, float persistence) {
    const mat2 octaveRotation = mat2(0.8, 0.6, -0.6, 0.8);
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (int i = 0; i < FBM_MAX_OCTAVES; i++) {
        if (i >= octaves) break;
        sum += amp * gradientNoise(p);
        norm += amp;
        amp *= persistence;
        p = lacunarity * (octaveRotation * p) + vec2(17.13, -3.71);
    }
    return 1.4 * sum / norm;
}
// 2D fBm with the usual defaults (lacunarity 2.01 so octave peaks never re-align, persistence 0.5).
float fbm(vec2 p, int octaves) { return fbm(p, octaves, 2.01, 0.5); }
// fBm over 3D gradient noise.
float fbm(vec3 p, int octaves, float lacunarity, float persistence) {
    const mat3 octaveRotation = mat3(0.00, 0.80, 0.60,
                                     -0.80, 0.36, -0.48,
                                     -0.60, -0.48, 0.64);
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (int i = 0; i < FBM_MAX_OCTAVES; i++) {
        if (i >= octaves) break;
        sum += amp * gradientNoise(p);
        norm += amp;
        amp *= persistence;
        p = lacunarity * (octaveRotation * p) + vec3(17.13, -3.71, 5.29);
    }
    return sum / norm;
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
// Hemisphere light: sky color from above blended to ground color from below.
vec3 hemisphereLight(vec3 n, vec3 skyColor, vec3 groundColor) {
    return mix(groundColor, skyColor, 0.5 + 0.5 * n.y);
}

// ---- shader-skills library: water ----
// Angular frequency sqrt(g*k*tanh(k*depth)) for finite-depth gravity waves. Nonpositive inputs are clamped.
float waterDispersion(float k, float depth, float gravity) {
    k = max(k,0.0);
    float e = exp(-2.0*k*max(depth,0.0));
    return sqrt(max(gravity,0.0)*k*(1.0-e)/(1.0+e));
}
// One sinusoidal wave: vec4(height, dh/dx, dh/dz, Laplacian). Direction is normalized internally; zero uses +X. wavelength > 0, amplitude in meters. footprint filters waves below 2-6 pixels; derivatives hold it constant.
vec4 waterWaveD(vec2 xz, float time, vec2 direction, float wavelength, float amplitude, float depth, float footprint) {
    float dl = length(direction);
    vec2 dir = dl>0.000001 ? direction/dl : vec2(1.0,0.0);
    float lengthM = max(wavelength,0.0001);
    float k = TAU/lengthM;
    float keep = smoothstep(2.0,6.0,lengthM/max(footprint,0.000001));
    float phase = k*dot(dir,xz)-waterDispersion(k,depth,9.81)*time;
    float h = amplitude*keep*sin(phase);
    return vec4(h, amplitude*keep*k*cos(phase)*dir, -k*k*h);
}
// Exact unpolarized dielectric Fresnel for a positive incident cosine and positive refractive indices. Returns 1 for total internal reflection. Caller chooses etaIncident/etaTransmitted for the ray's side.
float fresnelDielectric(float cosIncident, float etaIncident, float etaTransmitted) {
    float ci = clamp(abs(cosIncident),0.0,1.0);
    float ei = max(etaIncident,0.000001), et = max(etaTransmitted,0.000001);
    if (abs(ei-et)<0.0000001) return 0.0;
    float sinT2 = (ei*ei)/(et*et)*max(0.0,1.0-ci*ci);
    if (sinT2>=1.0) return 1.0;
    float ct = sqrt(max(0.0,1.0-sinT2));
    float rs = (ei*ci-et*ct)/max(ei*ci+et*ct,0.000001);
    float rp = (et*ci-ei*ct)/max(et*ci+ei*ct,0.000001);
    return clamp(0.5*(rs*rs+rp*rp),0.0,1.0);
}
// Beer-Lambert RGB transmittance exp(-extinction*pathLength). Negative extinction/path is clamped to zero. Use the refracted optical path, not vertical water depth. Attenuation alone does not add scattered light.
vec3 beerTransmittance(vec3 extinction, float pathLength) {
    return exp(-max(extinction,vec3(0.0))*max(pathLength,0.0));
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

// ---- shader-skills library: atmosphere ----
// Sun disk with antialiased edge and limb darkening (Neckel 1996). angularRadius in radians (the real sun is 0.00476; art often uses 3-10x). pixelAngle is the angular size of a pixel (about 2 / (iResolution.y * focal)). Returns a 0..1 shape tinted by limb darkening; multiply by a bright sun color (10-50).
vec3 sunDisk(vec3 rd, vec3 sunDir, float angularRadius, float pixelAngle) {
    float ang = acos(clamp(dot(rd, sunDir), -1.0, 1.0));
    float edge = 1.0 - smoothstep(angularRadius - pixelAngle, angularRadius + pixelAngle, ang);
    float r = clamp(ang / angularRadius, 0.0, 1.0);
    float muLimb = sqrt(max(1.0 - r * r, 0.0));
    vec3 limb = pow(vec3(muLimb), vec3(0.397, 0.503, 0.652));
    return edge * limb;
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
const int WATER_AA=QUALITY==3?4:1;
const int WATER_WAVES=QUALITY==3?12:8;
const int WATER_STEPS=QUALITY==3?240:180;
const vec3 COAST_SUN=normalize(vec3(-0.35,0.62,-0.55));
const vec3 EXTINCTION=vec3(0.42,0.085,0.045); // illustrative clear turquoise water, 1/m
const float WATER_IOR=1.333;
const float WATER_FAR=95.0;

float coastBed(vec2 p) {
    vec2 a=p-vec2(-7.0,-8.0),b=p-vec2(7.0,-19.0),c=p-vec2(-5.0,-1.0);
    float islands=5.7*exp(-0.055*dot(a,a))+5.0*exp(-0.07*dot(b,b))+1.1*exp(-0.15*dot(c,c));
    return -2.4+islands*(1.0+0.18*gradientNoise(p*0.75))+0.12*sin(p.x*1.7)*sin(p.y*1.2);
}

vec3 coastBedNormal(vec2 p,float eps) {
    vec2 d=vec2(coastBed(p+vec2(eps,0.0))-coastBed(p-vec2(eps,0.0)),
                coastBed(p+vec2(0.0,eps))-coastBed(p-vec2(0.0,eps)))/(2.0*eps);
    return normalize(vec3(-d.x,1.0,-d.y));
}

vec4 coastWaves(vec2 p,float footprint) {
    vec4 sum=vec4(0.0);
    for(int i=0;i<WATER_WAVES;i++) {
        float fi=float(i);
        float angle=0.7+fi*2.39996;
        float wavelength=4.5*pow(0.69,fi);
        float amp=0.075*(0.72+0.42*swell+0.30*bass)*pow(0.58,fi);
        // Fixed reference depth in phase avoids spatially varying frequency drifting out of phase along the shore.
        sum+=waterWaveD(p+vec2(fi*1.37,fi*0.79),iTime,vec2(cos(angle),sin(angle)),wavelength,amp,3.0,footprint);
    }
    return sum;
}

vec2 traceCoast(vec3 ro,vec3 rd,bool includeWater,int maxSteps) {
    float t=0.01,previous=0.0;
    float closing=max(0.05,abs(rd.y)+4.0*length(rd.xz));
    for(int i=0;i<WATER_STEPS;i++) {
        if(i>=maxSteps)break;
        vec3 p=ro+rd*t;
        float h=coastBed(p.xz);
        if(includeWater) {
            float geometryFootprint=2.0*t/(iResolution.y*1.75*max(abs(rd.y),0.1));
            h=max(h,coastWaves(p.xz,geometryFootprint).x);
        }
        float gap=p.y-h;
        if(gap<0.0) {
            float lo=previous,hi=t;
            for(int j=0;j<10;j++) {
                float mid=0.5*(lo+hi);
                vec3 q=ro+rd*mid;
                float surface=coastBed(q.xz);
                if(includeWater) {
                    float fp=2.0*mid/(iResolution.y*1.75*max(abs(rd.y),0.1));
                    surface=max(surface,coastWaves(q.xz,fp).x);
                }
                if(q.y>surface)lo=mid;else hi=mid;
            }
            return vec2(0.5*(lo+hi),float(i));
        }
        previous=t;
        t+=max(gap/closing,0.012+0.008*t);
        if(t>WATER_FAR)break;
    }
    if(includeWater && rd.y < -0.0001) return vec2(max(0.01,-ro.y/rd.y),float(maxSteps));
    return vec2(-1.0,float(maxSteps));
}

vec3 coastSky(vec3 rd) {
    vec3 c=mix(vec3(0.22,0.40,0.60),vec3(0.025,0.13,0.36),sqrt(max(rd.y,0.0)));
    float clouds=smoothstep(0.1,0.55,fbm(rd.xz/max(rd.y+0.4,0.15)*1.3,4));
    c=mix(c,vec3(0.95,0.97,1.0),clouds*0.18*smoothstep(0.03,0.3,rd.y));
    return c+vec3(9.0,8.0,6.0)*sunDisk(rd,COAST_SUN,0.012,0.002);
}

vec3 shadeCoastBed(vec3 p,vec3 n,bool submerged,float footprint) {
    float grain=0.5+0.5*fbm(p.xz*2.5,4)*(1.0-smoothstep(0.03,0.25,footprint));
    float rock=smoothstep(0.45,1.0,p.y)*(1.0-smoothstep(0.65,0.9,n.y));
    vec3 sand=mix(vec3(0.38,0.29,0.15),vec3(0.7,0.59,0.37),grain);
    vec3 albedo=mix(sand,vec3(0.17,0.15,0.12),rock);
    float vegetation=smoothstep(1.2,2.0,p.y)*smoothstep(0.5,0.82,n.y);
    albedo=mix(albedo,vec3(0.07,0.12,0.025),vegetation);
    vec3 direct=vec3(2.5,2.3,1.9)*max(dot(n,COAST_SUN),0.0);
    if(submerged) {
        direct*=beerTransmittance(EXTINCTION,max(-p.y,0.0)/COAST_SUN.y);
        float caustic=pow(max(0.0,sin(p.x*7.0+sin(p.z*4.0+iTime)*1.3)*sin(p.z*6.0+cos(p.x*4.0-iTime)*1.2)),9.0);
        float keep=1.0-smoothstep(0.02,0.12,footprint);
        direct*=1.0+caustic*keep*1.2; // projected artistic caustic pattern, not photon transport
    }
    return albedo*(direct+hemisphereLight(n,vec3(0.35,0.43,0.5),vec3(0.12,0.10,0.07)));
}

vec3 renderCoast(vec2 coord) {
    vec2 uv=(2.0*coord-iResolution.xy)/iResolution.y;
    vec3 ro=vec3(0.0,3.5,7.5);
    vec3 rd=cameraRay(cameraMatrix(ro,vec3(-0.8,-0.1,-6.0),0.0),uv,1.75);
    vec3 sky=coastSky(rd);
    vec2 hit=traceCoast(ro,rd,true,WATER_STEPS);
#if DEBUG_MODE == 4
    return debugHeat(hit.y/float(WATER_STEPS));
#endif
    if(hit.x<0.0)return sky;
    vec3 p=ro+rd*hit.x;
    float footprint=2.0*hit.x/(iResolution.y*1.75);
    float bed=coastBed(p.xz);
    vec3 col;
    if(bed>p.y-0.015) {
        vec3 n=coastBedNormal(p.xz,max(footprint,0.003));
        col=shadeCoastBed(p,n,false,footprint);
    } else {
        vec4 waves=coastWaves(p.xz,footprint/max(abs(rd.y),0.1));
        vec3 n=normalize(vec3(-waves.y,1.0,-waves.z));
        vec3 v=-rd;
        float F=fresnelDielectric(max(dot(n,v),0.0),1.0,WATER_IOR);
        vec3 refracted=refract(rd,n,1.0/WATER_IOR);
        vec2 bottomHit=traceCoast(p-n*0.006,refracted,false,WATER_STEPS);
        float path=bottomHit.x>0.0?bottomHit.x:30.0;
        vec3 bottomPoint=p-n*0.006+refracted*path;
        vec3 bottomColor=shadeCoastBed(bottomPoint,coastBedNormal(bottomPoint.xz,0.01),true,footprint);
        vec3 T=beerTransmittance(EXTINCTION,path);
        vec3 body=bottomColor*T+vec3(0.012,0.19,0.24)*(1.0-T); // approximate in-scattered body light
        vec3 reflected=reflect(rd,n);
        vec3 reflection=coastSky(normalize(vec3(reflected.x,max(reflected.y,0.01),reflected.z)));
#if QUALITY >= 2
        vec2 reflectedHit=traceCoast(p+n*0.015,reflected,false,WATER_STEPS);
        if(reflectedHit.x>0.0) {
            vec3 rp=p+n*0.015+reflected*reflectedHit.x;
            if(rp.y>0.02)reflection=shadeCoastBed(rp,coastBedNormal(rp.xz,0.015),false,footprint);
        }
#endif
        float unresolved=smoothstep(0.02,0.18,footprint);
        float rough=mix(0.075,0.20,unresolved);
        vec3 glint=specularGGX(n,v,COAST_SUN,rough,vec3(0.02037))*vec3(3.5,3.2,2.7);
        float shallow=1.0-smoothstep(0.08,0.5,max(p.y-bed,0.0));
        float shorePulse=0.5+0.5*sin((p.y-bed)*19.0-iTime*1.5+fbm(p.xz*2.0,3)*3.0);
        float foam=shallow*smoothstep(0.25,0.7,shorePulse)*(0.8+1.0*kick+0.5*drop);
        foam+=0.12*smoothstep(0.18,0.6,-waves.w)*(1.0-unresolved);
        foam=clamp(foam,0.0,1.0);
        col=mix(body*(1.0-F)+reflection*F+glint,vec3(0.8,0.84,0.82),foam);
#if DEBUG_MODE == 1
        return vec3(path/12.0);
#elif DEBUG_MODE == 2
        return n*0.5+0.5;
#elif DEBUG_MODE == 3
        return vec3(foam);
#elif DEBUG_MODE == 5
        return vec3(F);
#elif DEBUG_MODE == 6
        return T;
#endif
    }
    return mix(col,coastSky(normalize(vec3(rd.x,0.025,rd.z))),1.0-exp(-hit.x*0.003));
}

void mainImage(out vec4 fragColor,in vec2 fragCoord) {
    vec3 col=vec3(0.0);
    for(int i=0;i<WATER_AA;i++) {
        vec3 c=renderCoast(fragCoord+(WATER_AA>1?aaOffset(i):vec2(0.0)));
#if DEBUG_MODE == 0
        c=tonemapAgX(c*1.05*(1.0+0.10*swell+0.25*drop-0.12*build));
#endif
        col+=c/float(WATER_AA);
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
