"""Crop each test portrait to 4:5 at 1080x1350 and build its skin mask.

The mask is the hand-placed ellipses in portraits.json, minus pixels that
cannot be skin: near-black (hair, pupils), near-white specular or teeth, and
very low-chroma brights (eye whites)."""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import skinlib as S

HERE = Path(__file__).resolve().parent
OUT = HERE / "out" / "portraits"
OUT.mkdir(parents=True, exist_ok=True)
W, H = 1080, 1350


def prepare(p):
    im = Image.open(HERE / "out" / "candidates" / f"{p['id']}.jpg").convert("RGB")
    w, h = im.size
    x0, y0, x1, y1 = p["crop"]
    box = (x0 * w, y0 * h, x1 * w, y1 * h)
    # force 4:5 around the box centre
    bw, bh = box[2] - box[0], box[3] - box[1]
    if bw / bh > 0.8:
        nw = bh * 0.8; cx = (box[0] + box[2]) / 2; box = (cx - nw / 2, box[1], cx + nw / 2, box[3])
    else:
        nh = bw / 0.8; cy = (box[1] + box[3]) / 2; box = (box[0], cy - nh / 2, box[2], cy + nh / 2)
    crop = im.resize((W, H), Image.LANCZOS, box=box)
    # ellipses: original-normalised -> crop pixels
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    m = np.zeros((H, W), bool)
    sx, sy = W / (box[2] - box[0]), H / (box[3] - box[1])
    for cx, cy, rx, ry in p["skin"]:
        ex, ey = (cx * w - box[0]) * sx, (cy * h - box[1]) * sy
        ax, ay = rx * w * sx, ry * h * sy
        m |= ((xx - ex) / ax) ** 2 + ((yy - ey) / ay) ** 2 <= 1
    rgb = np.asarray(crop).astype(np.float32) / 255
    lab = S.srgb_to_lab(rgb)
    C = np.hypot(lab[..., 1], lab[..., 2])
    m &= lab[..., 0] > 3
    m &= lab[..., 0] < 92
    m &= ~((lab[..., 0] > 55) & (C < 6))
    crop.save(OUT / f"{p['id']}.png")
    Image.fromarray((m * 255).astype(np.uint8)).save(OUT / f"{p['id']}_mask.png")
    return crop, m


if __name__ == "__main__":
    ps = json.loads((HERE / "portraits.json").read_text())
    tiles = []
    for p in ps:
        crop, m = prepare(p)
        lab = S.srgb_to_lab(np.asarray(crop).astype(np.float32) / 255)[m]
        L, a, b = np.median(lab, 0)
        print(f"{p['id']:24s} skin px {m.sum():7d}  L* {L:5.1f}  a* {a:5.1f}  b* {b:5.1f}  "
              f"h {np.degrees(np.arctan2(b, a)):5.1f}")
        t = crop.copy()
        ov = Image.new("RGB", t.size, (0, 255, 0))
        t = Image.composite(Image.blend(t, ov, 0.45), t, Image.fromarray((m * 255).astype(np.uint8)))
        t.thumbnail((270, 338))
        tiles.append(t)
    sheet = Image.new("RGB", (8 * 270, 2 * 338), "white")
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % 8) * 270, (i // 8) * 338))
    sheet.save(HERE / "out" / "mask_check.jpg", quality=85)
