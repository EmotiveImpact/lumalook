"""Contact sheets: one per pack, every look on all 16 portraits plus the Monk
chart, flags marked, and the proposed fix under each look that fails.

    python3 sheets.py RENDER_DIR OUT_DIR
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
RENDER = Path(sys.argv[1])
OUT = Path(sys.argv[2])
FONTS = HERE.parents[1] / "LumaLook/Resources/Fonts"

P = json.loads((HERE / "portraits.json").read_text())
LOOKS = {l["id"]: l for l in json.loads((HERE / "looks.json").read_text())}
V = {v["id"]: v for v in json.loads((RENDER / "verdicts.json").read_text())}
FX = json.loads((RENDER / "fixes.json").read_text())
STRESS = {"day-pexels-31579771", "back-pexels-14253763"}

BG = (11, 11, 12)
PANEL = (22, 22, 24)
TEXT = (236, 236, 236)
MUTED = (140, 140, 146)
YELLOW = (245, 225, 75)
CAT = {"true": ((61, 220, 132), "SKIN-TRUE"), "tweak": ((245, 165, 36), "TWEAK"),
       "rework": ((240, 68, 56), "REWORK")}
SEV = {1: (245, 165, 36), 3: (240, 68, 56)}
LETTER = {"crush": "C", "dark": "D", "ashy": "A", "green": "G", "magenta": "M", "oversat": "O", "mono_flat": "F"}
WORDS = {"crush": "crushed shadows", "dark": "skin too dark", "ashy": "ashy / grey",
         "green": "green cast", "magenta": "magenta cast", "oversat": "orange / red oversaturation"}


def font(w, size):
    name = {"r": "Inter-Regular.otf", "m": "Inter-Medium.otf", "s": "Inter-SemiBold.otf", "b": "Inter-Bold.otf",
            "d": "InterDisplay-Bold.otf"}[w]
    return ImageFont.truetype(str(FONTS / name), size)


F = {k: font(*k) for k in [("r", 15), ("r", 17), ("m", 17), ("s", 19), ("s", 15), ("b", 13), ("s", 22),
                           ("d", 44), ("r", 20), ("m", 14), ("b", 15)]}

TW, TH = 132, 165
GAP, GROUP_GAP = 3, 14
LABEL_W = 360
CHART_W = 250
PAD = 40
ROW_GAP = 10
SUB_GAP = 3
LIGHTS = ["Daylight", "Warm indoor", "Night / neon", "Backlit"]


def grid_x(i):
    g = i // 4
    return PAD + LABEL_W + i * (TW + GAP) + g * (GROUP_GAP - GAP)


SHEET_W = grid_x(15) + TW + 20 + CHART_W + PAD


def wrap(d, text, f, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=f) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def pill(d, x, y, cat, text=None):
    col, label = CAT[cat]
    label = text or label
    f = F[("b", 13)]
    w = d.textlength(label, font=f) + 18
    d.rounded_rectangle([x, y, x + w, y + 22], radius=11, fill=col)
    d.text((x + 9, y + 4), label, font=f, fill=(10, 10, 10))
    return x + w


def thumb(path):
    return Image.open(path).convert("RGB").resize((TW, TH), Image.LANCZOS)


def draw_thumbs(im, d, y, folder, flags=None):
    for i, p in enumerate(P):
        x = grid_x(i)
        f = folder / f"{p['id']}.jpg"
        if not f.exists():
            d.rectangle([x, y, x + TW, y + TH], fill=PANEL)
            continue
        im.paste(thumb(f), (x, y))
        if flags is not None:
            fl = flags.get(p["id"], {})
            if fl:
                sev = max(fl.values())
                col = SEV[3 if sev >= 3 else 1]
                for k in range(3):
                    d.rectangle([x + k, y + k, x + TW - 1 - k, y + TH - 1 - k], outline=col)
                tag = " ".join(LETTER[k] for k, v in sorted(fl.items(), key=lambda kv: -kv[1]))
                f2 = F[("b", 13)]
                w = d.textlength(tag, font=f2) + 10
                d.rectangle([x + 3, y + TH - 23, x + 3 + w, y + TH - 4], fill=col)
                d.text((x + 8, y + TH - 22), tag, font=f2, fill=(10, 10, 10))


CHART_ROWS = [("Day", 0, 1), ("Warm", 1, 1), ("Back", 3, 1), ("Day -1", 0, 2), ("Day -2", 0, 3)]
ORIG_CHART = np.load(RENDER / "chart" / "original.npy")


def draw_chart(d, x, y, after):
    cw, chh = 24, 14
    f = F[("r", 15)]
    for r, (name, li, si) in enumerate(CHART_ROWS):
        yy = y + r * (2 * chh + 3)
        d.text((x, yy + 6), name, font=F[("m", 14)], fill=MUTED)
        for t in range(7):
            xx = x + 52 + t * (cw + 2)
            b = tuple(int(v * 255 + 0.5) for v in ORIG_CHART[li, t, si])
            a = tuple(int(v * 255 + 0.5) for v in after[li, t, si])
            d.rectangle([xx, yy, xx + cw, yy + chh], fill=b)
            d.rectangle([xx, yy + chh, xx + cw, yy + 2 * chh], fill=a)


def header(im, d, y, title, subtitle):
    d.text((PAD, y), title, font=F[("d", 44)], fill=TEXT)
    d.text((PAD, y + 58), subtitle, font=F[("r", 20)], fill=MUTED)
    y += 104
    # legend
    x = PAD
    for cat in ("true", "tweak", "rework"):
        x = pill(d, x, y, cat) + 10
    x += 14
    legend = "Red border: bad shift.  Amber: mild.  Letters: C crushed shadows, D skin too dark, A ashy / grey, G green cast, M magenta cast, O orange / red oversaturation."
    d.text((x, y + 2), legend, font=F[("r", 17)], fill=MUTED)
    y += 34
    d.text((PAD, y), "Night / neon frames are judged on shadows only, since the light itself is coloured. Frames marked STRESS are extreme low-key tests and count half.",
           font=F[("r", 17)], fill=MUTED)
    y += 40
    # column heads
    for g, light in enumerate(LIGHTS):
        x0 = grid_x(g * 4)
        d.text((x0, y), light.upper(), font=F[("s", 15)], fill=YELLOW)
    d.text((grid_x(15) + TW + 20, y), "MONK CHART, TONES 4 TO 10", font=F[("s", 15)], fill=YELLOW)
    d.text((grid_x(15) + TW + 20, y + 26), "Top half: photo", font=F[("r", 15)], fill=MUTED)
    d.text((grid_x(15) + TW + 20, y + 44), "Bottom half: with the look", font=F[("r", 15)], fill=MUTED)
    y += 26
    for i, p in enumerate(P):
        x = grid_x(i)
        lbl = p["label"] + ("  STRESS" if p["id"] in STRESS else "")
        for k, line in enumerate(wrap(d, lbl, F[("r", 15)], TW)[:2]):
            d.text((x, y + k * 18), line, font=F[("r", 15)], fill=MUTED)
    y += 44
    return y


def look_rows(look_id):
    """[(label lines, category, thumbs folder, flags, chart array, kind)]"""
    v = V[look_id]
    lk = LOOKS[look_id]
    fx = FX.get(look_id, {})
    rows = []
    stats = f"{v['bad_main']} of 10 main frames bad, {v['warn_main']} mild"
    if v["chart_bad"]:
        stats += f", {v['chart_bad']} chart cells bad"
    issues = [WORDS[k] for k in v["issues"][:3] if k in WORDS and v["issue_weight"].get(k, 0) >= 1]
    kind = "recipe" if lk["recipe"] else "film cube"
    rows.append(dict(title=f"{lk['code']}  {lk['name']}".strip(), cat=v["category"],
                     lines=[stats] + ([cap(", ".join(issues))] if issues and v["category"] != "true" else []),
                     folder=RENDER / "thumbs" / look_id, flags=v["flags"],
                     chart=np.load(RENDER / "chart" / f"{look_id}.npy"), main=True))
    if v["category"] == "true":
        return rows
    if kind == "recipe":
        e = fx.get("engine")
        if e:
            rows.append(dict(title="Proposed: engine fix only", cat=e["category"],
                             lines=["No recipe change. Contrast runs on", "mid grey with a soft toe."],
                             folder=RENDER / "thumbs_fix" / "engine" / look_id, flags=None,
                             chart=np.load(RENDER / "chart_fix" / f"engine_{look_id}.npy"), main=False))
        t = fx.get("tweak")
        if t and not t.get("none_found") and (RENDER / "thumbs_fix" / "tweak" / look_id).exists():
            pr, r = t["params"], lk["recipe"]
            ch = []
            for k, nm in (("contrast", "contrast"), ("saturation", "saturation"), ("brightness", "brightness"),
                          ("vignette", "vignette")):
                if abs(pr[k] - r[k]) > 1e-6:
                    ch.append(f"{nm} {r[k]:g} to {pr[k]:g}")
            if pr["wb_scale"] < 1:
                if r["temperature"] != 6500:
                    ch.append(f"warmth {r['temperature']:g} K to about {pr['temperature']:g} K")
                if r["tint"]:
                    ch.append(f"tint {r['tint']:g} to {pr['tint']:g}")
            rows.append(dict(title="Proposed: engine fix + recipe tweak", cat=t["category"],
                             lines=wrap_lines(cap("; ".join(ch))),
                             folder=RENDER / "thumbs_fix" / "tweak" / look_id, flags=None,
                             chart=np.load(RENDER / "chart_fix" / f"tweak_{look_id}.npy"), main=False))
    else:
        g = fx.get("guard")
        if g:
            mono = LOOKS[look_id].get("mono") or v["mono"]
            lines = (["Shadow floor in the cube: deepest", "tones keep their separation."] if v["mono"] else
                     ["Skin hues held close to the photo,", "rest of the frame keeps the look."])
            rows.append(dict(title="Proposed: skin guard in the cube", cat=g["category"], lines=lines,
                             folder=RENDER / "thumbs_fix" / "guard" / look_id, flags=None,
                             chart=np.load(RENDER / "chart_fix" / f"guard_{look_id}.npy"), main=False))
        si = fx.get("safe_intensity")
        if si and si < 1.0:
            rows[0]["lines"].append(f"Passes as it is at {int(si * 100)}% intensity")
    return rows


def cap(t):
    return t[:1].upper() + t[1:]


def wrap_lines(text, width=LABEL_W - 70):
    tmp = Image.new("RGB", (10, 10))
    return wrap(ImageDraw.Draw(tmp), text, F[("r", 15)], width)[:4]


def draw_row(im, d, y, row):
    x = PAD
    if row["main"]:
        d.line([PAD, y - ROW_GAP // 2, SHEET_W - PAD, y - ROW_GAP // 2], fill=(40, 40, 44), width=1)
        nx = pill(d, x, y + 4, row["cat"])
        lines = wrap(d, row["title"], F[("s", 22)], LABEL_W - 20)
        for k, ln in enumerate(lines[:2]):
            d.text((x, y + 36 + k * 28), ln, font=F[("s", 22)], fill=TEXT)
        yy = y + 36 + 28 * min(len(lines), 2) + 6
        for ln in row["lines"]:
            for l2 in wrap(d, ln, F[("r", 15)], LABEL_W - 30):
                d.text((x, yy), l2, font=F[("r", 15)], fill=MUTED)
                yy += 20
    else:
        d.rectangle([x + 18, y + 4, x + 22, y + TH - 8], fill=YELLOW)
        d.text((x + 40, y + 6), row["title"], font=F[("s", 15)], fill=YELLOW)
        pill(d, x + 40, y + 32, row["cat"], row.get("pill_prefix", "WOULD BE ") + CAT[row["cat"]][1])
        yy = y + 64
        for ln in row["lines"]:
            d.text((x + 40, yy), ln, font=F[("r", 15)], fill=MUTED)
            yy += 20
    draw_thumbs(im, d, y, row["folder"], row["flags"])
    draw_chart(d, grid_x(15) + TW + 20, y + 4, row["chart"])
    return y + TH + (ROW_GAP if row["main"] else SUB_GAP)


def sheet(title, subtitle, look_ids, path):
    rows = []
    for lid in look_ids:
        rows.extend(look_rows(lid))
    n_main = sum(r["main"] for r in rows)
    h = 290 + (TH + 30) + sum(TH + (ROW_GAP if r["main"] else SUB_GAP) for r in rows) + n_main * 4 + 120
    im = Image.new("RGB", (SHEET_W, h), BG)
    d = ImageDraw.Draw(im)
    y = header(im, d, PAD, title, subtitle)
    # original row
    d.text((PAD, y + 30), "Original photo", font=F[("s", 22)], fill=TEXT)
    d.text((PAD, y + 62), "No look applied", font=F[("r", 15)], fill=MUTED)
    draw_thumbs(im, d, y, RENDER / "thumbs" / "original")
    draw_chart(d, grid_x(15) + TW + 20, y + 4, ORIG_CHART)
    y += TH + 24
    for r in rows:
        y = draw_row(im, d, y + (4 if r["main"] else 0), r)
    y += 20
    d.text((PAD, y), CREDIT, font=F[("r", 15)], fill=MUTED)
    im = im.crop((0, 0, SHEET_W, y + 40))
    im.save(path, quality=86, optimize=True)
    return im


CREDIT = ("Photos from Pexels (Pexels Licence): " + ", ".join(sorted({p['by'] for p in P}))
          + ". Monk Skin Tone scale by Google (CC BY 4.0). Looks rendered at 100% intensity.")

ORDER = ["Signature", "Negative Set 01", "B&W Set 01", "Cine Print Set 01", "Originals 01", "After Dark",
         "Film Stocks 01", "Negative Archive", "Slide Archive", "Mono Archive", "Instant Lab", "Mirrorless Sims"]
RANK = {"true": 0, "tweak": 1, "rework": 2}

FIX_DIR = {"engine": "engine", "engine+recipe": "tweak", "skin guard": "guard", "shadow floor": "guard"}
FIX_NAME = {"engine": "engine fix", "engine+recipe": "engine fix + recipe tweak", "skin guard": "skin guard",
            "shadow floor": "shadow floor"}


def summary(path, n=14):
    """Before and after for the worst looks that have a fix, on 8 portraits."""
    ranked = json.loads((RENDER / "ranked.json").read_text())
    pick = [r for r in ranked if r["fix_kind"] in FIX_DIR and r["group"] == "tweak"]
    pick.sort(key=lambda r: -V[r["id"]]["score"])
    pick = pick[:n]
    sel = [0, 2, 4, 6, 9, 10, 12, 14]
    tw, th = 150, 188
    lw = 380
    W = PAD * 2 + lw + 8 * (tw + GAP) + 3 * GROUP_GAP
    H = 330 + len(pick) * (2 * th + 46) + 120
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    d.text((PAD, PAD), "Worst looks that a fix rescues", font=F[("d", 44)], fill=TEXT)
    d.text((PAD, PAD + 58), "Two portraits per light. Top row of each pair: the look as it ships. Bottom row: with the fix.",
           font=F[("r", 20)], fill=MUTED)

    def gx(i):
        return PAD + lw + i * (tw + GAP) + (i // 2) * (GROUP_GAP - GAP)
    y = PAD + 110
    for g, light in enumerate(LIGHTS):
        d.text((gx(g * 2), y), light.upper(), font=F[("s", 15)], fill=YELLOW)
    y += 30
    for c, i in enumerate(sel):
        im.paste(Image.open(RENDER / "thumbs" / "original" / f"{P[i]['id']}.jpg").convert("RGB").resize((tw, th), Image.LANCZOS), (gx(c), y))
    d.text((PAD, y + 70), "Original photo", font=F[("s", 22)], fill=TEXT)
    y += th + 30
    for r in pick:
        v = V[r["id"]]
        d.line([PAD, y - 14, W - PAD, y - 14], fill=(40, 40, 44))
        pill(d, PAD, y + 4, v["category"])
        d.text((PAD + 120, y + 4), r["section"], font=F[("r", 15)], fill=MUTED)
        for k, ln in enumerate(wrap(d, r["look"], F[("s", 22)], lw - 30)[:2]):
            d.text((PAD, y + 36 + k * 28), ln, font=F[("s", 22)], fill=TEXT)
        d.text((PAD, y + 100), f"Now: {v['bad_main']} of 10 frames bad", font=F[("r", 15)], fill=MUTED)
        if r["problems"]:
            for k, ln in enumerate(wrap(d, cap(r["problems"]), F[("r", 15)], lw - 30)[:2]):
                d.text((PAD, y + 122 + k * 20), ln, font=F[("r", 15)], fill=MUTED)
        fy = y + th + 6
        d.rectangle([PAD, fy + 4, PAD + 4, fy + th - 8], fill=YELLOW)
        d.text((PAD + 16, fy + 4), "With " + FIX_NAME[r["fix_kind"]], font=F[("s", 15)], fill=YELLOW)
        after_cat = "true" if r["after"] == "skin-true" else ("tweak" if r["group"] == "tweak" else "rework")
        pill(d, PAD + 16, fy + 30, after_cat, "WOULD BE " + CAT[after_cat][1])
        for c, i in enumerate(sel):
            pid = P[i]["id"]
            im.paste(Image.open(RENDER / "thumbs" / r["id"] / f"{pid}.jpg").convert("RGB").resize((tw, th), Image.LANCZOS), (gx(c), y))
            fp = RENDER / "thumbs_fix" / FIX_DIR[r["fix_kind"]] / r["id"] / f"{pid}.jpg"
            if fp.exists():
                im.paste(Image.open(fp).convert("RGB").resize((tw, th), Image.LANCZOS), (gx(c), fy))
        y = fy + th + 40
    d.text((PAD, y), CREDIT, font=F[("r", 15)], fill=MUTED)
    im = im.crop((0, 0, W, y + 40))
    im.save(path, quality=86, optimize=True)
    return path


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    made = [summary(OUT / "00-worst-looks-before-and-after.jpg")]
    print(made[0], flush=True)
    for i, sec in enumerate(ORDER, 1):
        ids = [lid for lid, l in LOOKS.items() if l["section"] == sec]
        ids.sort(key=lambda lid: (RANK[V[lid]["category"]], V[lid]["score"]))
        cnt = {c: sum(V[l]["category"] == c for l in ids) for c in RANK}
        sub = (f"{len(ids)} looks:  {cnt['true']} skin-true,  {cnt['tweak']} need a tweak,  {cnt['rework']} need rework."
               "  Best first.")
        slug = sec.lower().replace("&", "and").replace(" / ", "-").replace(" ", "-")
        path = OUT / f"{i:02d}-{slug}.jpg"
        sheet(sec, sub, ids, path)
        made.append(path)
        print(path, flush=True)
    pages = []
    for p in made:
        im = Image.open(p).convert("RGB")
        if im.width > 2000:
            im = im.resize((2000, im.height * 2000 // im.width), Image.LANCZOS)
        pages.append(im)
    pdf = OUT / "skin-test-contact-sheets.pdf"
    pages[0].save(pdf, save_all=True, append_images=pages[1:], resolution=150, quality=72)
    print(pdf)
