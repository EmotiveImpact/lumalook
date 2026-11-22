"""An exact-enough model of the app's recipe colour path, fitted to the
Core Image bake, so the test can try fixes without a Mac.

Core Image (default linear working space) does, per pixel:
  v = M_tt @ lin(x)                       CITemperatureAndTint (3x3 matrix)
  v = sat * v + (1 - sat) * (w . v)       CIColorControls saturation
  v = contrast * (v - 0.5) + 0.5          contrast, pivot at LINEAR 0.5
  v = v + brightness                      brightness, after contrast
  y = srgb(clamp(v))
"""
import json
from pathlib import Path

import numpy as np

import skinlib as S

W = np.array([0.2125, 0.7154, 0.0721], np.float32)
GRID = S.identity_cube(25).reshape(-1, 3)


def fit_tt_matrix(look):
    r = look["recipe"]
    y = look["lut"].reshape(-1, 3)
    ylin = S.srgb_to_lin(y)
    ok = np.all((y > 0.01) & (y < 0.99), axis=1)
    z = (ylin - r["brightness"] - 0.5) / r["contrast"] + 0.5
    x = S.srgb_to_lin(GRID)
    if r["saturation"] > 0.05:
        v = (z - (1 - r["saturation"]) * (z @ W)[:, None]) / r["saturation"]
        M, *_ = np.linalg.lstsq(x[ok], v[ok], rcond=None)
        return M.T
    return np.eye(3, dtype=np.float32)


def apply_model(rgb, r, M, space="linear", toe=0.0):
    """space='linear' reproduces the app today; space='srgb' runs the
    saturation, contrast and brightness on gamma-encoded values (pivot at
    sRGB 0.5, i.e. mid grey), the proposed engine fix. `toe` softens the
    bottom end so contrast can no longer clip shadows to black."""
    x = S.srgb_to_lin(rgb)
    v = x @ M.T
    if space == "linear":
        v = r["saturation"] * v + (1 - r["saturation"]) * (v @ W)[..., None]
        v = r["contrast"] * (v - 0.5) + 0.5 + r["brightness"]
        return S.lin_to_srgb(np.clip(v, 0, 1))
    e = S.lin_to_srgb(np.clip(v, 0, None))
    e = r["saturation"] * e + (1 - r["saturation"]) * (e @ W)[..., None]
    out = r["contrast"] * (e - 0.5) + 0.5 + r["brightness"]
    lo = 0.5 - 0.5 * r["contrast"] + r["brightness"]   # where black lands
    if toe > 0 and lo < 0:
        # Soft toe: between `lo` and t the straight line bends into a
        # parabola that still lands black on black but keeps at least half
        # the slope at the bottom, so shadow detail survives instead of
        # being clipped. t = max(toe, 3|lo|) keeps the curve monotonic.
        t = max(toe, 3 * -lo)
        k = -lo / (lo - t) ** 2
        bent = np.where(out < lo, 0.0, out + k * (out - t) ** 2)
        out = np.where(out < t, bent, out)
    return np.clip(out, 0, 1)


if __name__ == "__main__":
    looks = [l for l in S.load_looks() if l["recipe"]]
    errs = {}
    for lk in looks:
        M = fit_tt_matrix(lk)
        pred = apply_model(GRID, lk["recipe"], M)
        err = np.abs(pred - lk["lut"].reshape(-1, 3))
        errs[lk["id"]] = (float(err.mean() * 255), float(np.percentile(err, 99.5) * 255))
        lk["M"] = M.tolist()
    for k, (m, p) in errs.items():
        print(f"{k:32s} mean {m:5.2f}/255  p99.5 {p:5.2f}/255")
    Path(__file__).with_name("out").joinpath("tt_matrices.json").write_text(
        json.dumps({lk["id"]: lk["M"] for lk in looks}))
