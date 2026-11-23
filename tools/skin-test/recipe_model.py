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


# ---------------------------------------------------------------- Oklab

_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])
_M1i, _M2i = np.linalg.inv(_M1), np.linalg.inv(_M2)


def oklab(lin):
    return np.cbrt(lin @ _M1.T) @ _M2.T


def oklab_to_lin(lab):
    return (lab @ _M2i.T) ** 3 @ _M1i.T


def tone(e, c, b, toe=0.2):
    """The tone curve, on gamma-encoded values: contrast about mid grey,
    brightness added after it, then a soft toe (black lands on black, half
    the slope kept) and the same shoulder at the top (white lands on white),
    so nothing clips."""
    out = c * (e - 0.5) + 0.5 + b
    if toe <= 0:
        return np.clip(out, 0, 1)
    def bend(y, lo):
        t = max(toe, 3 * -lo)
        k = -lo / (lo - t) ** 2
        return np.where(y < t, np.where(y < lo, 0.0, y + k * (y - t) ** 2), y)
    lo = 0.5 - 0.5 * c + b
    if lo < 0:
        out = bend(out, lo)
    hi = 0.5 + 0.5 * c + b
    if hi > 1:
        out = 1 - bend(1 - out, 1 - hi)
    return np.clip(out, 0, 1)


def skin_true(lin, sat, c, b, toe=0.2):
    """The engine fix as built (SkinTrueTone.swift): saturation scales Oklab
    chroma, and contrast and brightness run on lightness alone, on the
    gamma-encoded grey scale, so skin keeps its hue and chroma while it gets
    lighter or darker. Out-of-gamut results lose chroma, never lightness."""
    lab = oklab(np.clip(lin, 0, 1).astype(np.float64))
    L = np.clip(lab[..., 0], 0, 1)
    e = S.lin_to_srgb(L ** 3).astype(np.float64)
    L2 = np.cbrt(S.srgb_to_lin(tone(e, c, b, toe)).astype(np.float64))
    ab = lab[..., 1:] * sat
    lo_k, hi_k = np.zeros(L.shape), np.ones(L.shape)
    def fits(k):
        v = oklab_to_lin(np.concatenate([L2[..., None], ab * k[..., None]], -1))
        return np.all((v >= -1e-6) & (v <= 1 + 1e-6), -1)
    ok = fits(hi_k)
    if not ok.all():
        for _ in range(14):
            mid = (lo_k + hi_k) / 2
            f = fits(mid)
            lo_k = np.where(f, mid, lo_k)
            hi_k = np.where(f, hi_k, mid)
        k = np.where(ok, 1.0, lo_k)
    else:
        k = hi_k
    v = oklab_to_lin(np.concatenate([L2[..., None], ab * k[..., None]], -1))
    return S.lin_to_srgb(np.clip(v, 0, 1)).astype(np.float32)


def apply_model(rgb, r, M, space="linear", toe=0.0):
    """space='linear' reproduces the app today; space='srgb' runs the
    saturation, contrast and brightness on gamma-encoded values (pivot at
    sRGB 0.5, i.e. mid grey), the proposed engine fix. `toe` softens the
    bottom end so contrast can no longer clip shadows to black."""
    x = S.srgb_to_lin(rgb)
    v = x @ M.T
    if space == "lightness":
        return skin_true(v, r["saturation"], r["contrast"], r["brightness"], toe or 0.2)
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
