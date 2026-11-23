// Minerva presence: a 3D orb that reacts to voice.
//
// A glass sphere with a volumetric energy core, a holographic lat/long grid on
// its shell and six tilted rings orbiting it, all ray-traced (orthographic, so every ring shares the center).
//
// Uniform layout (float indices for FragmentShader.setFloat):
//   0      uTime        seconds since start
//   1..2   uResolution  logical size of the painted rect
//   3      uLevel       smoothed loudness 0..1
//   4..7   uBandsLo     spectrum bands 0..3 (0..1)
//   8..11  uBandsHi     spectrum bands 4..7 (0..1)
//   12..15 uState       cross-fade weights: idle, listening, thinking, speaking
//   16..18 uAccent      accent color (linear-ish RGB 0..1)
//   19     uSpin        integrated rotation phase (speeds up while thinking)
//   20     uActivity    stream activity 0..1 (thinking intensity)
//   21     uCompact     0 = full window, 1 = small corner orb (additive, no backdrop)
//
// Cost: analytic sphere and ring-plane intersections plus a 22-step march
// through the core, only for rays that hit the sphere. Rays that miss it pay
// for the rings and the background only.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform float uTime;
uniform vec2 uResolution;
uniform float uLevel;
uniform vec4 uBandsLo;
uniform vec4 uBandsHi;
uniform vec4 uState;
uniform vec3 uAccent;
uniform float uSpin;
uniform float uActivity;
uniform float uCompact;

out vec4 fragColor;

const float PI = 3.14159265;
const float TAU = 6.28318531;
const float CAM_D = 4.5; // ray origin depth (unit sphere at the origin)

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Spectrum at t in [0, 1], linearly interpolated across the 8 bands.
float bandAt(float t) {
  float x = clamp(t, 0.0, 1.0) * 7.0;
  vec4 w0 = max(1.0 - abs(x - vec4(0.0, 1.0, 2.0, 3.0)), 0.0);
  vec4 w1 = max(1.0 - abs(x - vec4(4.0, 5.0, 6.0, 7.0)), 0.0);
  return dot(w0, uBandsLo) + dot(w1, uBandsHi);
}

// Anti-aliased band of half-width w around d = 0.
float line(float d, float w, float aa) {
  return 1.0 - smoothstep(w, w + aa, abs(d));
}

// Angular segments: n per turn, lit fraction `duty`, aaT = one pixel in turns.
float segs(float turn, float n, float duty, float aaT) {
  float f = fract(turn * n);
  float e = clamp(aaT * n, 1e-4, 0.5 * duty);
  return smoothstep(0.0, e, f) * (1.0 - smoothstep(duty - e, duty, f));
}

mat3 rotX(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat3(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c);
}

mat3 rotY(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
}

// Ray / sphere at the origin: (near, far); near > far on a miss.
vec2 sphere(vec3 ro, vec3 rd, float r) {
  float b = dot(ro, rd);
  float h = b * b - (dot(ro, ro) - r * r);
  if (h < 0.0) return vec2(1e5, -1e5);
  h = sqrt(h);
  return vec2(-b - h, -b + h);
}

// Smooth, texture-free 3D field in [-1, 1], domain-warped so it swirls.
float field(vec3 q, float t) {
  vec3 w = q + 0.45 * sin(q.yzx * 2.3 + t * vec3(0.9, 1.1, 0.7));
  return sin(w.x * 3.1 + t) * sin(w.y * 2.7 - t * 1.3) * sin(w.z * 3.4 + t * 0.8);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  float minRes = max(min(uResolution.x, uResolution.y), 1.0);
  float compact = step(0.5, uCompact);
  float full = 1.0 - compact;

  vec2 p = (frag - 0.5 * uResolution) / minRes;
  p.y = -p.y;
  float px = 1.0 / minRes;

  float wIdle = uState.x;
  float wListen = uState.y;
  float wThink = uState.z;
  float wSpeak = uState.w;
  float lvl = clamp(uLevel, 0.0, 1.0);
  float react = clamp(wListen + wSpeak, 0.0, 1.0);

  // Camera: the unit sphere spans `screenR` (in min-side units) on screen.
  float screenR = mix(0.14, 0.205, compact);
  // Orthographic: every ring is a circle around the origin, so on screen all
  // of them share the sphere's center (perspective shifts tilted rings).
  vec3 ro = vec3(p / screenR, CAM_D);
  vec3 rd = vec3(0.0, 0.0, -1.0);
  float pxW = px / screenR; // one pixel, in world units

  // The whole object slowly turns; thinking spins it faster.
  mat3 M = rotX(0.42 + 0.08 * sin(uSpin * 0.09)) * rotY(uTime * 0.06 + uSpin * 0.04);

  float shellR = 1.0 + 0.012 * sin(uTime * 1.4) * (wIdle + wListen) + 0.045 * lvl * react;
  vec2 hs = sphere(ro, rd, shellR);
  float hit = step(0.0, hs.x) * step(hs.x, hs.y);

  vec3 col = vec3(0.0);
  vec3 L = normalize(vec3(-0.55, 0.7, 0.55));
  vec3 cool = mix(uAccent, vec3(0.5, 0.42, 1.0), 0.45);

  if (hit > 0.5) {
    // --- Energy core: march through the sphere ---------------------------
    float t0 = hs.x;
    float dt = (hs.y - hs.x) / 22.0;
    float tt = uTime * (0.55 + 1.6 * wThink + 0.6 * wSpeak);
    float coreR = 0.27 + 0.14 * lvl * react + 0.025 * sin(uTime * 1.9) + 0.05 * wThink;
    vec3 acc = vec3(0.0);
    for (int i = 0; i < 22; i++) {
      vec3 q = ro + rd * (t0 + (float(i) + 0.5) * dt);
      vec3 qo = M * q;
      float r = length(q);
      float f = field(qo * 1.35, tt);
      float x = r / coreR;
      float dens = exp(-x * x * 2.0) * (0.6 + 0.4 * f) + exp(-x * x * 9.0) * 1.5; // white-hot heart
      // Voice lobes: the spectrum pushes energy out by direction.
      float az = atan(qo.z, qo.x) / TAU + 0.5;
      float band = bandAt(abs(fract(az * 2.0) * 2.0 - 1.0));
      float shellD = (r - 0.6) / 0.17;
      dens += react * band * 0.9 * exp(-shellD * shellD) * (0.55 + 0.45 * f);
      // Thin bright filaments where the field crosses zero.
      float fil = exp(-abs(f) * 18.0) * (1.0 - smoothstep(0.2, 0.6, r)) * (0.3 + 0.4 * wThink);
      vec3 c = mix(cool, uAccent, smoothstep(0.0, 0.5, dens));
      c = mix(c, vec3(1.0), smoothstep(0.55, 1.1, dens));
      acc += c * (dens * 2.6 + fil) * dt;
    }
    col += acc * (1.0 + 0.5 * wThink + 0.8 * lvl * wSpeak);

    // --- Holographic grid on the shell (front bright, back dim) ----------
    for (int s = 0; s < 2; s++) {
      float t = s == 0 ? hs.x : hs.y;
      vec3 n = normalize(ro + rd * t);
      vec3 qo = M * n;
      float lat = asin(clamp(qo.y, -1.0, 1.0));
      float lon = atan(qo.z, qo.x);
      float gStep = PI / 7.0;
      float dLat = abs(fract(lat / gStep + 0.5) - 0.5) * gStep;
      float dLon = abs(fract(lon / gStep + 0.5) - 0.5) * gStep * cos(lat);
      float view = abs(dot(n, rd));
      float aaG = pxW / shellR / max(view, 0.25);
      float g = max(line(dLat, 0.0, aaG), line(dLon, 0.0, aaG) * smoothstep(0.0, 0.35, cos(lat)));
      float lit = 0.04 + 0.3 * react * bandAt(fract(lon / TAU + 0.5));
      // Thinking: a bright latitude sweeps up and down the shell.
      float sweep = sin(uTime * 1.6) * 1.2;
      float sw = exp(-abs(lat - sweep) * 18.0) * wThink * 0.55;
      float side = s == 0 ? 1.0 : 0.3;
      col += uAccent * (g * lit + sw * (0.3 + 0.7 * g)) * side;
    }

    // --- Glass: fresnel rim, iridescence, highlights ---------------------
    vec3 n = normalize(ro + rd * hs.x);
    float ndv = max(dot(n, -rd), 0.0);
    float fres = pow(1.0 - ndv, 3.0);
    vec3 rim = mix(uAccent, vec3(0.88, 0.45, 1.0), smoothstep(0.2, 0.9, 1.0 - ndv) * 0.45);
    col += rim * fres * (0.75 + 0.9 * lvl * react + 0.3 * wThink);
    vec3 h = normalize(L - rd);
    col += vec3(1.0) * pow(max(dot(n, h), 0.0), 90.0) * 0.85;
    // Soft bounce light from below, in the accent color.
    col += uAccent * pow(max(dot(n, normalize(vec3(0.3, -0.8, 0.4))), 0.0), 6.0) * 0.12;
  }

  // --- Halo around the silhouette ----------------------------------------
  float dRay = length(ro.xy); // ray distance to the center
  float halo = exp(-max(dRay - shellR, 0.0) * 5.0) * (1.0 - hit);
  col += uAccent * halo * mix(0.2, 0.1, compact) * (1.0 + 1.2 * lvl * react + 0.4 * wThink);

  // --- Orbiting rings ------------------------------------------------------
  // Six rings, mostly coplanar (Saturn-like, seen from slightly above) plus one
  // polar orbit for depth. They turn with uSpin, whose rate the app raises with
  // activity (listening < speaking < thinking), so an active orb visibly spins.
  for (int i = 0; i < 6; i++) {
    float fi = float(i);
    float polar = step(3.5, fi) * step(fi, 4.5); // ring 4
    // Each orbit precesses around the sphere and nods, driven by uSpin too, so
    // activity makes the rings orbit and tumble, not just turn in place.
    float dirO = 1.0 - 2.0 * mod(floor(fi * 0.5), 2.0);
    float tilt = mix(0.30 + 0.05 * fi, 1.12, polar)
        + (0.10 + 0.08 * polar) * sin(uSpin * (0.11 + 0.02 * fi) + fi * 2.0);
    float yaw = 1.5708 + (mod(fi, 2.0) - 0.5) * 0.6 + polar * 0.9
        + uSpin * dirO * (0.07 + 0.025 * fi + 0.1 * polar);
    vec3 nrm = normalize(vec3(sin(tilt) * cos(yaw), cos(tilt), sin(tilt) * sin(yaw)));
    vec3 u = normalize(cross(nrm, vec3(0.0, 0.0, 1.0)));
    vec3 v = cross(nrm, u);
    float dn = dot(rd, nrm);
    float t = -dot(ro, nrm) / (abs(dn) < 1e-4 ? 1e-4 : dn);
    if (t <= 0.0) continue;
    vec3 q = ro + rd * t;
    float rr = length(q);
    float ang = atan(dot(q, v), dot(q, u)) / TAU + 0.5;
    float aa = pxW / max(abs(dn), 0.18);
    float aaT = aa / (TAU * max(rr, 1e-3));
    float ringR = 1.28 + 0.17 * fi + polar * 0.1;
    float d = rr - ringR;
    // Alternate directions; inner rings turn faster.
    float dir = 1.0 - 2.0 * mod(fi, 2.0);
    float spin = uSpin * dir * (0.045 - 0.005 * fi);
    float m = 0.0;
    if (i == 0) {
      // Thin solid ring with two bright runners.
      float runners = segs(ang + spin * 2.5, 2.0, 0.07 + 0.05 * wThink, aaT);
      m = line(d, 0.005, aa) * 0.5 + line(d, 0.011, aa) * runners * 1.1;
    } else if (i == 1) {
      // Tick dial with major marks.
      float ticks = segs(ang + spin, 90.0, 0.3, aaT) * line(d, 0.02, aa);
      float major = segs(ang + spin + 0.002, 12.0, 0.02, aaT) * line(d, 0.04, aa);
      m = max(ticks * 0.42, major * 0.9);
    } else if (i == 2) {
      // Voice spectrum: radial bars, quiet when idle.
      float len = 0.012 + bandAt(abs(fract(ang * 2.0) * 2.0 - 1.0)) * 0.13 + lvl * 0.02;
      float db = d - 0.5 * len;
      m = segs(ang + spin, 72.0, 0.4, aaT) * line(db, 0.5 * len, aa) * (0.18 + 0.7 * react);
    } else if (i == 3) {
      // Three thick outlined arcs.
      float arcs = segs(ang + spin, 3.0, 0.22, aaT);
      float w = 0.026;
      m = (line(d, w, aa) * 0.2 + line(abs(d) - w, 0.004, aa) * 0.9) * arcs;
    } else if (i == 4) {
      // Polar orbit: a fine line with one comet and its tail.
      float head = fract(ang + spin * 3.0);
      float tail = exp(-(1.0 - head) * 7.0) * step(0.0, head);
      m = line(d, 0.004, aa) * (0.22 + 0.9 * tail);
    } else {
      // Outer orbit: fine dashes and two long brackets.
      float dashes = segs(ang + spin, 120.0, 0.45, aaT) * line(d, 0.003, aa) * 0.35;
      float brackets = segs(ang + spin + 0.1, 2.0, 0.16, aaT) * line(d + 0.025, 0.006, aa) * 0.8;
      m = dashes + brackets;
    }
    // Behind the glass the ring is dimmer, and bluer.
    float behind = hit * step(hs.x, t);
    vec3 rc = mix(uAccent, cool, behind);
    col += rc * m * mix(1.0, 0.3, behind) * (0.85 + 0.25 * wThink + 0.3 * lvl * react);
  }

  // Tone map (soft clip).
  col = 1.0 - exp(-col * 1.4);

  if (full > 0.5) {
    // Near-black backdrop with a faint accent glow and slow drifting motes.
    float r = length(p);
    vec3 bg = vec3(0.012, 0.008, 0.018) + uAccent * 0.035 * exp(-r * 3.5);
    bg *= 1.0 - 0.5 * smoothstep(0.35, 1.0, length(p * vec2(0.75, 1.0)));
    vec2 g = p * 26.0 + vec2(0.0, uTime * 0.05);
    vec2 cell = floor(g);
    float hsh = hash12(cell);
    vec2 off = vec2(hsh, fract(hsh * 17.31)) * 0.6 + 0.2;
    float pxc = px * 26.0;
    float dotv = 1.0 - smoothstep(pxc * 0.6, pxc * 1.8, length(fract(g) - off));
    float twinkle = 0.5 + 0.5 * sin(uTime * (0.7 + 1.6 * hsh) + hsh * 40.0);
    bg += uAccent * dotv * step(0.64, hsh) * twinkle * smoothstep(0.2, 0.45, r) * (0.18 + 0.3 * lvl);
    fragColor = vec4(bg + col * (1.0 - bg), 1.0);
  } else {
    // Corner orb: light only (premultiplied, alpha 0 = additive), faded before the rect edge.
    col *= 1.0 - smoothstep(0.44, 0.5, length(p));
    fragColor = vec4(col, 0.0);
  }
}
