"""Where is a recipe look safe for skin? Sweeps the recipe numbers.

    python3 sweep.py

Builds recipe looks that nobody has written yet, across a grid of contrast,
brightness and saturation, and then across warmth, runs each through the
skin test with True Colour on, and prints where the verdict stays skin-true.
The tables in the rulebook ("Rules for new looks") come from this.

Tone uses the Python copy of the engine (recipe_model.skin_true, which
matches the Mac bake of the shipping looks). Warmth uses the white-balance
matrices fitted from the Mac bake of looks already in the app, scaled up and
down, since Core Image's own temperature filter only runs on a Mac. So the
warmth table is a guide; the gate on the Mac runner has the last word.
"""
import json
import sys
import tempfile
from multiprocessing import Pool
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix="skin-sweep-")]
import fixes as F                # noqa: E402
import recipe_model as RM        # noqa: E402

CONTRAST = [0.9, 1.0, 1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.4]
BRIGHTNESS = [-0.06, -0.04, -0.02, 0.0, 0.03, 0.06]
SATURATION = [0.7, 0.85, 1.0, 1.15, 1.3, 1.45]
SHORT = {"true": "ok", "tweak": "near", "rework": "BAD"}
EYE = np.eye(3, dtype=np.float32)


def verdicts(recipe, M):
    r = dict(recipe, vignette=0.0, bloom=0.0)
    cube = RM.apply_model(F.GRID, r, M, space="lightness", toe=F.TOE).reshape(F.N, F.N, F.N, 3).astype(np.float32)
    res, _ = F.measure({"id": "sweep", "recipe": r, "lut": cube}, (1.0, 0.75), small=True)
    mono = r["saturation"] < 0.35
    v = F.judge(res, mono)[0]
    return v["category"], F.judge(res, mono, "portraits75")[0]["category"], v["issues"][:2]


def tone_job(p):
    c, s, b = p
    return p, verdicts(dict(contrast=c, saturation=s, brightness=b), EYE)


def warmth_job(p):
    lid, k = p
    M = F.mired_scale(F.MATS[lid], k)
    return p, verdicts(dict(contrast=1.1, saturation=1.05, brightness=0.0), M)


if __name__ == "__main__":
    looks = {l["id"]: l for l in json.loads((HERE / "looks.json").read_text()) if l["recipe"]}
    grid = [(c, s, b) for s in SATURATION for c in CONTRAST for b in BRIGHTNESS]
    with Pool(4, initializer=F._init) as pool:
        tone = dict(pool.imap_unordered(tone_job, grid, chunksize=4))
        print("Tone: verdict at full strength / at the 75% default (neutral white balance)\n")
        for s in SATURATION:
            print(f"saturation {s:.2f}        brightness " + "".join(f"{b:>11.2f}" for b in BRIGHTNESS))
            for c in CONTRAST:
                print(f"  contrast {c:.2f}              " + "".join(
                    f"{SHORT[tone[(c, s, b)][0]] + '/' + SHORT[tone[(c, s, b)][1]]:>11s}" for b in BRIGHTNESS))
            print()
        # the warmest, the coolest and the most tinted looks in the app
        picks = sorted(looks, key=lambda i: looks[i]["recipe"]["temperature"])
        picks = [picks[0], picks[1], picks[-1], picks[-2]] + sorted(
            looks, key=lambda i: -abs(looks[i]["recipe"]["tint"]))[:3]
        scales = [0.5, 1.0, 1.5, 2.0, 2.5]
        warm = dict(pool.imap_unordered(warmth_job, [(i, k) for i in dict.fromkeys(picks) for k in scales]))
        print("Warmth: a mild tone (contrast 1.1, saturation 1.05) with each look's white balance scaled\n")
        for lid in dict.fromkeys(picks):
            r = looks[lid]["recipe"]
            print(f"{looks[lid]['name']} ({r['temperature']:.0f} K, tint {r['tint']:+.0f})")
            for k in scales:
                full, at75, issues = warm[(lid, k)]
                print(f"   x{k:.1f}  about {F.kelvin_for(k, r['temperature']):5.0f} K, tint {r['tint'] * k:+5.1f}:  "
                      f"{SHORT[full]}/{SHORT[at75]}  {', '.join(issues)}")
