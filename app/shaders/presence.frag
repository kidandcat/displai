// DisplAI presence animation: a JARVIS-style HUD "face" that reacts to voice.
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
//   20     uActivity    stream activity 0..1 (thinking sweep intensity)
//   21     uCompact     0 = full window, 1 = small status-bar orb
//
// Cost: no loops, one hash, ~20 exp/smoothstep, two atan. Everything is a
// closed-form distance function of the pixel, so it scales with pixel count
// only and stays well under a frame on large monitors.

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

void main() {
  vec2 frag = FlutterFragCoord().xy;
  float minRes = max(min(uResolution.x, uResolution.y), 1.0);
  float compact = step(0.5, uCompact);
  float full = 1.0 - compact;

  // Compact mode zooms in so the kept rings fill the orb.
  float zoom = mix(1.0, 0.62, compact);
  vec2 p = (frag - 0.5 * uResolution) / minRes * zoom;
  float px = zoom / minRes; // one logical pixel in shader units
  float aa = px;
  float r = length(p);
  float turn = atan(p.y, p.x) / TAU + 0.5;
  float aaT = px / (TAU * max(r, 1e-3));

  float wIdle = uState.x;
  float wListen = uState.y;
  float wThink = uState.z;
  float wSpeak = uState.w;
  float react = wListen + wSpeak;
  float lvl = uLevel * react;
  float breath = 0.5 + 0.5 * sin(uTime * 0.85);

  // Mirrored spectrum layout: lows at the top, highs at the bottom.
  float specT = abs(atan(p.x, -p.y)) / PI;
  float spec = bandAt(specT) * react;

  // Radial displacement shared by the rings: spectrum shape, loudness swell,
  // idle breathing and a tiny organic wobble.
  float wob = 0.0022 * sin(turn * TAU * 3.0 + uTime * 0.6) *
              sin(turn * TAU * 2.0 - uTime * 0.45);
  float disp = spec * (0.020 + 0.010 * wSpeak) + lvl * 0.010 + wob +
               breath * 0.004 * wIdle;

  float minW = px * 0.5 * compact; // keep lines >= 1 px wide in the orb
  vec3 col = vec3(0.0);
  float hot = 0.0;

  // --- Core -------------------------------------------------------------
  float thinkPulse = (0.5 + 0.5 * sin(uTime * 4.2)) * wThink;
  float coreI = 0.55 + 0.18 * breath * wIdle + 1.1 * lvl + 0.35 * thinkPulse;
  float coreR = 0.025 * (1.0 + 0.6 * lvl + 0.2 * thinkPulse);
  float rc = r / coreR;
  hot += exp(-rc * rc) * coreI;
  col += uAccent * (exp(-r * 24.0) * 0.55 * coreI + exp(-r * 6.0) * 0.07 * (1.0 + 1.5 * lvl));

  // --- Ring 0: fast twin arcs hugging the core (full only) ---------------
  if (full > 0.5) {
    float d = r - 0.045 - disp * 0.15;
    float m = segs(turn + uSpin * 0.16, 2.0, 0.32, aaT);
    col += uAccent * line(d, max(0.0011, minW), aa) * m * 0.85;
  }

  // --- Ring 1: thin solid ring ------------------------------------------
  {
    float d = r - 0.075 - disp * 0.35;
    col += uAccent * (line(d, max(0.0010, minW), aa) * 0.8 + exp(-abs(d) * 110.0) * 0.18);
  }

  // --- Ring 2: tick dial (full only) ------------------------------------
  if (full > 0.5) {
    float d = r - 0.105 - disp * 0.5;
    float t = turn + uSpin * 0.02;
    float ticks = segs(t, 72.0, 0.22, aaT) * line(d, 0.0045, aa);
    float major = segs(t + 0.003, 12.0, 0.012, aaT) * line(d, 0.0085, aa);
    col += uAccent * max(ticks * 0.45, major * 0.85);
  }

  // --- Ring 3: three thick outlined arcs, counter-rotating ---------------
  {
    float d = r - 0.145 - disp * 0.7;
    float w = max(0.0065, minW * 2.0);
    float m = segs(turn - uSpin * 0.035, 3.0, 0.27, aaT);
    float fill = line(d, w, aa) * 0.22;
    float edge = line(abs(d) - w, max(0.0007, minW), aa) * 0.9;
    float inner = line(d + 0.013, max(0.0006, minW), aa) * 0.22 * full;
    col += uAccent * ((fill + edge) * m + inner);
  }

  // --- Ring 4: fine dashes (full only) ----------------------------------
  if (full > 0.5) {
    float d = r - 0.19 - disp * 0.85;
    float m = segs(turn + uSpin * 0.012, 96.0, 0.5, aaT);
    col += uAccent * line(d, 0.0016, aa) * m * 0.5;
  }

  // --- Spectrum bars between ring 4 and ring 5 (audio states) -----------
  {
    float n = mix(96.0, 28.0, compact);
    float base = 0.203 + disp * 0.85;
    float len = 0.004 + spec * 0.04 + lvl * 0.006;
    float d = r - base - 0.5 * len;
    float m = segs(turn, n, 0.42, aaT);
    float bars = line(d, 0.5 * len, aa) * m;
    // Brighter towards the tip, so loud bands read as "lit".
    float tip = 0.35 + 0.65 * clamp((r - base) / max(len, 1e-3), 0.0, 1.0);
    col += uAccent * bars * tip * (0.12 + 0.6 * react) * (0.3 + 0.7 * react);
  }

  // --- Ring 5: thin line with two fast highlights + thinking sweep ------
  {
    float d = r - 0.24 - disp;
    float base = line(d, max(0.0009, minW), aa) * 0.35;
    float hiM = segs(turn + uSpin * 0.06, 2.0, 0.07 + 0.05 * wThink, aaT);
    float hi = line(d, max(0.0022, minW * 1.5), aa) * hiM * 0.9;
    col += uAccent * (base + hi + exp(-abs(d) * 140.0) * 0.12);
  }

  // --- Ring 6: outer faint scale (full only) ----------------------------
  if (full > 0.5) {
    float d = r - 0.30 - disp * 0.6;
    float t = turn - uSpin * 0.006;
    float minor = segs(t, 180.0, 0.28, aaT) * line(d, 0.0022, aa) * 0.22;
    float major = segs(t + 0.002, 36.0, 0.03, aaT) * line(d - 0.002, 0.0055, aa) * 0.4;
    float rim = line(d - 0.013, 0.0006, aa) * 0.12;
    col += uAccent * (max(minor, major) + rim);
  }

  // --- Thinking: expanding pulses and a radar sweep ---------------------
  if (wThink > 0.001) {
    float f0 = fract(uTime * 0.45);
    float f1 = fract(uTime * 0.45 + 0.5);
    float p0 = exp(-abs(r - 0.04 - f0 * 0.28) * 150.0) * (1.0 - f0) * (1.0 - f0);
    float p1 = exp(-abs(r - 0.04 - f1 * 0.28) * 150.0) * (1.0 - f1) * (1.0 - f1);
    float sweepTurn = fract(uSpin * 0.22);
    float behind = fract(sweepTurn - turn);
    float wedge = smoothstep(0.055, 0.075, r) * (1.0 - smoothstep(0.27, 0.31, r));
    float trail = exp(-behind * 9.0) * (0.10 + 0.12 * uActivity) * wedge;
    float head = exp(-behind * 260.0) * 0.45 * wedge;
    col += uAccent * wThink * ((p0 + p1) * 0.5 + trail + head * full);
  }

  // --- Particles and scan band (full only) ------------------------------
  if (full > 0.5) {
    vec2 g = p * 26.0 + vec2(0.0, uTime * 0.06);
    vec2 cell = floor(g);
    float h = hash12(cell);
    vec2 off = vec2(h, fract(h * 17.31)) * 0.6 + 0.2;
    float pxc = px * 26.0;
    float dist = length(fract(g) - off);
    float dotv = 1.0 - smoothstep(pxc * 0.6, pxc * 1.8, dist);
    float twinkle = 0.5 + 0.5 * sin(uTime * (0.7 + 1.6 * h) + h * 40.0);
    float on = step(0.62, h);
    float fade = smoothstep(0.09, 0.32, r);
    col += uAccent * dotv * on * twinkle * fade * (0.22 + 0.4 * lvl);

    float scanY = fract(uTime * 0.06) * 1.6 - 0.8;
    float sy = (p.y - scanY) * 14.0;
    col += uAccent * exp(-sy * sy) * 0.035;
  }

  // Tone map (soft clip) and add the white-hot core.
  col += (vec3(1.0) * 0.75 + uAccent * 0.5) * hot;
  col = 1.0 - exp(-col * 1.45);

  if (full > 0.5) {
    // Fine scan lines and a vignetted near-black background.
    col *= 0.9 + 0.1 * sin(frag.y * TAU / 3.0);
    vec3 bg = vec3(0.006, 0.012, 0.018) + uAccent * 0.03 * exp(-r * 3.0);
    bg *= 1.0 - 0.5 * smoothstep(0.35, 1.0, length(p * vec2(0.75, 1.0)));
    fragColor = vec4(bg + col, 1.0);
  } else {
    // Transparent orb: fade the glow out before the rect edge, then output
    // premultiplied color with alpha following the light.
    col *= 1.0 - smoothstep(0.40 * zoom, 0.5 * zoom, r);
    float a = clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0);
    fragColor = vec4(col, a);
  }
}
