#!/usr/bin/env python3
"""Renders the DisplAI app icon: the presence orb (a numpy port of shaders/presence.frag)
inside a macOS-style rounded square, and writes every size of the macOS AppIcon set.

Run from app/: python3 tool/make_icon.py [--preview out.png]
Needs numpy and Pillow.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

TAU = 2 * np.pi
ACCENT = np.array([0x4F, 0xD8, 0xFF]) / 255.0

# A frozen moment of the orb: speaking, with a lively spectrum.
TIME = 5.3
SPIN = 9.0
LEVEL = 0.45
BANDS = np.array([0.55, 0.85, 0.7, 0.95, 0.6, 0.8, 0.5, 0.65])
W_IDLE, W_LISTEN, W_THINK, W_SPEAK = 0.0, 0.0, 0.25, 0.75
ACTIVITY = 0.4
SCREEN_R = 0.18  # sphere radius on screen, in units of the tile side
LINE = 2.4  # ring and grid lines are thicker than on screen, so they survive Dock sizes


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def line(d, w, aa):
    return 1.0 - smoothstep(w, w + aa, np.abs(d))


def fract(x):
    return x - np.floor(x)


def segs(turn, n, duty, aa_t):
    f = fract(turn * n)
    e = np.clip(aa_t * n, 1e-4, 0.5 * duty)
    return smoothstep(0.0, e, f) * (1.0 - smoothstep(duty - e, duty, f))


def band_at(t):
    x = np.clip(t, 0.0, 1.0) * 7.0
    out = np.zeros_like(x)
    for k in range(8):
        out += np.maximum(1.0 - np.abs(x - k), 0.0) * BANDS[k]
    return out


def rot_x(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_y(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def field(q, t):
    w = q + 0.45 * np.sin(q[:, [1, 2, 0]] * 2.3 + t * np.array([0.9, 1.1, 0.7]))
    return np.sin(w[:, 0] * 3.1 + t) * np.sin(w[:, 1] * 2.7 - t * 1.3) * np.sin(w[:, 2] * 3.4 + t * 0.8)


def render(res):
    """The orb with its backdrop, as linear-ish RGB floats, res x res."""
    ys, xs = np.mgrid[0:res, 0:res].astype(np.float64)
    p = np.stack([(xs + 0.5) / res - 0.5, -((ys + 0.5) / res - 0.5)], -1).reshape(-1, 2)
    n_px = p.shape[0]
    px = 1.0 / res
    lvl = LEVEL
    react = min(W_LISTEN + W_SPEAK, 1.0)

    ro = np.concatenate([p / SCREEN_R, np.full((n_px, 1), 4.5)], 1)
    rd = np.array([0.0, 0.0, -1.0])
    px_w = px / SCREEN_R
    m = rot_x(0.42 + 0.08 * np.sin(SPIN * 0.09)) @ rot_y(TIME * 0.06 + SPIN * 0.04)

    shell_r = 1.0 + 0.012 * np.sin(TIME * 1.4) * (W_IDLE + W_LISTEN) + 0.045 * lvl * react
    r2 = ro[:, 0] ** 2 + ro[:, 1] ** 2
    h = shell_r**2 - r2
    hit = h >= 0
    sq = np.sqrt(np.maximum(h, 0))
    hs_x, hs_y = 4.5 - sq, 4.5 + sq

    col = np.zeros((n_px, 3))
    light = np.array([-0.55, 0.7, 0.55])
    light /= np.linalg.norm(light)
    cool = ACCENT * 0.55 + np.array([0.45, 0.55, 1.0]) * 0.45

    idx = np.nonzero(hit)[0]
    if idx.size:
        ro_h = ro[idx]
        t0 = hs_x[idx]
        dt = (hs_y[idx] - t0) / 22.0
        tt = TIME * (0.55 + 1.6 * W_THINK + 0.6 * W_SPEAK)
        core_r = 0.27 + 0.14 * lvl * react + 0.025 * np.sin(TIME * 1.9) + 0.05 * W_THINK
        acc = np.zeros((idx.size, 3))
        for i in range(22):
            q = ro_h + rd[None, :] * (t0 + (i + 0.5) * dt)[:, None]
            qo = q @ m.T
            r = np.linalg.norm(q, axis=1)
            f = field(qo * 1.35, tt)
            x = r / core_r
            dens = np.exp(-x * x * 2.0) * (0.6 + 0.4 * f) + np.exp(-x * x * 9.0) * 1.5
            az = np.arctan2(qo[:, 2], qo[:, 0]) / TAU + 0.5
            band = band_at(np.abs(fract(az * 2.0) * 2.0 - 1.0))
            shell_d = (r - 0.6) / 0.17
            dens += react * band * 0.9 * np.exp(-shell_d * shell_d) * (0.55 + 0.45 * f)
            fil = np.exp(-np.abs(f) * 18.0) * (1.0 - smoothstep(0.2, 0.6, r)) * (0.3 + 0.4 * W_THINK)
            k = smoothstep(0.0, 0.5, dens)[:, None]
            c = cool * (1 - k) + ACCENT * k
            k2 = smoothstep(0.55, 1.1, dens)[:, None]
            c = c * (1 - k2) + k2
            acc += c * (dens * 2.6 + fil)[:, None] * dt[:, None]
        col[idx] += acc * (1.0 + 0.5 * W_THINK + 0.8 * lvl * W_SPEAK)

        for s in range(2):
            t = hs_x[idx] if s == 0 else hs_y[idx]
            n = ro_h + rd[None, :] * t[:, None]
            n /= np.linalg.norm(n, axis=1)[:, None]
            qo = n @ m.T
            lat = np.arcsin(np.clip(qo[:, 1], -1, 1))
            lon = np.arctan2(qo[:, 2], qo[:, 0])
            g_step = np.pi / 7.0
            d_lat = np.abs(fract(lat / g_step + 0.5) - 0.5) * g_step
            d_lon = np.abs(fract(lon / g_step + 0.5) - 0.5) * g_step * np.cos(lat)
            view = np.abs(n @ rd)
            aa_g = LINE * px_w / shell_r / np.maximum(view, 0.25)
            g = np.maximum(line(d_lat, 0.0015 * LINE, aa_g), line(d_lon, 0.0015 * LINE, aa_g) * smoothstep(0.0, 0.35, np.cos(lat)))
            lit = 0.04 + 0.3 * react * band_at(fract(lon / TAU + 0.5))
            sweep = np.sin(TIME * 1.6) * 1.2
            sw = np.exp(-np.abs(lat - sweep) * 18.0) * W_THINK * 0.55
            side = 1.0 if s == 0 else 0.3
            col[idx] += ACCENT * ((g * lit + sw * (0.3 + 0.7 * g)) * side)[:, None]

        n = ro_h + rd[None, :] * hs_x[idx][:, None]
        n /= np.linalg.norm(n, axis=1)[:, None]
        ndv = np.maximum(n @ -rd, 0.0)
        fres = (1.0 - ndv) ** 3
        k = (smoothstep(0.2, 0.9, 1.0 - ndv) * 0.45)[:, None]
        rim = ACCENT * (1 - k) + np.array([0.62, 0.45, 1.0]) * k
        col[idx] += rim * (fres * (0.75 + 0.9 * lvl * react + 0.3 * W_THINK))[:, None]
        hv = light - rd
        hv /= np.linalg.norm(hv)
        col[idx] += (np.maximum(n @ hv, 0.0) ** 90 * 0.85)[:, None]
        b = np.array([0.3, -0.8, 0.4])
        b /= np.linalg.norm(b)
        col[idx] += ACCENT * (np.maximum(n @ b, 0.0) ** 6 * 0.12)[:, None]

    d_ray = np.sqrt(r2)
    halo = np.exp(-np.maximum(d_ray - shell_r, 0.0) * 5.0) * (~hit)
    col += ACCENT * (halo * 0.2 * (1.0 + 1.2 * lvl * react + 0.4 * W_THINK))[:, None]

    for i in range(6):
        fi = float(i)
        polar = 1.0 if i == 4 else 0.0
        dir_o = 1.0 - 2.0 * ((i // 2) % 2)
        tilt = (0.30 + 0.05 * fi) * (1 - polar) + 1.12 * polar + (0.10 + 0.08 * polar) * np.sin(
            SPIN * (0.11 + 0.02 * fi) + fi * 2.0
        )
        yaw = 1.5708 + ((fi % 2) - 0.5) * 0.6 + polar * 0.9 + SPIN * dir_o * (0.07 + 0.025 * fi + 0.1 * polar)
        nrm = np.array([np.sin(tilt) * np.cos(yaw), np.cos(tilt), np.sin(tilt) * np.sin(yaw)])
        nrm /= np.linalg.norm(nrm)
        u = np.cross(nrm, [0.0, 0.0, 1.0])
        u /= np.linalg.norm(u)
        v = np.cross(nrm, u)
        dn = rd @ nrm
        dn = dn if abs(dn) >= 1e-4 else 1e-4
        t = -(ro @ nrm) / dn
        ok = t > 0
        q = ro + rd[None, :] * t[:, None]
        rr = np.linalg.norm(q, axis=1)
        ang = np.arctan2(q @ v, q @ u) / TAU + 0.5
        aa = px_w / max(abs(dn), 0.18)
        aa_t = aa / (TAU * np.maximum(rr, 1e-3))
        ring_r = 1.28 + 0.17 * fi + polar * 0.1
        d = rr - ring_r
        direction = 1.0 - 2.0 * (i % 2)
        spin = SPIN * direction * (0.045 - 0.005 * fi)
        if i == 0:
            runners = segs(ang + spin * 2.5, 2.0, 0.07 + 0.05 * W_THINK, aa_t)
            mk = line(d, 0.005 * LINE, aa) * 0.5 + line(d, 0.011 * LINE, aa) * runners * 1.1
        elif i == 1:
            ticks = segs(ang + spin, 90.0, 0.3, aa_t) * line(d, 0.02 * LINE, aa)
            major = segs(ang + spin + 0.002, 12.0, 0.02, aa_t) * line(d, 0.04 * LINE, aa)
            mk = np.maximum(ticks * 0.42, major * 0.9)
        elif i == 2:
            ln = 0.012 + band_at(np.abs(fract(ang * 2.0) * 2.0 - 1.0)) * 0.13 + lvl * 0.02
            db = d - 0.5 * ln
            mk = segs(ang + spin, 72.0, 0.4, aa_t) * line(db, 0.5 * ln * LINE, aa) * (0.18 + 0.7 * react)
        elif i == 3:
            arcs = segs(ang + spin, 3.0, 0.22, aa_t)
            w = 0.026 * 1.4
            mk = (line(d, w, aa) * 0.2 + line(np.abs(d) - w, 0.004 * LINE, aa) * 0.9) * arcs
        elif i == 4:
            head = fract(ang + spin * 3.0)
            tail = np.exp(-(1.0 - head) * 7.0)
            mk = line(d, 0.004 * LINE, aa) * (0.22 + 0.9 * tail)
        else:
            dashes = segs(ang + spin, 120.0, 0.45, aa_t) * line(d, 0.003 * LINE, aa) * 0.35
            brackets = segs(ang + spin + 0.1, 2.0, 0.16, aa_t) * line(d + 0.025, 0.006 * LINE, aa) * 0.8
            mk = dashes + brackets
        behind = (hit & (hs_x <= t)).astype(np.float64)
        rc = ACCENT[None, :] * (1 - behind)[:, None] + cool[None, :] * behind[:, None]
        gain = (1.0 - 0.7 * behind) * (0.85 + 0.25 * W_THINK + 0.3 * lvl * react)
        col += rc * (mk * gain * ok)[:, None]

    col = 1.0 - np.exp(-col * 1.4)

    # Backdrop: near black with a faint accent glow (no motes: they read as noise at icon size).
    r = np.linalg.norm(p, axis=1)
    top = np.clip(0.5 + p[:, 1], 0, 1)[:, None]  # 0 at the bottom edge, 1 at the top
    bg = np.array([0.012, 0.02, 0.035])[None, :] * (1 - top) + np.array([0.03, 0.06, 0.09])[None, :] * top
    bg = bg + ACCENT[None, :] * (0.13 * np.exp(-r * 3.2))[:, None]
    bg *= (1.0 - 0.35 * smoothstep(0.35, 0.75, r))[:, None]
    out = bg + col * (1.0 - bg)
    return out.reshape(res, res, 3)


def squircle_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def icon(canvas=2048):
    """macOS icon grid: an 824/1024 tile with ~185/1024 corners and a soft drop shadow."""
    tile = round(canvas * 824 / 1024)
    rgb = np.clip(render(tile), 0, 1)
    orb = Image.fromarray((rgb * 255 + 0.5).astype(np.uint8), "RGB")

    mask = squircle_mask(tile, round(tile * 185 / 824))
    # A thin light rim on the tile edge, brighter at the top.
    rim = Image.new("L", (tile, tile), 0)
    w = max(2, tile // 300)
    ImageDraw.Draw(rim).rounded_rectangle(
        [w // 2, w // 2, tile - 1 - w // 2, tile - 1 - w // 2], radius=round(tile * 185 / 824), outline=255, width=w
    )
    fade = np.linspace(0.55, 0.12, tile)[:, None] * np.ones((1, tile))
    rim_a = (np.asarray(rim, np.float64) / 255.0 * fade)[..., None]
    o = np.asarray(orb, np.float64) / 255.0
    o = o + (1 - o) * rim_a * (0.6 + 0.4 * ACCENT)
    orb = Image.fromarray((np.clip(o, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")

    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    off = (canvas - tile) // 2
    shadow = Image.new("L", (canvas, canvas), 0)
    shadow.paste(mask, (off, off + canvas // 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(canvas / 60))
    out.putalpha(ImageChops.multiply(shadow, Image.new("L", (canvas, canvas), 110)))
    layer = orb.convert("RGBA")
    layer.putalpha(mask)
    out.alpha_composite(layer, (off, off))
    return out


def main():
    big = icon(2048)
    master = big.resize((1024, 1024), Image.LANCZOS)
    if "--preview" in sys.argv:
        master.save(sys.argv[sys.argv.index("--preview") + 1])
        return
    root = Path(__file__).resolve().parent.parent
    icon_set = root / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    names = {img["filename"] for img in json.loads((icon_set / "Contents.json").read_text())["images"]}
    for name in sorted(names):
        size = int(name.removeprefix("app_icon_").removesuffix(".png"))
        master.resize((size, size), Image.LANCZOS).save(icon_set / name)
        print("wrote", icon_set / name)


if __name__ == "__main__":
    main()
