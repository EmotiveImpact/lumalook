"""Write the guarded cubes from fixes.py as .cube files, ready to swap in.

    python3 export_cubes.py RENDER_DIR OUT_DIR
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RENDER, OUT = Path(sys.argv[1]), Path(sys.argv[2])
LOOKS = {l["id"]: l for l in json.loads((HERE / "looks.json").read_text())}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for f in sorted((RENDER / "guarded_cubes").glob("*.npy")):
        lk = LOOKS[f.stem]
        cube = np.load(f)                       # [b][g][r] -> rgb
        n = cube.shape[0]
        lines = [f"# {lk['code']} {lk['name']}: skin guard (Lumalook skin test)",
                 f"TITLE \"{lk['code']} skin guard\"", f"LUT_3D_SIZE {n}",
                 "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        lines += [f"{r:.6f} {g:.6f} {b:.6f}" for r, g, b in cube.reshape(-1, 3)]
        name = Path(lk["cube"]).stem + "_guard.cube"
        (OUT / name).write_text("\n".join(lines) + "\n")
        print(name)
