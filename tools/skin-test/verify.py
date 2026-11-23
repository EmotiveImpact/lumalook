"""Verify the True Colour build on the real Core Image bake.

    python3 verify.py RENDER_DIR

Reads the Mac runner's bake of the shipping engine (out/luts_tc,
out/luts_classic, out/film_tc, from bake_truecolour.swift) and judges every
look with the same yardstick as the skin test:

  on    True Colour on (the default): recipe tone on lightness, film cubes
        with the skin guard
  off   True Colour off: classic per-channel tone, film cubes as authored
  before  the verdict as the looks shipped (RENDER_DIR/verdicts.json)

Also checks the research thread's pass targets on the Monk chart (daylight,
normal exposure): Monk 10 keeps at least 0.20 Oklab L on every look, and at
the 75% default deep skin (Monk 8 to 10) keeps hue within 5 degrees, chroma
between 0.85x and 1.2x and lightness within 0.06.

Writes RENDER_DIR/verify.json and thumbs under RENDER_DIR/thumbs_tc/<id>/.
"""
import json
import os
import sys
from pathlib import Path
from collections import Counter
from multiprocessing import Pool

import numpy as np

import fixes as F          # reads RENDER_DIR from argv
import recipe_model as RM
import skinlib as S
import run_test as T

RENDER = F.RENDER
OUT = Path(os.environ.get("VERIFY_BAKE", F.HERE / "out"))
DEEP = [4, 5, 6]           # MST8, MST9, MST10 in T.MONK order


def oklch(rgb):
    lab = RM.oklab(S.srgb_to_lin(rgb).astype(np.float64))
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1]))


def targets(look):
    """Research targets on the Monk chart, daylight at normal exposure."""
    src = T.CHART[0, :, 1]                              # (tones, 3)
    full = S.sample_tetra(look["lut"], src)
    lin75 = S.srgb_to_lin(src) * 0.25 + S.srgb_to_lin(full) * 0.75
    at75 = S.lin_to_srgb(lin75)
    L0, C0, h0 = oklch(src[DEEP])
    L1, C1, h1 = oklch(at75[DEEP])
    Lf, _, _ = oklch(full)
    dh = (h1 - h0 + 180) % 360 - 180
    mono = look.get("_mono", False)
    return dict(
        mst10_L=round(float(Lf[6]), 3),
        mst10_ok=bool(Lf[6] >= 0.20),
        hue_drift=round(float(np.abs(dh).max()), 1),
        chroma_ratio=[round(float(x), 2) for x in (C1 / np.maximum(C0, 1e-6))],
        dL=[round(float(x), 3) for x in (L1 - L0)],
        hue_ok=bool(mono or np.abs(dh).max() < 5),
        chroma_ok=bool(mono or np.all((C1 / C0 >= 0.85) & (C1 / C0 <= 1.2))),
        light_ok=bool(np.all(np.abs(L1 - L0) <= 0.06)),
    )


def job(lid):
    look = dict(F._LOOKS[lid])
    out = {"id": lid, "kind": "recipe" if look["recipe"] else "film cube"}
    variants = {}
    if look["recipe"]:
        mono = look["recipe"]["saturation"] < 0.35
        variants["on"] = S.read_baked(OUT / "luts_tc" / f"{lid}.u16")
        variants["off"] = S.read_baked(OUT / "luts_classic" / f"{lid}.u16")
    else:
        mono = None
        variants["on"] = S.read_baked(OUT / "film_tc" / f"{lid}.u16")
        variants["off"] = look["lut"]
    for name, lut in variants.items():
        lk = dict(look, lut=lut)
        thumbs = RENDER / "thumbs_tc" / lid if name == "on" else None
        res, ch = F.measure(lk, (1.0, 0.75), thumbs)
        if name == "on":
            np.save(RENDER / "chart_fix" / f"tc_{lid}.npy", ch)
        v, m = F.judge(res, mono)
        if mono is None and name == "off":
            mono = m
        out[name] = F.brief(v)
        out[name + "75"] = F.brief(F.judge(res, m, "portraits75")[0])
        out[name + "_targets"] = targets(dict(lk, _mono=m))
    return out


if __name__ == "__main__":
    (RENDER / "chart_fix").mkdir(parents=True, exist_ok=True)
    before = {v["id"]: v for v in json.loads((RENDER / "verdicts.json").read_text())}
    ids = [l["id"] for l in json.loads((F.HERE / "looks.json").read_text())]
    res = {}
    if F.ONLY:      # re-check a few looks, keep the rest of the last run
        ids = [i for i in ids if any(s in i for s in F.ONLY)]
        res = json.loads((RENDER / "verify.json").read_text())
    with Pool(4, initializer=F._init) as p:
        for r in p.imap_unordered(job, ids):
            r["before"] = F.brief(before[r["id"]]) if r["id"] in before else None
            res[r["id"]] = r
            print(f"{r['id']:34s} before {r['before']['category'] if r['before'] else '?':6s} "
                  f"on {r['on']['category']:6s} {r['on']['bad_main']}/{r['on']['warn_main']}  "
                  f"off {r['off']['category']:6s}  on75 {r['on75']['category']:6s} "
                  f"mst10 {r['on_targets']['mst10_L']}", flush=True)
    (RENDER / "verify.json").write_text(json.dumps(res, indent=1))
    for kind in ("recipe", "film cube", None):
        sel = [r for r in res.values() if kind is None or r["kind"] == kind]
        print(f"\n{kind or 'all'} ({len(sel)})")
        for k in ("before", "on", "on75", "off", "off75"):
            rows = [r[k] for r in sel if r.get(k)]
            print(f"  {k:6s}", dict(Counter(x["category"] for x in rows)),
                  "bad main frames", sum(x["bad_main"] for x in rows))
        for k in ("on_targets", "off_targets"):
            t = [r[k] for r in sel]
            print(f"  {k}: mst10>=0.20 {sum(x['mst10_ok'] for x in t)}/{len(t)}, "
                  f"hue<5 {sum(x['hue_ok'] for x in t)}, chroma {sum(x['chroma_ok'] for x in t)}, "
                  f"lightness {sum(x['light_ok'] for x in t)}")
