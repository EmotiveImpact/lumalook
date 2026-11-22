"""Engine fix with and without the soft toe, for every recipe look.

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
    for name, toe in (("encode_only", 0.0), ("encode_toe", F.TOE)):
        v, _ = F.judge(F.measure(dict(look, lut=F.recipe_cube(look, toe=toe)), (1.0,))[0])
        out[name] = F.brief(v)
    return lid, out


if __name__ == "__main__":
    ids = [l["id"] for l in json.loads((F.HERE / "looks.json").read_text()) if l["recipe"]]
    res = {}
    with Pool(4, initializer=F._init) as p:
        for lid, o in p.imap_unordered(run, ids):
            res[lid] = o
            print(lid, o["encode_only"]["category"], o["encode_only"]["bad_main"], "|",
                  o["encode_toe"]["category"], o["encode_toe"]["bad_main"], flush=True)
    (RENDER / "engine_variants.json").write_text(json.dumps(res, indent=1))
