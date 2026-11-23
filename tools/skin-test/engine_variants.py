"""Engine fix variants for every recipe look: encoded values without and with
the soft toe, and the lightness-only engine as built (colour held).

    python3 engine_variants.py RENDER_DIR
"""
import json
import sys
from multiprocessing import Pool
from pathlib import Path

import fixes as F   # reads RENDER_DIR from argv

RENDER = F.RENDER


def run(lid):
    look = F._LOOKS[lid]
    out = {}
    for name, space, toe in (("encode_only", "srgb", 0.0), ("encode_toe", "srgb", F.TOE),
                             ("lightness", "lightness", F.TOE)):
        res = F.measure(dict(look, lut=F.recipe_cube(look, space=space, toe=toe)), (1.0, 0.75))[0]
        out[name] = F.brief(F.judge(res)[0])
        out[name + "75"] = F.brief(F.judge(res, key="portraits75")[0])
    return lid, out


if __name__ == "__main__":
    ids = [l["id"] for l in json.loads((F.HERE / "looks.json").read_text()) if l["recipe"]]
    res = {}
    with Pool(4, initializer=F._init) as p:
        for lid, o in p.imap_unordered(run, ids):
            res[lid] = o
            print(f"{lid:34s}", *(f"{o[k]['category']:6s}{o[k]['bad_main']:2d}/{o[k]['warn_main']}"
                                  for k in ("encode_only", "encode_toe", "lightness", "lightness75")), flush=True)
    (RENDER / "engine_variants.json").write_text(json.dumps(res, indent=1))
