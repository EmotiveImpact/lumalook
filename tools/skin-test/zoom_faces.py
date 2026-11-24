"""Zoom into the face: one look on a few photos, as shipped, True Colour on
and off, with how much of the skin each version turns black.

    python3 zoom_faces.py OUT.jpg LOOK [--before LOOKS_BEFORE.json] [--extra PHOTO:x0,y0,x1,y1 ...]

Uses the test portraits and their skin masks (out/portraits). `--extra` adds
any other photo with a face box in 0..1 coordinates; its skin is taken as an
ellipse inside the box, minus pixels that are already black or blown out.
Each photo gets two rows: full strength, and the app's 75% default. "Skin
gone black" is the skin test's own measure (CIELAB L* under 2.5); "very
dark" is L* under 10, where a face stops reading on a phone.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

import skinlib as S
import try_photos as TP

HERE = Path(__file__).resolve().parent
PORTRAITS = ["day-pexels-31579771", "back-pexels-29037457", "warm-pexels-5760943", "night-pexels-7194024"]
TILE = 400


def face_box(mask):
    ys, xs = np.nonzero(mask)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    side = max(x1 - x0, y1 - y0) * 1.25
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    h, w = mask.shape
    side = min(side, w, h)
    bx = min(max(cx - side / 2, 0), w - side)
    by = min(max(cy - side / 2, 0), h - side)
    return int(bx), int(by), int(bx + side), int(by + side)


def load_extra(spec):
    path, box = spec.rsplit(":", 1)
    x0, y0, x1, y1 = [float(v) for v in box.split(",")]
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    s = 1400 / max(im.size)
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    rgb = np.asarray(im).astype(np.float32) / 255
    h, w = rgb.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    cx, cy = (x0 + x1) / 2 * w, (y0 + y1) / 2 * h
    m = ((xx - cx) / ((x1 - x0) * w * 0.36)) ** 2 + ((yy - cy) / ((y1 - y0) * h * 0.44)) ** 2 <= 1
    lab = S.srgb_to_lab(rgb)
    m &= (lab[..., 0] > 3) & (lab[..., 0] < 92)
    return Path(path).stem, rgb, m, (int(x0 * w), int(y0 * h), int(x1 * w), int(y1 * h))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("look")
    ap.add_argument("--before", default="")
    ap.add_argument("--extra", nargs="*", default=[])
    a = ap.parse_args()
    looks = {l["id"]: l for l in json.loads((HERE / "looks.json").read_text())}
    by_code = {(l["code"] or l["name"]).lower(): l["id"] for l in reversed(list(looks.values()))}
    lid = a.look if a.look in looks else by_code[a.look.lower()]
    look = looks[lid]
    before = {l["id"]: l["recipe"] for l in json.loads(Path(a.before).read_text())} if a.before else {}
    versions = TP.versions(look, before.get(lid))

    photos = [load_extra(s) for s in a.extra]
    for pid in PORTRAITS:
        rgb = np.asarray(Image.open(TP.OUT / "portraits" / f"{pid}.png").convert("RGB")).astype(np.float32) / 255
        mask = np.asarray(Image.open(TP.OUT / "portraits" / f"{pid}_mask.png")) > 127
        photos.append((pid, rgb, mask, face_box(mask)))

    f_title = ImageFont.truetype(str(TP.FONTS / "Inter-SemiBold.otf"), 26)
    f_lab = ImageFont.truetype(str(TP.FONTS / "Inter-SemiBold.otf"), 18)
    f_small = ImageFont.truetype(str(TP.FONTS / "Inter-Medium.otf"), 17)
    left, gap, cap = 170, 8, 58
    W = left + 4 * (TILE + gap) + 30
    row_h = TILE + cap + 14
    H = 110 + len(photos) * (2 * row_h + 40)
    canvas = Image.new("RGB", (W, H), (11, 11, 12))
    d = ImageDraw.Draw(canvas)
    d.text((30, 28), f"{look['code']} {look['name']}".strip() + ": zoomed into the face", font=f_title, fill=(236, 236, 236))
    d.text((30, 66), "Under each picture: how much of the skin has gone black, and how much is too dark to read.",
           font=f_small, fill=(150, 150, 156))
    y = 110
    stats = []
    for name, rgb, mask, (x0, y0, x1, y1) in photos:
        for strength, label in ((1.0, "Full strength"), (0.75, "75% default")):
            d.text((30, y + 8), label, font=f_lab, fill=(236, 236, 236))
            cols = [("Original", rgb)] + [(n, S.grade(rgb, v, strength)) for n, v in versions]
            for c, (n, img) in enumerate(cols):
                x = left + c * (TILE + gap)
                tile = Image.fromarray((np.clip(img[y0:y1, x0:x1], 0, 1) * 255 + 0.5).astype(np.uint8))
                canvas.paste(tile.resize((TILE, TILE), Image.LANCZOS), (x, y))
                box = d.textbbox((x + 8, y + 8), n, font=f_small)
                d.rounded_rectangle((box[0] - 6, box[1] - 4, box[2] + 6, box[3] + 4), 6, fill=(11, 11, 12))
                d.text((x + 8, y + 8), n, font=f_small, fill=(245, 225, 75))
                L = S.srgb_to_lab(img)[..., 0][mask]
                black, dark = float((L < 2.5).mean()) * 100, float((L < 10).mean()) * 100
                stats.append((name, label, n, round(black, 1), round(dark, 1)))
                bad = n == "As it shipped" and (black >= 3 or dark >= 25)
                d.text((x + 2, y + TILE + 8), f"Gone black {black:.0f}%", font=f_lab,
                       fill=(255, 110, 100) if bad else (236, 236, 236))
                d.text((x + 2, y + TILE + 32), f"Too dark to read {dark:.0f}%", font=f_small, fill=(150, 150, 156))
            y += row_h
        y += 40
    canvas.crop((0, 0, W, y)).save(a.out, quality=90)
    for s in stats:
        print(*s, sep=" | ")
    print(a.out)


if __name__ == "__main__":
    main()
