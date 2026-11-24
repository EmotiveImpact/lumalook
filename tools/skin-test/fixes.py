"""Try the proposed fixes and measure them with the same yardstick.

    python3 fixes.py RENDER_DIR

1. Engine fix (recipe looks), as built in SkinTrueTone.swift: contrast and
   brightness run on lightness alone (on the gamma-encoded grey scale, pivot
   at mid grey, soft toe and shoulder), saturation scales Oklab chroma, so
   skin keeps its hue and chroma. Replaces CIColorControls in linear light.
2. Recipe tweaks: for recipe looks that still fail after the engine fix, a
   small search over contrast, saturation, brightness and the warmth shift.
3. Skin guard (film cubes): a hue-qualified correction baked into the cube
   that keeps skin hue, chroma and shadow depth close to the original while
   the rest of the frame keeps the look.
4. Safe intensity (film cubes): the highest intensity at which the look
   passes as it is.

Writes RENDER_DIR/fixes.json, thumbs for the fixed versions under
RENDER_DIR/thumbs_fix/<variant>/<look id>/ and guarded cubes under
RENDER_DIR/guarded_cubes/.
"""
import itertools
import json
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
from PIL import Image

import skinlib as S
import recipe_model as RM

RENDER = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "out" / "render"
ONLY = sys.argv[2:]
sys.argv = sys.argv[:1] + [str(RENDER)]
import run_test as T     # noqa: E402  (reads sys.argv for its RENDER)
import analyse as A      # noqa: E402

HERE = Path(__file__).resolve().parent
TOE = 0.2
MAX_EVAL = 45
N = 25
GRID = S.identity_cube(N).reshape(-1, 3)
MATS = json.loads((HERE / "out" / "tt_matrices.json").read_text())


# ---------------------------------------------------------------- recipes

def mired_scale(M, k):
    """Scale a look's white-balance shift by k (k=1 as is, 0 none). Done on the
    matrix, which for these modest shifts is close to scaling in mired."""
    I = np.eye(3, dtype=np.float32)
    return I + k * (np.asarray(M, np.float32) - I)


def kelvin_for(k, temp):
    m0 = 1e6 / 6500
    return 1e6 / (m0 + k * (1e6 / temp - m0))


def recipe_cube(look, r=None, space="lightness", toe=TOE, wb=1.0):
    r = dict(look["recipe"], **(r or {}))
    M = mired_scale(MATS[look["id"]], wb)
    return RM.apply_model(GRID, r, M, space=space, toe=toe).reshape(N, N, N, 3).astype(np.float32)


# ---------------------------------------------------------------- skin guard

def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


GUARD_SMOOTHING = 0.012     # TrueColour.guardSmoothing


def skin_hue(hue, chroma):
    """How much a colour's hue says "skin", 0 to 1 (TrueColour.skinHue). Fully
    inside 20 to 85 degrees; outside it fades over 15 degrees or over 8 Lab
    units of colour distance from that range, whichever is gentler."""
    by_angle = smoothstep(5, 20, hue) * (1 - smoothstep(85, 100, hue))
    off = np.abs(hue - 52.5)
    off = np.where(off > 180, 360 - off, off)
    outside = np.maximum(0, off - 32.5)
    distance = np.where(outside >= 90, chroma, chroma * np.sin(np.radians(np.minimum(outside, 90))))
    return np.maximum(by_angle, 1 - smoothstep(0, 8, distance))


def skin_guard(cube, strength=0.8):
    """Return a guarded copy of `cube` ([b][g][r] -> rgb, any size). A copy of
    TrueColour.guarded in the app; check_look.py --self-test compares the two.

    Skin is selected by the INPUT colour: Lab hue 20 to 85 degrees (feathered),
    chroma 4 to 70, lightness below 88. For those colours the guard works out
    the nearest colour that is still fair to the skin tone that went in:
      hue    within 6 degrees of it
      chroma between 0.85x and 1.2x of it
      depth  no darker than 0.8x its lightness in the shadows (L* < 45)
    and moves the look's output 80% of the way there, as a straight blend of
    colours (Lab a and b). Inside the tolerance the nearest fair colour is the
    look's own output, so nothing moves. The correction is then spread over
    neighbouring colours, so two colours side by side are never pulled apart."""
    from scipy.ndimage import gaussian_filter1d
    n = cube.shape[0]
    x = S.identity_cube(n).reshape(-1, 3)
    y = cube.reshape(-1, 3)
    lx, ly = S.srgb_to_lab(x).astype(np.float64), S.srgb_to_lab(y).astype(np.float64)
    Cx, Cy = np.hypot(lx[:, 1], lx[:, 2]), np.hypot(ly[:, 1], ly[:, 2])
    hx = np.degrees(np.arctan2(lx[:, 2], lx[:, 1]))
    hy = np.degrees(np.arctan2(ly[:, 2], ly[:, 1]))
    w = (skin_hue(hx, Cx)
         * smoothstep(3, 8, Cx) * (1 - smoothstep(60, 75, Cx))
         * (1 - smoothstep(85, 92, lx[:, 0])))
    w = w * strength
    # the nearest fair colour: up to 6 degrees of the look's hue shift, less
    # where its hue says nothing reliable (opposite the skin tone, or grey)
    dh = (hy - hx + 180) % 360 - 180
    ratio = Cy / np.maximum(Cx, 1e-3)
    kept = np.clip(dh, -6, 6) * (1 - smoothstep(90, 180, np.abs(dh))) * smoothstep(0.1, 0.4, ratio)
    h_fair = np.radians(hx + kept)
    C_fair = Cx * np.clip(ratio, 0.85, 1.2)
    a = ly[:, 1] + w * (C_fair * np.cos(h_fair) - ly[:, 1])
    b = ly[:, 2] + w * (C_fair * np.sin(h_fair) - ly[:, 2])
    # depth: in the shadows do not let skin drop below 0.8x its lightness
    floor = lx[:, 0] * 0.8
    shadow = 1 - smoothstep(35, 50, lx[:, 0])
    L_new = np.where(ly[:, 0] < floor, ly[:, 0] + (floor - ly[:, 0]) * w * shadow, ly[:, 0])
    out = np.clip(S.lab_to_srgb(np.stack([L_new, a, b], -1).astype(np.float32)), 0, 1)
    if GUARD_SMOOTHING <= 0:
        return np.where((w > 0)[:, None], out, y).reshape(cube.shape).astype(np.float32)
    # Spread the correction over neighbouring colours. A look may store values
    # a little outside 0..1; bringing those into range is not a correction,
    # so the correction is measured from the colour as a screen shows it.
    shown = np.clip(y, 0, 1)
    delta = (np.where((w > 0)[:, None], out, shown) - shown).reshape(cube.shape).astype(np.float64)
    for axis in range(3):
        delta = gaussian_filter1d(delta, GUARD_SMOOTHING * (n - 1), axis=axis, mode="nearest", truncate=3.0)
    return np.where(np.any(delta != 0, -1, keepdims=True),
                    np.clip(shown.reshape(cube.shape) + delta, 0, 1), cube).astype(np.float32)


def resample(cube, n, clip=True):
    """`cube` on an n-point lattice. clip=False keeps values outside 0..1, as
    the app's own densify does (LUTDensifier)."""
    g = S.identity_cube(n)
    return S.sample_tetra(cube, g, clip=clip).astype(np.float32)


# ---------------------------------------------------------------- measuring

_IMS = _MASKS = _LOOKS = _SMALL = None


def _init():
    global _IMS, _MASKS, _LOOKS, _SMALL
    _IMS, _MASKS = T.load_portraits()
    _LOOKS = {l["id"]: l for l in S.load_looks()}
    # half-size copies for the parameter search (results confirmed full size)
    _SMALL = ({k: np.asarray(Image.fromarray((v * 255 + 0.5).astype(np.uint8)).resize((270, 338), Image.LANCZOS)
                             ).astype(np.float32) / 255 for k, v in _IMS.items()},
              {k: np.asarray(Image.fromarray(m.astype(np.uint8) * 255).resize((270, 338), Image.NEAREST)) > 127
               for k, m in _MASKS.items()})


def measure(look, intensities=(1.0, 0.75), thumbs=None, small=False):
    ims, masks = _SMALL if small else (_IMS, _MASKS)
    res = {}
    for it in intensities:
        key = "portraits" if it == 1.0 else f"portraits{int(round(it * 100))}"
        res[key] = {}
    if thumbs:
        thumbs.mkdir(parents=True, exist_ok=True)
    for pid, im in ims.items():
        full = S.grade(im, look, 1.0)
        lin_full, lin_in = S.srgb_to_lin(full), S.srgb_to_lin(im)
        for it in intensities:
            out = full if it == 1.0 else S.lin_to_srgb(lin_in * (1 - it) + lin_full * it)
            key = "portraits" if it == 1.0 else f"portraits{int(round(it * 100))}"
            res[key][pid] = T.skin_stats(im, out, masks[pid])
        if thumbs:
            Image.fromarray((full * 255 + 0.5).astype(np.uint8)).resize(T.THUMB, Image.LANCZOS).save(
                thumbs / f"{pid}.jpg", quality=88)
    ch = S.sample_tetra(look["lut"], T.CHART)
    res["chart"] = T.chart_stats(T.CHART, ch)
    return res, ch


def judge(res, mono_hint=None, key="portraits"):
    mono, per = A.summarise(res, key, mono_hint)
    cf = A.chart_flags(res["chart"], mono)
    return A.verdict(per, cf, mono), mono


def brief(v):
    return {k: v[k] for k in ("category", "score", "bad_main", "warn_main", "bad_neon", "chart_bad", "stress_lost", "issues")}


# ---------------------------------------------------------------- jobs

def job_recipe(look_id):
    look = dict(_LOOKS[look_id])
    out = {"id": look_id, "kind": "recipe"}
    # as shipped (re-measured so every row uses the same code path)
    v0, _ = judge(measure(look, (1.0,))[0])
    out["now"] = brief(v0)
    # recipes say what they are: no saturation is black and white, anything
    # else is judged as colour (a bleach bypass still has to keep skin warm)
    mono = look["recipe"]["saturation"] < 0.35
    # engine fix
    fixed = dict(look, lut=recipe_cube(look))
    res, ch = measure(fixed, (1.0, 0.75), RENDER / "thumbs_fix" / "engine" / look_id)
    np.save(RENDER / "chart_fix" / f"engine_{look_id}.npy", ch)
    v1, _ = judge(res, mono)
    out["engine"] = brief(v1)
    out["engine75"] = brief(judge(res, mono, "portraits75")[0])
    # engine fix + recipe tweak, only if still not skin-true
    if v1["category"] != "true":
        r = look["recipe"]
        best = None
        cs = sorted({r["contrast"], *[c for c in (1.0, 1.05, 1.1, 1.15, 1.2) if c <= r["contrast"]]})
        if mono:
            ss = [r["saturation"]]
        elif r["saturation"] < 0.85:
            # deliberately muted looks may give a little colour back to skin
            ss = sorted({r["saturation"], round(min(0.9, r["saturation"] + 0.1), 2),
                         round(min(0.9, r["saturation"] + 0.2), 2)})
        else:
            ss = sorted({r["saturation"], *[s for s in (0.9, 1.0, 1.05, 1.1) if s <= r["saturation"]]})
        bs = sorted({r["brightness"], *[b for b in (0.0, -0.01) if abs(b) <= abs(r["brightness"]) or r["brightness"] > 0]})
        wbs = [1.0, 0.7, 0.5] if (r["temperature"] != 6500 or r["tint"] != 0) else [1.0]
        vigs = sorted({r["vignette"], min(r["vignette"], 0.3)})
        cands = []
        for c, s_, b, wb, vg in itertools.product(cs, ss, bs, wbs, vigs):
            # distance from the original recipe: prefer the smallest change
            dist = (abs(c - r["contrast"]) / 0.05 + abs(s_ - r["saturation"]) / (0.1 if s_ > r["saturation"] else 0.05)
                    + abs(b - r["brightness"]) / 0.01 + (1 - wb) / 0.3 + abs(vg - r["vignette"]) / 0.2)
            cands.append((dist, c, s_, b, wb, vg))
        cands.sort()
        for n_eval, (dist, c, s_, b, wb, vg) in enumerate(cands):
            if n_eval >= MAX_EVAL or (best and best[1]["category"] == "true"):
                break
            if dist == 0:
                continue          # that is the engine-fix result already measured
            cand_r = dict(contrast=c, saturation=s_, brightness=b, vignette=vg)
            cand = dict(look, lut=recipe_cube(look, cand_r, wb=wb), recipe=dict(r, **cand_r))
            v, _ = judge(measure(cand, (1.0,), small=True)[0], mono)
            rank = (0 if v["category"] == "true" else 1 if v["category"] == "tweak" else 2, v["score"] + 0.5 * dist)
            if best is None or rank < best[2]:
                best = (dist, v, rank, dict(cand_r, wb=wb))
        if best is None:
            best = (0, v1, None, dict(contrast=r["contrast"], saturation=r["saturation"],
                                      brightness=r["brightness"], vignette=r["vignette"], wb=1.0))
        dist, v, rank, p = best
        params = dict(contrast=p["contrast"], saturation=p["saturation"], brightness=p["brightness"],
                      vignette=p["vignette"], wb_scale=p["wb"],
                      temperature=round(kelvin_for(p["wb"], r["temperature"]) / 50) * 50 if r["temperature"] != 6500 else 6500,
                      tint=round(r["tint"] * p["wb"], 1))
        if dist > 0:
            # confirm at full size, and keep thumbs and chart for the sheets
            cr = {k: p[k] for k in ("contrast", "saturation", "brightness", "vignette")}
            tl = dict(look, lut=recipe_cube(look, cr, wb=p["wb"]), recipe=dict(r, **cr))
            res, ch = measure(tl, (1.0,), RENDER / "thumbs_fix" / "tweak" / look_id)
            np.save(RENDER / "chart_fix" / f"tweak_{look_id}.npy", ch)
            v = judge(res, mono)[0]
            out["tweak"] = dict(brief(v), params=params)
        else:
            out["tweak"] = dict(brief(v1), params=params, none_found=True)
    return out


def job_cube(look_id):
    look = dict(_LOOKS[look_id])
    out = {"id": look_id, "kind": "film cube"}
    res0, _ = measure(look, (1.0, 0.9, 0.75, 0.6, 0.5))
    v0, mono = judge(res0)
    out["now"] = brief(v0)
    safe = None
    for it, key in ((1.0, "portraits"), (0.9, "portraits90"), (0.75, "portraits75"),
                    (0.6, "portraits60"), (0.5, "portraits50")):
        v, _ = judge(res0, mono, key)
        out[f"at{int(it * 100)}"] = v["category"]
        if v["category"] == "true" and safe is None:
            safe = it
    out["safe_intensity"] = safe
    if v0["category"] != "true" and not mono:
        g = skin_guard(resample(look["lut"], N))
        guarded = dict(look, lut=g)
        res, ch = measure(guarded, (1.0, 0.75), RENDER / "thumbs_fix" / "guard" / look_id)
        np.save(RENDER / "chart_fix" / f"guard_{look_id}.npy", ch)
        out["guard"] = brief(judge(res, mono)[0])
        out["guard75"] = brief(judge(res, mono, "portraits75")[0])
        np.save(RENDER / "guarded_cubes" / f"{look_id}.npy", g)
    elif v0["category"] != "true" and mono:
        # mono: the problems are tonal (crush, darkening); try a shadow floor
        g = mono_floor(resample(look["lut"], N))
        res, ch = measure(dict(look, lut=g), (1.0, 0.75), RENDER / "thumbs_fix" / "guard" / look_id)
        np.save(RENDER / "chart_fix" / f"guard_{look_id}.npy", ch)
        out["guard"] = brief(judge(res, True)[0])
        out["guard75"] = brief(judge(res, True, "portraits75")[0])
        np.save(RENDER / "guarded_cubes" / f"{look_id}.npy", g)
    return out


def mono_floor(cube, strength=0.8):
    """For black-and-white cubes: lift only the deepest tones so that a face
    in shadow keeps separation, leaving mid-tones and highlights as they are."""
    n = cube.shape[0]
    x = S.identity_cube(n).reshape(-1, 3)
    y = cube.reshape(-1, 3)
    Lx, Ly = S.srgb_to_lab(x)[:, 0], S.srgb_to_lab(y)
    floor = Lx * 0.8
    shadow = 1 - S_smooth(30, 50, Lx)
    L_new = np.where(Ly[:, 0] < floor, Ly[:, 0] + (floor - Ly[:, 0]) * strength * shadow, Ly[:, 0])
    out = S.lab_to_srgb(np.stack([L_new, Ly[:, 1], Ly[:, 2]], -1).astype(np.float32))
    return out.reshape(cube.shape).astype(np.float32)


S_smooth = smoothstep


def job(look_id):
    look = _LOOKS[look_id]
    return job_recipe(look_id) if look.get("recipe") else job_cube(look_id)


if __name__ == "__main__":
    for d in ("chart_fix", "guarded_cubes", "thumbs_fix"):
        (RENDER / d).mkdir(parents=True, exist_ok=True)
    ids = [l["id"] for l in json.loads((HERE / "looks.json").read_text())]
    if ONLY == ["@recipes"]:
        ids = [l["id"] for l in json.loads((HERE / "looks.json").read_text()) if l["recipe"]]
    elif ONLY:
        ids = [i for i in ids if any(s in i for s in ONLY)]
    cubes = {l["id"]: l["cube"] for l in json.loads((HERE / "looks.json").read_text())}
    ids = [i for i in ids if cubes[i] or S.before_bake(i).exists()]   # recipes added since have no "before" to fix
    results = {}
    if ONLY and (RENDER / "fixes.json").exists():
        results = json.loads((RENDER / "fixes.json").read_text())
    with Pool(4, initializer=_init) as pool:
        for i, r in enumerate(pool.imap_unordered(job, ids)):
            results[r["id"]] = r
            print(f"{i + 1}/{len(ids)} {r['id']:36s} now {r['now']['category']:6s} "
                  + (f"engine {r['engine']['category']:6s} " if "engine" in r else "")
                  + (f"tweak {r['tweak']['category']:6s} {r['tweak']['params']} " if "tweak" in r else "")
                  + (f"safe {r.get('safe_intensity')} guard {r['guard']['category']}" if "guard" in r else
                     (f"safe {r.get('safe_intensity')}" if r["kind"] == "film cube" else "")), flush=True)
    (RENDER / "fixes.json").write_text(json.dumps(results, indent=1))
