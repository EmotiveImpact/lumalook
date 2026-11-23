"""Before and after sheets for the True Colour build, from the real Core
Image bake (verify.py must have run).

    python3 after_sheets.py RENDER_DIR OUT_DIR

Writes OUT_DIR/00-before-and-after.jpg (the biggest rescues on 8 portraits),
one sheet per pack (each look as it shipped, then with True Colour), and
OUT_DIR/true-colour-before-and-after.pdf.
"""
import json

import numpy as np
from PIL import Image, ImageDraw

import sheets as SH          # reads RENDER_DIR and OUT_DIR from argv

RENDER, OUT = SH.RENDER, SH.OUT
VER = json.loads((RENDER / "verify.json").read_text())
LOOKS = SH.LOOKS
V = SH.V
CAT, F, PAD, GAP, GROUP_GAP = SH.CAT, SH.F, SH.PAD, SH.GAP, SH.GROUP_GAP
RANK = {"true": 0, "tweak": 1, "rework": 2}


def stats(v):
    s = f"{v['bad_main']} of 10 main frames bad, {v['warn_main']} mild"
    return s + (f", {v['chart_bad']} chart cells bad" if v.get("chart_bad") else "")


def look_rows(look_id):
    v, r, lk = V[look_id], VER[look_id], LOOKS[look_id]
    issues = [SH.WORDS[k] for k in v["issues"][:3] if k in SH.WORDS and v["issue_weight"].get(k, 0) >= 1]
    rows = [dict(title=f"{lk['code']}  {lk['name']}".strip(), cat=v["category"],
                 lines=["As it shipped: " + stats(v)] + ([SH.cap(", ".join(issues))] if issues and v["category"] != "true" else []),
                 folder=RENDER / "thumbs" / look_id, flags=v["flags"],
                 chart=np.load(RENDER / "chart" / f"{look_id}.npy"), main=True)]
    on = r["on"]
    what = ("Tone on lightness, colour held" if lk["recipe"] else
            "Skin guard on the film cube" if not v["mono"] else "Shadow floor on the cube")
    lines = [what, stats(on)]
    if on["category"] != "true" and r["on75"]["category"] == "true":
        lines.append("Skin-true at the 75% default")
    rows.append(dict(title="With True Colour", cat=on["category"], pill_prefix="NOW ", lines=lines,
                     folder=RENDER / "thumbs_tc" / look_id, flags=None,
                     chart=np.load(RENDER / "chart_fix" / f"tc_{look_id}.npy"), main=False))
    return rows


def summary(path, n_recipe=8, n_film=6):
    """The worst looks as shipped and the same looks with True Colour."""
    def worst(kind, n):
        ids = [k for k, r in VER.items() if r["kind"] == kind and V[k]["category"] != "true"
               and r["on"]["category"] == "true"]
        return sorted(ids, key=lambda k: -V[k]["score"])[:n]
    pick = worst("recipe", n_recipe) + worst("film cube", n_film)
    P = SH.P
    sel = [0, 2, 4, 6, 9, 10, 12, 14]
    tw, th, lw = 150, 188, 380
    W = PAD * 2 + lw + 8 * (tw + GAP) + 3 * GROUP_GAP
    H = 330 + len(pick) * (2 * th + 46) + 120
    im = Image.new("RGB", (W, H), SH.BG)
    d = ImageDraw.Draw(im)
    d.text((PAD, PAD), "True Colour: before and after", font=F[("d", 44)], fill=SH.TEXT)
    d.text((PAD, PAD + 58), "The worst looks as they shipped (top of each pair) and with True Colour (bottom), "
           "rendered through the app's own engine on Core Image.", font=F[("r", 20)], fill=SH.MUTED)

    def gx(i):
        return PAD + lw + i * (tw + GAP) + (i // 2) * (GROUP_GAP - GAP)
    y = PAD + 110
    for g, light in enumerate(SH.LIGHTS):
        d.text((gx(g * 2), y), light.upper(), font=F[("s", 15)], fill=SH.YELLOW)
    y += 30

    def paste(folder, pid, yy, c):
        im.paste(Image.open(folder / f"{pid}.jpg").convert("RGB").resize((tw, th), Image.LANCZOS), (gx(c), yy))
    for c, i in enumerate(sel):
        paste(RENDER / "thumbs" / "original", P[i]["id"], y, c)
    d.text((PAD, y + 70), "Original photo", font=F[("s", 22)], fill=SH.TEXT)
    y += th + 30
    for lid in pick:
        v, r, lk = V[lid], VER[lid], LOOKS[lid]
        d.line([PAD, y - 14, W - PAD, y - 14], fill=(40, 40, 44))
        SH.pill(d, PAD, y + 4, v["category"])
        d.text((PAD + 120, y + 4), lk["section"], font=F[("r", 15)], fill=SH.MUTED)
        for k, ln in enumerate(SH.wrap(d, f"{lk['code']} {lk['name']}".strip(), F[("s", 22)], lw - 30)[:2]):
            d.text((PAD, y + 36 + k * 28), ln, font=F[("s", 22)], fill=SH.TEXT)
        d.text((PAD, y + 100), f"As it shipped: {v['bad_main']} of 10 frames bad", font=F[("r", 15)], fill=SH.MUTED)
        issues = [SH.WORDS[k] for k in v["issues"][:3] if k in SH.WORDS and v["issue_weight"].get(k, 0) >= 1]
        for k, ln in enumerate(SH.wrap(d, SH.cap(", ".join(issues)), F[("r", 15)], lw - 30)[:2]):
            d.text((PAD, y + 122 + k * 20), ln, font=F[("r", 15)], fill=SH.MUTED)
        fy = y + th + 6
        d.rectangle([PAD, fy + 4, PAD + 4, fy + th - 8], fill=SH.YELLOW)
        d.text((PAD + 16, fy + 4), "With True Colour", font=F[("s", 15)], fill=SH.YELLOW)
        SH.pill(d, PAD + 16, fy + 30, r["on"]["category"], "NOW " + CAT[r["on"]["category"]][1])
        for c, i in enumerate(sel):
            paste(RENDER / "thumbs" / lid, P[i]["id"], y, c)
            paste(RENDER / "thumbs_tc" / lid, P[i]["id"], fy, c)
        y = fy + th + 40
    d.text((PAD, y), SH.CREDIT, font=F[("r", 15)], fill=SH.MUTED)
    im = im.crop((0, 0, W, y + 40))
    im.save(path, quality=86, optimize=True)
    return path


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    SH.look_rows = look_rows
    made = [summary(OUT / "00-before-and-after.jpg")]
    print(made[0], flush=True)
    for i, sec in enumerate(SH.ORDER, 1):
        ids = [lid for lid, l in LOOKS.items() if l["section"] == sec]
        ids.sort(key=lambda lid: (RANK[VER[lid]["on"]["category"]], VER[lid]["on"]["bad_main"], V[lid]["score"]))
        b = {c: sum(V[l]["category"] == c for l in ids) for c in RANK}
        a = {c: sum(VER[l]["on"]["category"] == c for l in ids) for c in RANK}
        sub = (f"{len(ids)} looks. Skin-true as shipped: {b['true']}. With True Colour: {a['true']} skin-true, "
               f"{a['tweak']} near, {a['rework']} rework.")
        slug = sec.lower().replace("&", "and").replace(" / ", "-").replace(" ", "-")
        path = OUT / f"{i:02d}-{slug}.jpg"
        SH.sheet(f"{sec}: before and after", sub, ids, path)
        made.append(path)
        print(path, flush=True)
    pages = []
    for p in made:
        im = Image.open(p).convert("RGB")
        if im.width > 2000:
            im = im.resize((2000, im.height * 2000 // im.width), Image.LANCZOS)
        pages.append(im)
    pdf = OUT / "true-colour-before-and-after.pdf"
    pages[0].save(pdf, save_all=True, append_images=pages[1:], resolution=150, quality=72)
    print(pdf)
