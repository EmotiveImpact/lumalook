"""Run every look over every test portrait and the Monk skin-tone chart,
measure what each look does to skin, and save thumbnails and numbers.

    python3 run_test.py RENDER_DIR

Writes RENDER_DIR/thumbs/<look id>/<portrait id>.jpg, RENDER_DIR/chart/<look id>.png
and RENDER_DIR/results.json.
"""
import json
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

import skinlib as S

HERE = Path(__file__).resolve().parent
RENDER = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "out" / "render"
WORK = (540, 675)          # metrics and thumbnails are made at this size
THUMB = (216, 270)

# ---------------------------------------------------------------- test set

PORTRAITS = json.loads((HERE / "portraits.json").read_text())

# Monk Skin Tone scale (Google, CC BY 4.0), tones 4 to 10: light brown to deepest.
MONK = {"MST4": "#eadaba", "MST5": "#d7bd96", "MST6": "#a07e56", "MST7": "#825c43",
        "MST8": "#604134", "MST9": "#3a312a", "MST10": "#292420"}
LIGHTS = {
    "Daylight": dict(gain=(1.0, 1.0, 1.0), stops=0.0, veil=0.0),
    "Warm indoor": dict(gain=(1.18, 1.0, 0.72), stops=0.0, veil=0.0),
    "Night / neon": dict(gain=(1.25, 0.62, 1.30), stops=-0.5, veil=0.0),
    "Backlit": dict(gain=(1.0, 1.0, 1.0), stops=-1.3, veil=0.012),
}
STOPS = [0.7, 0.0, -1.0, -2.0]


def hex_rgb(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], np.float32) / 255


def chart_patches():
    """(lights, tones, stops, 3) sRGB patches."""
    out = np.zeros((len(LIGHTS), len(MONK), len(STOPS), 3), np.float32)
    for li, lt in enumerate(LIGHTS.values()):
        g = np.array(lt["gain"], np.float32)
        g = g / float(g @ np.array([0.2126, 0.7152, 0.0722]))
        for ti, hx in enumerate(MONK.values()):
            lin = S.srgb_to_lin(hex_rgb(hx)) * g
            for si, st in enumerate(STOPS):
                v = lin * 2 ** (st + lt["stops"]) + lt["veil"] * np.array([1.0, 0.85, 0.7])
                out[li, ti, si] = S.lin_to_srgb(np.clip(v, 0, 1))
    return out


CHART = chart_patches()


def load_portraits():
    ims, masks = {}, {}
    for p in PORTRAITS:
        im = Image.open(HERE / "out" / "portraits" / f"{p['id']}.png").convert("RGB").resize(WORK, Image.LANCZOS)
        m = Image.open(HERE / "out" / "portraits" / f"{p['id']}_mask.png").resize(WORK, Image.NEAREST)
        ims[p["id"]] = np.asarray(im).astype(np.float32) / 255
        masks[p["id"]] = np.asarray(m) > 127
    return ims, masks


# ---------------------------------------------------------------- metrics

def hue(a, b):
    return np.degrees(np.arctan2(b, a))


def skin_stats(before, after, mask):
    lb = S.srgb_to_lab(before)
    la = S.srgb_to_lab(after)
    B, A = lb[mask], la[mask]
    Cb = np.hypot(B[:, 1], B[:, 2])
    Ca = np.hypot(A[:, 1], A[:, 2])
    mb, ma = B.mean(0), A.mean(0)
    dh = (hue(ma[1], ma[2]) - hue(mb[1], mb[2]) + 180) % 360 - 180
    # shadow detail: local luminance texture in the darkest 30 % of the skin
    def texture(L):
        return L - gaussian_filter(L, 2.0)
    tb, ta = texture(lb[..., 0])[mask], texture(la[..., 0])[mask]
    dark = B[:, 0] <= np.percentile(B[:, 0], 30)
    detail = float(ta[dark].std() / max(tb[dark].std(), 1e-3))
    return dict(
        L_before=float(np.median(B[:, 0])), L_after=float(np.median(A[:, 0])),
        C_before=float(np.median(Cb)), C_after=float(np.median(Ca)),
        h_before=float(hue(mb[1], mb[2])), dh=float(dh),
        da=float(ma[1] - mb[1]), db=float(ma[2] - mb[2]),
        clip_before=float((B[:, 0] < 2.5).mean()), clip_after=float((A[:, 0] < 2.5).mean()),
        shadow_detail=detail,
        L_dark_before=float(np.percentile(B[:, 0], 10)), L_dark_after=float(np.percentile(A[:, 0], 10)),
        mono=bool(np.median(Ca) < 1.5),
    )


def chart_stats(before, after):
    lb, la = S.srgb_to_lab(before), S.srgb_to_lab(after)
    return dict(lab_before=lb.round(2).tolist(), lab_after=la.round(2).tolist())


# ---------------------------------------------------------------- worker

_IMS = _MASKS = _LOOKS = None


def _init():
    global _IMS, _MASKS, _LOOKS
    _IMS, _MASKS = load_portraits()
    _LOOKS = {l["id"]: l for l in S.load_looks()}


def run_look(look_id):
    look = _LOOKS[look_id]
    res = {"portraits": {}, "portraits75": {}}
    d = RENDER / "thumbs" / look_id
    d.mkdir(parents=True, exist_ok=True)
    for pid, im in _IMS.items():
        out = S.grade(im, look, 1.0)
        res["portraits"][pid] = skin_stats(im, out, _MASKS[pid])
        out75 = S.grade(im, look, 0.75)
        res["portraits75"][pid] = skin_stats(im, out75, _MASKS[pid])
        Image.fromarray((out * 255 + 0.5).astype(np.uint8)).resize(THUMB, Image.LANCZOS).save(
            d / f"{pid}.jpg", quality=88)
    ch = S.sample_tetra(look["lut"], CHART)
    res["chart"] = chart_stats(CHART, ch)
    np.save(RENDER / "chart" / f"{look_id}.npy", ch)
    return look_id, res


if __name__ == "__main__":
    (RENDER / "chart").mkdir(parents=True, exist_ok=True)
    (RENDER / "thumbs" / "original").mkdir(parents=True, exist_ok=True)
    ims, masks = load_portraits()
    for pid, im in ims.items():
        Image.fromarray((im * 255 + 0.5).astype(np.uint8)).resize(THUMB, Image.LANCZOS).save(
            RENDER / "thumbs" / "original" / f"{pid}.jpg", quality=88)
    np.save(RENDER / "chart" / "original.npy", CHART)
    ids = [l["id"] for l in json.loads((HERE / "looks.json").read_text())]
    results = {}
    with Pool(4, initializer=_init) as pool:
        for i, (lid, res) in enumerate(pool.imap_unordered(run_look, ids)):
            results[lid] = res
            if i % 10 == 0:
                print(f"{i + 1}/{len(ids)} {lid}", flush=True)
    base = {pid: skin_stats(im, im, masks[pid]) for pid, im in ims.items()}
    (RENDER / "results.json").write_text(json.dumps({"base": base, "looks": results}))
    print("done", len(results))
