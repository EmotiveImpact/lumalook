"""Run any photo through looks: as shipped before the fix, True Colour off,
True Colour on, all from the Mac runner's Core Image bake.

    python3 try_photos.py OUT.jpg PHOTO [PHOTO ...] [--looks id-or-code,...] [--before LOOKS_BEFORE.json]

Each photo gets one block: the original, then a row per look with the three
versions side by side. Recipes use out/luts (before), out/luts_classic (off)
and out/luts_tc (on); film looks use the raw cube (before and off) and
out/film_tc (on). Bloom and vignette are drawn like the app. `--before`
points at the looks.json from before the recipe tweaks, so "before" uses the
old recipe's bloom and vignette too.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

import skinlib as S

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
FONTS = HERE.parents[1] / "LumaLook/Resources/Fonts"
DEFAULT = ["sig-kd2-golden-hour", "sig-afrobeats-glow", "sig-neon-nights", "cine-print-set-01-cn83",
           "bw-set-01-bw32", "film-stocks-01-pt160", "film-stocks-01-cp2383", "film-instant-lab-px680"]


def load(path, long_side=900):
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    s = long_side / max(im.size)
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255


def versions(look, before_recipe):
    lid = look["id"]
    if look["recipe"]:
        b = dict(look, lut=S.read_baked(OUT / "luts" / f"{lid}.u16"), recipe=before_recipe or look["recipe"])
        off = dict(look, lut=S.read_baked(OUT / "luts_classic" / f"{lid}.u16"))
        on = dict(look, lut=S.read_baked(OUT / "luts_tc" / f"{lid}.u16"))
    else:
        raw = S.read_cube(S.FILM_DIR / look["cube"])
        b = dict(look, lut=raw)
        off = dict(look, lut=raw)
        on = dict(look, lut=S.read_baked(OUT / "film_tc" / f"{lid}.u16"))
    return [("As it shipped", b), ("True Colour off", off), ("True Colour on", on)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("photos", nargs="+")
    ap.add_argument("--looks", default="")
    ap.add_argument("--before", default="")
    ap.add_argument("--intensity", type=float, default=1.0)
    a = ap.parse_args()
    looks = {l["id"]: l for l in json.loads((HERE / "looks.json").read_text())}
    by_code = {}
    for l in looks.values():
        by_code.setdefault((l["code"] or l["name"]).lower(), l["id"])
    before = {l["id"]: l["recipe"] for l in json.loads(Path(a.before).read_text())} if a.before else {}
    want = [w.strip() for w in a.looks.split(",") if w.strip()] or DEFAULT
    ids = [w if w in looks else by_code.get(w.lower()) for w in want]
    ids = [i for i in ids if i]
    f_title = ImageFont.truetype(str(FONTS / "Inter-SemiBold.otf"), 22)
    f_small = ImageFont.truetype(str(FONTS / "Inter-Medium.otf"), 16)
    blocks = []
    for p in a.photos:
        img = load(p)
        h, w = img.shape[:2]
        tw = 360
        th = round(h * tw / w)
        lw = 260
        W = lw + 3 * (tw + 6) + 40
        H = 60 + (th + 40) * (len(ids) + 1)
        canvas = Image.new("RGB", (W, H), (11, 11, 12))
        d = ImageDraw.Draw(canvas)
        y = 20
        d.text((20, y), Path(p).name, font=f_title, fill=(236, 236, 236))
        y += 40

        def put(arr, col, yy):
            canvas.paste(Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)).resize((tw, th), Image.LANCZOS),
                         (lw + col * (tw + 6), yy))
        d.text((20, y + 10), "Original", font=f_title, fill=(236, 236, 236))
        put(img, 0, y)
        y += th + 40
        for lid in ids:
            lk = looks[lid]
            d.text((20, y + 10), f"{lk['code']} {lk['name']}".strip(), font=f_title, fill=(236, 236, 236))
            d.text((20, y + 40), lk["section"], font=f_small, fill=(140, 140, 146))
            for c, (label, v) in enumerate(versions(lk, before.get(lid))):
                put(S.grade(img, v, a.intensity), c, y)
                x0 = lw + c * (tw + 6) + 8
                box = d.textbbox((x0, y + 8), label, font=f_small)
                d.rounded_rectangle((box[0] - 6, box[1] - 4, box[2] + 6, box[3] + 4), 6, fill=(11, 11, 12))
                d.text((x0, y + 8), label, font=f_small, fill=(245, 225, 75))
            y += th + 40
        blocks.append(canvas.crop((0, 0, W, y)))
    W = max(b.width for b in blocks)
    sheet = Image.new("RGB", (W, sum(b.height for b in blocks)), (11, 11, 12))
    y = 0
    for b in blocks:
        sheet.paste(b, (0, y))
        y += b.height
    sheet.save(a.out, quality=88)
    print(a.out, sheet.size)


if __name__ == "__main__":
    main()
