// Minerva presence: a holographic AI core that reacts to voice.
//
// From the inside out:
//   nucleus    white-hot heart with a soft bloom and a thin lens streak
//   plasma     a counter-rotating inner ball of energy filaments
//   shell      a sphere of data points (rows of dots, each row turning at its own rate), seen
//              from the front and, dimmer, through to the back
//   gyroscope  three tilted orbits with comets, passing behind and in front of the shell
//   HUD        a slightly tilted instrument plane: spectrum bars, chasers, a tick dial with a radar
//              sweep, drifting motes, a data track, bracket arcs and cardinal marks (the compact
//              orb keeps the spectrum bars only)
//
// How each state reads:
//   idle       everything slow and dim; the nucleus breathes
//   listening  the user's voice lights the spectrum bars and swells the shell's dot rows, in the
//              second accent color
//   thinking   the dot rows spin against each other and fire at random, a meridian scan sweeps the
//              shell, the gyroscope tumbles, chasers run around the HUD and its data track flickers
//              (all of it faster with uActivity, through uSpin)
//   speaking   the nucleus and the plasma flare with Minerva's voice, ripples travel outward and a
//              voice contour blooms around the shell
//   muted      the app fades both accents to red
//   workers    each running background worker (up to three) takes an orbit of the gyroscope: a
//              bright amber satellite (kPresenceWorkerAccent) travels along it with an amber wake,
//              the only amber in the orb; when the worker ends, the orbit flares amber and fades
//
// Uniform layout (float indices for FragmentShader.setFloat):
//   0      uTime        seconds, wrapped by the app at 2000*pi
//   1..2   uOrigin      top-left corner of the painted square, in canvas coordinates
//   3      uSize        side of the painted square, logical pixels
//   4      uPx          device pixels per logical pixel (anti-aliasing width)
//   5      uLevel       smoothed loudness 0..1
//   6..9   uBandsLo     spectrum bands 0..3 (0..1)
//   10..13 uBandsHi     spectrum bands 4..7 (0..1)
//   14..17 uState       cross-fade weights: idle, listening, thinking, speaking
//   18..20 uAccent      accent color (RGB 0..1)
//   21..23 uAccent2     second accent color, the "input" side of the palette
//   24     uSpin        integrated rotation phase, wrapped at 2000*pi (faster while busy)
//   25     uActivity    stream activity 0..1 (thinking intensity)
//   26     uCompact     0 = full orb with its HUD, 1 = small orb
//   27..35 uRotX/Y/Z    rows of the shell's rotation matrix (view -> object)
//   36..53 uRing0..2    per orbit: inverse 2x2 projection (vec4) and depth coefficients (vec2)
//   54..57 uHud         inverse 2x2 projection of the HUD plane
//   58..60 uWork        per orbit: how much a running background worker is on it, 0..1 (eased)
//   61..63 uDone        per orbit: the flare of a worker that just ended, 1 fading to 0
//
// uTime and uSpin wrap so they keep float precision for days. A wrap is seamless as long as every
// multiplier applied to them inside a sin/cos (or to uSpin / TAU inside a fract, times an integer)
// has at most three decimals: keep it that way.
//
// Cost: everything is analytic (no ray marching). One sqrt for the shell, two dot lookups, two
// plasma samples, three 2x2-projected orbits and one polar transform for the HUD; each part is
// skipped outside its own radius, and pixels outside the orb return at once. The app paints only a
// square around the orb (not the window), at 20-30 fps while calm and 60 fps while busy. All
// per-frame trigonometry (rotations, orbit planes) is done once in Dart, not per pixel.
// The output is premultiplied light. The full orb's alpha is 0 (additive), so it sits on any
// backdrop. The small orb's alpha follows its light (a little over it, a faint shade that keeps it
// readable over light apps), so it also shows on a transparent window, where pixels of alpha 0 are
// dropped, with nothing around it.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform float uTime;
uniform vec2 uOrigin;
uniform float uSize;
uniform float uPx;
uniform float uLevel;
uniform vec4 uBandsLo;
uniform vec4 uBandsHi;
uniform vec4 uState;
uniform vec3 uAccent;
uniform vec3 uAccent2;
uniform float uSpin;
uniform float uActivity;
uniform float uCompact;
uniform vec3 uRotX;
uniform vec3 uRotY;
uniform vec3 uRotZ;
uniform vec4 uRing0;
uniform vec2 uRing0Z;
uniform vec4 uRing1;
uniform vec2 uRing1Z;
uniform vec4 uRing2;
uniform vec2 uRing2Z;
uniform vec4 uHud;
uniform vec3 uWork;
uniform vec3 uDone;

out vec4 fragColor;

const float PI = 3.14159265;
const float TAU = 6.28318531;
// kPresenceWorkerAccent (presence_view.dart): amber, apart from both accents and the muted reds.
const vec3 WORK = vec3(1.0, 0.682, 0.259);

float hash11(float x) {
  x = fract(x * 0.1031);
  x *= x + 33.33;
  x *= x + x;
  return fract(x);
}

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

// Smooth, texture-free 3D field in [-1, 1], domain-warped so it swirls.
float field(vec3 q, float t) {
  vec3 w = q + 0.5 * sin(q.yzx * 2.3 + t * vec3(0.9, 1.1, 0.7));
  return sin(w.x * 3.1 + t) * sin(w.y * 2.7 - t * 1.3) * sin(w.z * 3.4 + t * 0.8);
}

void main() {
  vec2 frag = FlutterFragCoord().xy - uOrigin;
  vec2 p = frag / uSize - 0.5;
  p.y = -p.y;
  float compact = step(0.5, uCompact);

  // Everything below is in shell radii: the shell is the unit circle.
  float R = mix(0.19, 0.25, compact); // shell radius, in squares
  vec2 q = p / R;
  float r = length(q);
  float rMax = 0.5 / R;
  if (r >= rMax) {
    fragColor = vec4(0.0);
    return;
  }
  float pxW = 1.0 / (uSize * uPx * R); // one device pixel

  float wListen = uState.y;
  float wThink = uState.z;
  float wSpeak = uState.w;
  float lvl = clamp(uLevel, 0.0, 1.0);
  float react = clamp(wListen + wSpeak, 0.0, 1.0);
  float hear = wListen * lvl;
  float say = wSpeak * lvl;
  float sturn = uSpin / TAU;
  float breath = sin(uTime * 0.9);
  float pulse = 0.5 + 0.5 * sin(uSpin * 0.5); // a slow swell at rest, a heartbeat while busy

  vec3 A = uAccent;
  vec3 B = uAccent2;
  vec3 hot = mix(A, vec3(1.0), 0.78);
  vec3 col = vec3(0.0);

  // --- Shell: a sphere of data points ---------------------------------------
  float shellR = 1.0 + 0.010 * breath + 0.05 * say + 0.015 * hear;
  float rs = r / shellR;
  if (rs < 1.0) {
    float z = sqrt(1.0 - rs * rs);
    vec2 qs = q / shellR;
    float rows = mix(26.0, 12.0, compact);
    float cellH = PI / rows;
    float aaS = pxW / max(z, 0.22); // the surface is foreshortened toward the limb
    for (int s = 0; s < 2; s++) {
      vec3 n = vec3(qs, s == 0 ? z : -z);
      vec3 o = vec3(dot(uRotX, n), dot(uRotY, n), dot(uRotZ, n));
      float lat = asin(clamp(o.y, -1.0, 1.0));
      float j = floor((lat / PI + 0.5) * rows);
      float latC = ((j + 0.5) / rows - 0.5) * PI;
      // As many dots per row as fit its parallel, so they are evenly spread.
      float cnt = max(floor(cos(latC) * rows * 2.0 + 0.5), 1.0);
      float lon = atan(o.z, o.x);
      // Each row turns at its own rate: a slow shear at rest, a spinning drum while thinking.
      float rowRate = (floor(hash11(j + 3.0) * 9.0) - 4.0) * 0.03;
      float u = (lon / TAU + 0.5 + sturn * rowRate) * cnt;
      float k = mod(floor(u), cnt);
      float d = length(vec2((fract(u) - 0.5) / cnt * TAU * cos(lat), lat - latC));
      float hd = hash12(vec2(k, j) + 7.0);
      // Lows at the equator, highs at the poles. Mostly the user's voice: Minerva's lights the inside.
      float band = bandAt(abs(latC) / (0.5 * PI)) * (wListen + 0.3 * wSpeak);
      float tw = 0.5 + 0.5 * sin(hd * 40.0 + uTime * (0.5 + floor(hd * 8.0) * 0.25));
      float fire = pow(0.5 + 0.5 * sin(hd * 71.0 + uSpin * (0.3 + floor(hd * 6.0) * 0.1)), 8.0) * wThink;
      float scan = pow(0.5 + 0.5 * cos(lon + uSpin * 0.2), 12.0) * wThink;
      float rad = cellH * (0.13 + 0.05 * tw + 0.13 * band + 0.10 * fire + 0.06 * scan);
      float m = 1.0 - smoothstep(rad - aaS, rad + aaS, d);
      float lum = 0.26 + 0.34 * tw + 1.3 * band + 1.5 * fire + 0.9 * scan + 0.5 * say;
      vec3 dc = mix(mix(A, B, 0.2 + 0.5 * hd + 0.3 * wListen - 0.2 * wSpeak), hot, clamp(0.8 * fire + 0.5 * band, 0.0, 1.0));
      col += dc * m * lum * (s == 0 ? 1.0 : 0.24);
    }
    // Glass: a fresnel rim and a faint body, so the shell reads as a volume.
    float fres = pow(1.0 - z, 2.5);
    col += mix(A, B, 0.35) * fres * (0.34 + 0.6 * say + 0.4 * hear + 0.2 * wThink);
    col += A * 0.03 * z;
  }
  // Crisp silhouette and the halo around it.
  float dEdge = r - shellR;
  col += mix(A, B, 0.3) * line(dEdge, 0.0, pxW * 1.5) * 0.4;
  col += A * exp(-max(dEdge, 0.0) * 7.0) * step(0.0, dEdge) * 0.15 * (1.0 + 1.6 * say + 0.9 * hear + 0.4 * wThink);

  // --- Plasma: an inner ball of filaments, turning against the shell ---------
  float ri = 0.60 + 0.06 * wSpeak + 0.16 * say + 0.03 * wThink;
  if (r < ri) {
    float zi = sqrt(1.0 - (r * r) / (ri * ri));
    vec2 qi = q / ri;
    float tt = uTime * 0.35 + uSpin * 0.06;
    vec3 of = uRotX * qi.x + uRotY * qi.y + uRotZ * zi; // transpose = the opposite rotation
    vec3 ob = uRotX * qi.x + uRotY * qi.y - uRotZ * zi;
    float ff = field(of * 1.7, tt);
    float fb = field(ob * 1.7 + 2.0, tt);
    float gain = 0.42 + 0.55 * wThink + 0.5 * wSpeak + 1.8 * say + 0.3 * hear;
    vec3 front = mix(B, A, 0.5 + 0.5 * ff) * (exp(-abs(ff) * 16.0) * 0.95 + 0.08);
    vec3 back = mix(A, B, 0.5 + 0.5 * fb) * exp(-abs(fb) * 16.0) * 0.4;
    col += (front + back) * zi * zi * gain;
  }

  // --- Nucleus -----------------------------------------------------------------
  float cr = 0.17 + 0.02 * breath + 0.08 * say + 0.03 * hear + 0.04 * wThink * pulse;
  float x = r / cr;
  col += hot * exp(-x * x * 1.2) * (1.0 + 0.5 * say + 0.35 * wThink * pulse);
  col += A * exp(-x * 0.9) * 0.45;
  col += hot * exp(-abs(q.y) * 30.0 - abs(q.x) * 1.5) * (0.10 + 0.4 * say + 0.12 * wThink);

  // --- Speaking: ripples travelling outward, and the voice contour -------------
  if (wSpeak > 0.004) {
    float rip = pow(0.5 + 0.5 * sin(r * 17.0 - uTime * 9.0), 9.0);
    col += mix(A, hot, 0.35) * rip * say * 0.7 * smoothstep(0.2, 0.5, r) * exp(-max(r - 1.0, 0.0) * 1.5);
    if (r > 0.9 && r < 1.75) {
      float turn = atan(q.y, q.x) / TAU + 0.5;
      float bw = bandAt(abs(fract(turn * 2.0 + 0.25) * 2.0 - 1.0));
      float rc = shellR + 0.06 + (0.03 + 0.36 * bw) * (0.2 + 0.8 * lvl)
          + 0.012 * sin(turn * TAU * 7.0 + uTime * 5.0) * lvl;
      float dc = r - rc;
      float aura = (1.0 - smoothstep(-0.3, 0.0, dc)) * step(dc, 0.0) * step(shellR, r);
      col += (hot * line(dc, 0.004, pxW * 1.2) * 0.85 + A * exp(-abs(dc) * 24.0) * 0.3 + A * aura * 0.14)
          * wSpeak * (0.35 + 0.65 * lvl);
    }
  }

  // --- Gyroscope: three tilted orbits with comets -------------------------------
  float gyroR = mix(1.25, 1.21, compact);
  float gyroStep = mix(0.12, 0.105, compact);
  if (r > 0.35 && r < gyroR + 2.0 * gyroStep + 0.25) {
    float lw = max(0.0032, 0.42 * pxW);
    for (int i = 0; i < 3; i++) {
      vec4 m = i == 0 ? uRing0 : (i == 1 ? uRing1 : uRing2);
      vec2 zc = i == 0 ? uRing0Z : (i == 1 ? uRing1Z : uRing2Z);
      float wk = i == 0 ? uWork.x : (i == 1 ? uWork.y : uWork.z);
      float wd = i == 0 ? uDone.x : (i == 1 ? uDone.y : uDone.z);
      float rad = gyroR + gyroStep * float(i);
      // Screen point -> point of the orbit's plane (orthographic view, so this is linear).
      vec2 ab = vec2(dot(m.xy, q), dot(m.zw, q));
      float len = max(length(ab), 1e-4);
      vec2 dir = ab / len;
      float grad = max(length(dir.x * m.xy + dir.y * m.zw), 1e-3);
      float ds = (len - rad) / grad; // distance to the orbit, on screen
      // Where a worker's satellite is on this orbit, as an angle of its plane; it goes the way the
      // comets go.
      float sgn = i == 1 ? -1.0 : 1.0;
      float ma = sgn * uTime * (0.45 + 0.1 * float(i)) + float(i) * 2.1;
      if (abs(ds) < 0.2) {
        float turn = atan(ab.y, ab.x) / TAU + 0.5;
        float depth = dot(zc, ab);
        float tail;
        float dh;
        float base;
        if (i == 1) {
          // Two comets, opposite each other.
          tail = exp(-(1.0 - fract(turn * 2.0)) * 5.0);
          dh = length(vec2(abs(ab.x) - rad, ab.y));
          base = 0.26;
        } else if (i == 2) {
          // A dashed orbit with one long comet.
          tail = exp(-(1.0 - turn) * 3.2);
          dh = length(ab + vec2(rad, 0.0));
          base = 0.10 + 0.34 * segs(turn, 40.0, 0.5, pxW / (TAU * rad) * grad);
        } else {
          tail = exp(-(1.0 - turn) * 6.0);
          dh = length(ab + vec2(rad, 0.0));
          base = 0.30;
        }
        float lum = line(ds, lw, pxW) * (base + 1.15 * tail) + exp(-abs(ds) * 30.0) * (0.04 + 0.3 * tail);
        float head = exp(-dh * dh * 1100.0);
        // Behind the shell the orbit shows through the glass; behind its plane it is just dimmer.
        float vis = depth >= 0.0 ? 1.0 : mix(0.5, 0.13, 1.0 - smoothstep(shellR - 0.02, shellR + 0.02, r));
        vec3 rc = mix(A, B, i == 1 ? 0.85 : 0.12);
        col += (rc * lum + hot * head * 1.3) * vis * (0.8 + 0.4 * wThink + 0.35 * lvl * react);
        // A background worker on this orbit: the orbit turns amber, brightest in the satellite's
        // wake. When the worker ends, the whole orbit flares amber and fades back.
        if (wk + wd > 0.002) {
          float wake = exp(-fract(sgn * (ma / TAU + 0.5 - turn)) * 5.0);
          float tint = line(ds, lw * 1.3, pxW) * (0.45 + 1.4 * wake) + exp(-abs(ds) * 24.0) * (0.06 + 0.3 * wake);
          col += WORK * tint * wk * max(vis, 0.35);
          col += (mix(WORK, vec3(1.0), 0.4) * line(ds, lw * 2.2, pxW) * 1.3 + WORK * exp(-abs(ds) * 16.0) * 0.6)
              * wd * max(vis, 0.35);
        }
      }
      // The worker's satellite: a white-hot amber bead with a wide halo, a few pixels across even on
      // the corner orb, and only dimmed (never hidden) behind the shell.
      if (wk > 0.002) {
        vec2 sab = rad * vec2(cos(ma), sin(ma));
        // Back from the orbit's plane to the screen: the inverse of m.
        vec2 sq = vec2(m.w * sab.x - m.y * sab.y, m.x * sab.y - m.z * sab.x) / (m.x * m.w - m.y * m.z);
        float dm = length(q - sq);
        float sr = max(mix(0.045, 0.085, compact), 2.5 * pxW);
        float behind = dot(zc, sab) < 0.0 && length(sq) < shellR ? 0.5 : 1.0;
        float beat = 0.85 + 0.15 * sin(uTime * 3.0 + float(i) * 2.1);
        float core = 1.0 - smoothstep(sr - pxW, sr + pxW, dm);
        float halo = exp(-dm * dm / (sr * sr) * 0.35);
        col += (mix(WORK, vec3(1.0), 0.5) * core * 2.5 + WORK * halo * 1.1 * beat) * wk * behind;
      }
    }
  }

  // --- HUD: a slightly tilted instrument plane -----------------------------------
  float r0 = mix(1.70, 1.50, compact); // foot of the spectrum bars
  if (r > r0 - 0.25) {
    vec2 h = vec2(dot(uHud.xy, q), dot(uHud.zw, q));
    float rh = length(h);
    float th = atan(h.y, h.x) / TAU + 0.5;
    float aa = pxW * 1.15;
    float aaT = aa / (TAU * rh);

    // Spectrum bars: the voice, mirrored four ways. Mostly the user's (listening).
    float nb = mix(96.0, 44.0, compact);
    float bi = floor(th * nb);
    float tb = abs(fract((bi + 0.5) / nb * 2.0) * 2.0 - 1.0);
    float jit = 0.72 + 0.28 * sin(bi * 12.9898 + uTime * 9.0);
    float amp = bandAt(tb) * (wListen + 0.4 * wSpeak) * jit;
    float shimmer = 0.5 + 0.5 * sin(bi * TAU * 3.0 / nb + uTime * 1.3);
    float len = 0.016 + 0.014 * shimmer + mix(0.32, 0.25, compact) * amp;
    float dr = rh - r0;
    float bar = segs(th, nb, 0.5, aaT) * smoothstep(-aa, 0.0, dr) * (1.0 - smoothstep(len, len + aa, dr));
    vec3 barC = mix(mix(A, B, 0.15 + 0.85 * wListen), hot, clamp(amp * 0.6, 0.0, 1.0));
    col += barC * bar * (0.2 + 0.1 * shimmer + 0.25 * react + 1.1 * amp);
    col += mix(A, B, wListen) * line(dr + 0.03, 0.0, aa) * 0.22;

    if (compact < 0.5) {
      // Thinking: three chasers between the gyroscope and the bars.
      float ch = fract(th * 3.0 - sturn * 0.9);
      col += mix(B, hot, ch * ch * ch) * line(rh - 1.6, 0.007, aa) * exp(-(1.0 - ch) * 4.0)
          * wThink * (0.55 + 0.45 * uActivity);

      // A radar sweep: whatever it passes over lights up and fades.
      float sweep = exp(-fract(sturn * 0.2 - th) * 5.0);

      // Tick dial, turning slowly.
      float td = th - sturn * 0.02;
      float dial = rh - 2.08;
      float fine = segs(td, 180.0, 0.25, aaT) * line(dial - 0.012, 0.012, aa);
      float major = segs(td + 0.0008, 12.0, 0.016, aaT) * line(dial - 0.026, 0.026, aa);
      col += mix(A, hot, sweep) * max(fine * 0.32, major * 0.85) * (0.55 + 1.3 * sweep + 0.3 * wThink);
      col += A * sweep * sweep * 0.05 * smoothstep(1.72, 1.9, rh) * (1.0 - smoothstep(2.0, 2.3, rh));

      // Motes drifting around the orb, each lane at its own pace.
      float lane = floor(rh * 5.0);
      float hl = hash11(lane + 11.0);
      float mt = th * 14.0 + uTime * (floor(hl * 7.0) - 3.0) * 0.025 * 14.0 / TAU;
      float mh = hash12(vec2(mod(floor(mt), 14.0), lane));
      vec2 md = vec2((fract(mt) - 0.2 - 0.6 * mh) * TAU * rh / 14.0, fract(rh * 5.0) / 5.0 - 0.04 - 0.12 * fract(mh * 7.3));
      float mote = (1.0 - smoothstep(0.004, 0.004 + 2.5 * aa, length(md))) * step(0.62, mh);
      col += mix(A, B, fract(mh * 3.7)) * mote * (0.25 + 0.3 * sin(uTime * (1.0 + floor(mh * 8.0) * 0.25) + mh * 40.0) + 0.4 * lvl * react);

      // Data track: cells that flip at random, alive while thinking.
      float cell = floor(fract(td) * 72.0);
      float bit = step(0.5 - 0.2 * uActivity, hash12(vec2(cell, floor(uSpin * 0.5 + hash11(cell) * 4.0))));
      float track = segs(td, 72.0, 0.78, aaT) * line(rh - 2.2, 0.016, aa);
      col += mix(A, B, 0.6) * track * (0.05 + bit * (0.07 + 0.7 * wThink));

      // Bracket arcs, turning the other way, and the thin circle they sit on.
      float tbk = th + sturn * 0.03;
      float arcs = segs(tbk, 3.0, 0.24, aaT);
      float ad = rh - 2.34;
      col += A * (line(ad, 0.022, aa) * 0.13 + line(abs(ad) - 0.022, 0.003, aa) * 0.8) * arcs;
      col += A * line(ad, 0.0015, aa) * (1.0 - arcs) * 0.2;
      // Cardinal marks.
      col += hot * segs(th + 0.004, 4.0, 0.008, aaT) * line(rh - 2.43, 0.022, aa) * 0.6;

      // A faint glow behind everything.
      col += A * 0.04 * exp(-r * 1.2);
    }
  } else if (compact < 0.5) {
    col += A * 0.04 * exp(-r * 1.2);
  }

  // Tone map (soft clip), fade out before the square's edge, dither against banding.
  col = 1.0 - exp(-col * 1.35);
  col *= 1.0 - smoothstep(0.92 * rMax, rMax, r);
  col += (hash12(frag * uPx) - 0.5) * (1.5 / 255.0) * step(1e-4, col.r + col.g + col.b);
  col = max(col, 0.0);
  float alpha = uCompact > 0.5 ? min(1.0, 1.5 * max(col.r, max(col.g, col.b))) : 0.0;
  fragColor = vec4(col, alpha);
}
