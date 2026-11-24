"""Colour maths for the skin test: the app's looks, re-run in numpy.

Film looks are the app's own .cube files, sampled tetrahedrally (the app
densifies its 13-point cubes tetrahedrally to 64 points, then samples them
trilinearly, which comes to the same thing). Recipe looks are the cubes that
bake_recipes.swift rendered through real Core Image on a Mac. Bloom and
vignette are spatial, so they are modelled here and checked against the Mac's
probe images.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from scipy.ndimage import gaussian_filter

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
FILM_DIR = REPO / "LumaLook/Resources/FilmLUTs"
BAKE_DIR = HERE / "out"

# ---------------------------------------------------------------- transfer

def srgb_to_lin(c):
    c = np.asarray(c, dtype=np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def lin_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=np.float32), 0, None)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055).astype(np.float32)


_M = np.array([[0.4124564, 0.3575761, 0.1804375],
               [0.2126729, 0.7151522, 0.0721750],
               [0.0193339, 0.1191920, 0.9503041]], dtype=np.float32)
_WHITE = np.array([0.95047, 1.0, 1.08883], dtype=np.float32)


def srgb_to_lab(rgb):
    """sRGB 0..1 (..., 3) -> CIELAB D65 (..., 3)."""
    xyz = srgb_to_lin(np.clip(rgb, 0, 1)) @ _M.T / _WHITE
    e = 216 / 24389
    k = 24389 / 27
    f = np.where(xyz > e, np.cbrt(xyz), (k * xyz + 16) / 116)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], -1)


def lab_to_srgb(lab):
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    e = 216 / 24389
    k = 24389 / 27
    def inv(f):
        f3 = f ** 3
        return np.where(f3 > e, f3, (116 * f - 16) / k)
    xyz = np.stack([inv(fx), np.where(L > k * e, fy ** 3, L / k), inv(fz)], -1) * _WHITE
    lin = xyz @ np.linalg.inv(_M).T
    return np.clip(lin_to_srgb(lin), 0, 1)


# ---------------------------------------------------------------- cubes

def read_cube(path: Path) -> np.ndarray:
    """A .cube file as an array indexed [b][g][r] -> rgb (red fastest)."""
    size, rows = None, []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("LUT_3D_SIZE"):
            size = int(line.split()[1])
            continue
        if line[0].isalpha():
            continue
        rows.append([float(v) for v in line.split()[:3]])
    a = np.asarray(rows, dtype=np.float32)
    assert size and len(a) == size ** 3, path
    return a.reshape(size, size, size, 3)


def read_baked(path: Path, n: int = 25) -> np.ndarray:
    raw = np.frombuffer(path.read_bytes(), dtype="<u2").astype(np.float32) / 65535.0
    return raw.reshape(n, n, n, 3)


def sample_trilinear(cube: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    """Trilinear interpolation of `cube` ([b][g][r] -> rgb) at sRGB `rgb`, which
    is how Core Image's colour cube reads a cube in the app."""
    n = cube.shape[0]
    p = np.clip(rgb.reshape(-1, 3), 0, 1) * (n - 1)
    i0 = np.clip(np.floor(p).astype(np.int32), 0, n - 2)
    f = p - i0
    out = 0
    for db in (0, 1):
        for dg in (0, 1):
            for dr in (0, 1):
                w = ((f[:, 0] if dr else 1 - f[:, 0]) * (f[:, 1] if dg else 1 - f[:, 1])
                     * (f[:, 2] if db else 1 - f[:, 2]))
                out = out + cube[i0[:, 2] + db, i0[:, 1] + dg, i0[:, 0] + dr] * w[:, None]
    return np.clip(out, 0, 1).reshape(rgb.shape).astype(np.float32)


def sample_tetra(cube: np.ndarray, rgb: np.ndarray, clip: bool = True) -> np.ndarray:
    """Tetrahedral interpolation of `cube` ([b][g][r] -> rgb) at sRGB `rgb`."""
    n = cube.shape[0]
    shp = rgb.shape
    p = np.clip(rgb.reshape(-1, 3), 0, 1) * (n - 1)
    i0 = np.clip(np.floor(p).astype(np.int32), 0, n - 2)
    f = p - i0
    order = np.argsort(-f, axis=1)                      # axes, largest fraction first
    fs = np.take_along_axis(f, order, axis=1)
    w = np.stack([1 - fs[:, 0], fs[:, 0] - fs[:, 1], fs[:, 1] - fs[:, 2], fs[:, 2]], 1)
    flat = cube.reshape(-1, 3)
    def at(idx):  # idx: (m, 3) as (r, g, b)
        return flat[(idx[:, 2] * n + idx[:, 1]) * n + idx[:, 0]]
    v = i0.copy()
    out = at(v) * w[:, 0:1]
    rows = np.arange(len(v))
    for k in range(3):
        v = v.copy()
        v[rows, order[:, k]] += 1
        out += at(v) * w[:, k + 1:k + 2]
    return (np.clip(out, 0, 1) if clip else out).reshape(shp)


def identity_cube(n: int) -> np.ndarray:
    g = np.linspace(0, 1, n, dtype=np.float32)
    b, gg, r = np.meshgrid(g, g, g, indexing="ij")
    return np.stack([r, gg, b], -1)


# ---------------------------------------------------------------- looks

def before_bake(look_id):
    """Where a recipe look's bake from before True Colour lives (out/luts)."""
    return BAKE_DIR / "luts" / f"{look_id}.u16"


def load_looks():
    """Every look, with a colour cube under "lut": a film look's own .cube
    file, or a recipe look's bake as it shipped before True Colour (out/luts,
    the "before" of the skin test, which is never baked again).

    A recipe added since then has no "before", so its "lut" is None. The gate
    and verify.py do not need it: they judge the bakes of today's engine
    (out/luts_tc, out/luts_classic). The tools that draw or measure the
    "before" leave such a look out."""
    looks = json.loads((HERE / "looks.json").read_text())
    for lk in looks:
        if lk["cube"]:
            lk["lut"] = read_cube(FILM_DIR / lk["cube"])
        else:
            path = before_bake(lk["id"])
            lk["lut"] = read_baked(path) if path.exists() else None
    return looks


def own_input_range(path):
    """True when a .cube file sets its own input range (DOMAIN_MIN/MAX other
    than 0 and 1). The app stretches the picture into that range before the
    cube and shows such a LUT without the skin guard (TrueColour.lutData), so
    a lattice point of the cube is not a plain screen colour and the skin test
    cannot read it as one."""
    for line in Path(path).read_text(errors="replace").splitlines():
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if parts[0].upper() in ("DOMAIN_MIN", "DOMAIN_MAX"):
            want = 0.0 if parts[0].upper() == "DOMAIN_MIN" else 1.0
            try:
                if any(abs(float(v) - want) > 1e-6 for v in parts[1:4]):
                    return True
            except ValueError:
                return True
        elif parts[0][0] in "+-.0123456789":
            break                   # the colour table has started; the header is over
    return False


def _vignette_profile():
    """CIVignette(radius 2, intensity 1) measured on the Mac: linear-light gain
    as a function of distance from the centre, in pixels of a 1080x1350 frame.
    The probe shows gain(i) = gain(1) ** i, so one profile covers every look."""
    path = BAKE_DIR / "probes" / "vignette_profile.json"
    if path.exists():
        d = json.loads(path.read_text())
        return np.asarray(d["r"], np.float32), np.asarray(d["g"], np.float32)
    from PIL import Image
    def load(name):
        a = np.asarray(Image.open(BAKE_DIR / "probes" / name)).astype(np.float32)
        return a[..., 0] / (65535 if a.max() > 255 else 255)
    m = srgb_to_lin(load("vignette_100.png")) / srgb_to_lin(load("vignette_input.png"))
    h, w = m.shape
    y, x = np.mgrid[0:h, 0:w]
    r = np.hypot(x - (w - 1) / 2, y - (h - 1) / 2)
    edges = np.arange(0, r.max() + 4, 4)
    idx = np.digitize(r.ravel(), edges)
    g = np.bincount(idx, m.ravel()) / np.maximum(np.bincount(idx), 1)
    rr = np.bincount(idx, r.ravel()) / np.maximum(np.bincount(idx), 1)
    keep = np.bincount(idx) > 0
    rr, g = rr[keep], np.clip(g[keep], 1e-4, 1)
    path.write_text(json.dumps({"r": rr.round(2).tolist(), "g": g.round(5).tolist()}))
    return rr.astype(np.float32), g.astype(np.float32)


def vignette_mask(h: int, w: int, intensity: float) -> np.ndarray:
    """Linear-light gain standing in for CIVignette(radius 2) at `intensity`,
    scaled from the 1080x1350 probe by frame size."""
    if intensity <= 0:
        return np.ones((h, w), np.float32)
    rr, g = _vignette_profile()
    scale = np.sqrt((1080 * 1350) / (h * w))
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    r = np.hypot(x - (w - 1) / 2, y - (h - 1) / 2) * scale
    return np.interp(r, rr, g).astype(np.float32) ** intensity


def bloom(rgb: np.ndarray, intensity: float, radius_px: float) -> np.ndarray:
    """Stand-in for CIBloom, fitted to the Mac's probe renders (rms error
    0.003 to 0.015 in linear light for intensity 0.2 to 1): a Gaussian blur
    of 1.25 x radius mixed in, out = (1 - 0.4 i) x + 0.48 i blur(x)."""
    if intensity <= 0:
        return rgb
    lin = srgb_to_lin(rgb)
    s = max(radius_px * 1.25, 0.5)
    blur = np.stack([gaussian_filter(lin[..., c], s, mode="nearest") for c in range(3)], -1)
    out = lin * (1 - 0.4 * intensity) + 0.48 * intensity * blur
    return lin_to_srgb(out)


def grade(rgb: np.ndarray, look: dict, intensity: float = 1.0, spatial: bool = True,
          ref_width: float = 1080.0) -> np.ndarray:
    """The app's LookPipeline.apply for one look: colour cube, then (recipes
    only) bloom and vignette, then the intensity dissolve in linear light."""
    out = sample_tetra(look["lut"], rgb)
    r = look.get("recipe")
    if spatial and r:
        scale = rgb.shape[1] / ref_width
        if r["bloom"] > 0:
            out = bloom(out, r["bloom"], 8 * scale)
        if r["vignette"] > 0:
            m = vignette_mask(*out.shape[:2], r["vignette"])[..., None]
            out = lin_to_srgb(srgb_to_lin(out) * m)
    if intensity < 0.999:
        # CIDissolveTransition blends in linear light (probe: black to white
        # at 0.75 gives 0.881, the linear answer).
        out = lin_to_srgb(srgb_to_lin(rgb) * (1 - intensity) + srgb_to_lin(out) * intensity)
    return np.clip(out, 0, 1)
