"""Lumalook's own black-and-white film looks, made from a few numbers.

    python3 make_mono_cube.py              write every look below into the app (LumaLook/Resources/FilmLUTs)
    python3 make_mono_cube.py --to DIR     write them into DIR instead, to try them first

A black-and-white look is two choices:

  1. Sensitivity: how light each colour comes out. Three weights, for red,
     green and blue light. More red makes skin lighter and skies darker (a
     photographer's orange filter); more blue does the opposite.
  2. The tone curve: a handful of points from black to white, joined
     smoothly. A steep middle is a hard, pushed look; a long gentle curve is
     a soft one.

The cube it writes is a plain .cube file with the standard input range, like
the film LUTs in the app, so True Colour treats it the same way (the shadow
floor for black-and-white looks) and the skin test can read it. Try a new
look before it goes in:

    python3 make_mono_cube.py --to /tmp/try
    python3 check_look.py /tmp/try/FS_PM800.cube --sheet try.jpg

The file name starts with FS_ like every pack film look: the app leaves FS_
files to their pack, and copies any other bundled cube into a new library as
a basic LUT (LUTRepository.seedBundledLUTsIfNeeded).
"""
import argparse
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator

import skinlib as S

# 17 points a side is enough: the look is smooth, and read back between the
# points it stays within 1 of 255 of the exact curve everywhere.
POINTS = 17

LOOKS = {
    # Press Mono 800: a press look, pushed hard. Orange-filter sensitivity
    # keeps Black and brown skin luminous while skies and blues go dark; the
    # middle of the curve is steep, the toe is short but never closes, and the
    # highlights run bright without clipping.
    "FS_PM800.cube": {
        "title": "Lumalook Press Mono 800",
        "weights": (0.55, 0.40, 0.05),
        "curve": [(0.00, 0.012), (0.10, 0.052), (0.20, 0.135), (0.30, 0.260), (0.40, 0.425), (0.50, 0.610),
                  (0.60, 0.765), (0.70, 0.870), (0.80, 0.935), (0.90, 0.972), (1.00, 0.992)],
    },
}


def make(look, n=POINTS):
    """The look as an n x n x n cube of display colours (grey values), indexed
    [blue][green][red] like every cube in skinlib."""
    w = np.array(look["weights"], np.float64)
    w = w / w.sum()
    xs, ys = zip(*look["curve"])
    curve = PchipInterpolator(xs, ys)                     # smooth, and never overshoots its points
    lin = S.srgb_to_lin(S.identity_cube(n).astype(np.float64))
    grey = S.lin_to_srgb(np.clip(lin @ w, 0, 1))          # how light the colour is to this film
    out = np.clip(curve(grey), 0, 1)
    return np.repeat(out[..., None], 3, axis=-1).astype(np.float32)


def write(path, look, cube):
    n = cube.shape[0]
    lines = ["# Lumalook's own look. Made by tools/skin-test/make_mono_cube.py; change it there, not here.",
             f'TITLE "{look["title"]}"', "", f"LUT_3D_SIZE {n}", "",
             "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0", ""]
    # The cube is indexed [blue][green][red], as skinlib reads them, so going
    # through it in order gives the .cube order: red changes fastest.
    lines += [f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}" for v in cube.reshape(-1, 3)]
    Path(path).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Write Lumalook's own black-and-white film cubes.")
    ap.add_argument("--to", default=str(S.FILM_DIR), help="folder to write into (default: the app's FilmLUTs)")
    a = ap.parse_args()
    out = Path(a.to)
    out.mkdir(parents=True, exist_ok=True)
    for name, look in LOOKS.items():
        write(out / name, look, make(look))
        print("wrote", out / name)
