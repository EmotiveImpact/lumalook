"""Try a film LUT against the skin test before it goes anywhere near the app.

    python3 check_look.py NEW.cube [MORE.cube ...] [--sheet OUT.jpg]
    python3 check_look.py --self-test

For each .cube file this says what the look does to Black and brown skin,
twice: as its author made it, and as Lumalook would show it (True Colour on,
through the skin guard). It then says PASS or FAIL by the rule for new looks
in gate.py: skin-true at the app's 75% default, never "needs rework", and the
deepest skin tone keeps at least 0.20 lightness. A failure names the problem
and what to change in the LUT.

No Mac needed: the skin guard is worked out here by a Python copy of the
app's maths. `--self-test` proves the copy still matches the app, by
comparing it with the Mac runner's bake of every film look in the app.
Recipe looks (contrast, warmth and so on) are not checked here, because their
warmth runs through Core Image; add the look to the app on a claude/ branch
and the gate tests it on the Mac runner.

`--sheet` saves a picture: four test portraits, one per kind of light, as
shot, as the LUT's author made it, and as the app shows it, all at 75%.

Exit code 0 when every file passes, 1 when any fails.
"""
import argparse
import os
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
SHEET_PORTRAITS = ["day-pexels-31579771", "warm-pexels-5760943", "night-pexels-7194024", "back-pexels-29037457"]


def is_monochrome(cube, S):
    """TrueColour.isMonochrome: colourful inputs keep under 15% of their chroma."""
    n = cube.shape[0]
    idx = np.arange(0, n, max(1, n // 9))
    x = S.srgb_to_lab(S.identity_cube(n)[np.ix_(idx, idx, idx)].reshape(-1, 3))
    y = S.srgb_to_lab(cube[np.ix_(idx, idx, idx)].reshape(-1, 3))
    cx = np.hypot(x[:, 1], x[:, 2])
    keep = cx > 20
    if not keep.any():
        return False
    ratios = np.sort(np.hypot(y[keep, 1], y[keep, 2]) / cx[keep])
    return bool(ratios[len(ratios) // 2] < 0.15)


def as_the_app_shows_it(raw, F, S):
    """LookPipeline.loadLUT + TrueColour.lutData: small cubes are smoothed up
    to 64 a side, then colour looks get the skin guard and black-and-white
    looks get the shadow floor."""
    dense = F.resample(raw, 64, clip=False) if raw.shape[0] < 48 else raw
    mono = is_monochrome(dense, S)
    return (F.mono_floor(dense) if mono else F.skin_guard(dense)), mono


def own_input_range(path):
    for line in path.read_text(errors="replace").splitlines()[:40]:
        parts = line.split()
        if parts and parts[0].upper() in ("DOMAIN_MIN", "DOMAIN_MAX"):
            want = 0.0 if parts[0].upper() == "DOMAIN_MIN" else 1.0
            if any(abs(float(v) - want) > 1e-6 for v in parts[1:4]):
                return True
    return False


def sheet(path, rows, F, S, T):
    from PIL import Image, ImageDraw, ImageFont
    fonts = HERE.parents[1] / "LumaLook/Resources/Fonts"
    try:
        f_head = ImageFont.truetype(str(fonts / "Inter-SemiBold.otf"), 22)
        f_small = ImageFont.truetype(str(fonts / "Inter-Medium.otf"), 16)
    except OSError:
        f_head = f_small = ImageFont.load_default()
    tw, th, gap, left, top = 216, 270, 6, 250, 70
    cols = ["As shot", "As its author made it", "In Lumalook (True Colour on)"]
    w = left + len(SHEET_PORTRAITS) * 3 * (tw + gap) + 20
    canvas = Image.new("RGB", (w, top + len(rows) * (th + 44) + 20), (11, 11, 12))
    d = ImageDraw.Draw(canvas)
    d.text((20, 18), "New looks on the skin test portraits, at the app's 75% default", font=f_head, fill=(236, 236, 236))
    y = top
    for name, verdict, raw, shown in rows:
        d.text((20, y + 6), name[:26], font=f_head, fill=(236, 236, 236))
        d.text((20, y + 40), verdict, font=f_small, fill=(120, 220, 140) if verdict.startswith("PASS") else (255, 110, 100))
        x = left
        for pid in SHEET_PORTRAITS:
            im = F._IMS[pid]
            for label, cube in zip(cols, (None, raw, shown)):
                out = im if cube is None else S.grade(im, {"lut": cube, "recipe": None}, 0.75)
                tile = Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8)).resize((tw, th), Image.LANCZOS)
                canvas.paste(tile, (x, y))
                d.text((x + 2, y + th + 6), label, font=f_small, fill=(150, 150, 156))
                x += tw + gap
        y += th + 44
    canvas.save(path, quality=90)


def main():
    ap = argparse.ArgumentParser(description="Skin test for a new film LUT.")
    ap.add_argument("cubes", nargs="*", help=".cube files")
    ap.add_argument("--sheet", default="", help="save a picture of the looks on four test portraits")
    ap.add_argument("--self-test", action="store_true", help="check this tool's guard against the app's")
    a = ap.parse_args()
    if not a.cubes and not a.self_test:
        ap.error("give at least one .cube file, or --self-test")
    if not (HERE / "out" / "portraits").exists():
        print("Test portraits are not prepared. Run: python3 tools/skin-test/prep_portraits.py")
        return 1

    # The measuring code reads its scratch folder from argv when it is imported.
    sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix="skin-check-")]
    import fixes as F
    import gate as G
    import run_test as T
    import skinlib as S
    import verify as V
    F._init()

    if a.self_test:
        grid = S.identity_cube(25)
        bake = Path(os.environ.get("VERIFY_BAKE") or HERE / "out")     # as verify.py and gate.py
        worst, over, n = 0.0, 0, 0
        for look in F._LOOKS.values():
            if not look["cube"]:
                continue
            shown, _ = as_the_app_shows_it(look["lut"], F, S)
            # the Mac bake reads the guarded cube back through Core Image on a 25-point lattice
            gap = np.abs(S.sample_trilinear(shown, grid) - S.read_baked(bake / "film_tc" / f"{look['id']}.u16")).max() * 255
            worst, over, n = max(worst, gap), over + (gap > 1.0), n + 1
        print(f"{n} film looks: this tool's guard and the app's differ by at most {worst:.2f} of 255 "
              f"({over} looks differ by more than 1).")
        if worst > 1.5:
            print("FAIL: the Python copy of the skin guard no longer matches TrueColour.swift. "
                  "Update fixes.skin_guard / fixes.mono_floor to match, or run the bake again.")
            return 1
        print("PASS: the Python copy matches the app.")
        if not a.cubes:
            return 0

    failed, rows = 0, []
    for arg in a.cubes:
        path = Path(arg)
        raw = S.read_cube(path)
        shown, mono = as_the_app_shows_it(raw, F, S)
        look = {"id": path.stem, "recipe": None}
        r = V.judge_variants(look, {"on": shown, "off": raw}, None)
        now = G.summarise(r)
        problems = G.judge(now, None)
        print(f"\n{path.name}  ({raw.shape[0]} points a side, {'black-and-white' if mono else 'colour'})")
        print(f"  as its author made it:  {G.WORD[r['off']['category']]} at full strength, "
              f"{G.WORD[r['off75']['category']]} at 75%")
        print(f"  in Lumalook:            {G.WORD[now['full']]} at full strength, {G.WORD[now['default']]} at 75%, "
              f"deepest skin tone keeps {now['monk10']:.3f} lightness")
        if own_input_range(path):
            print("  note: this file sets its own input range (DOMAIN_MIN/MAX). The app shows such a LUT as authored, "
                  "with no skin guard, so judge it by the first line.")
        if problems:
            failed += 1
            print("  FAIL: this look " + "; ".join(problems) + ".")
            for k in (r["on"]["issues"] or r["on75"]["issues"])[:3]:
                print(f"    what it does: {G.PROBLEM.get(k, k)}. Try: {G.REMEDY.get(k, 'see the rulebook')}.")
        else:
            print("  PASS")
        rows.append((path.stem, "PASS" if not problems else "FAIL: " + G.WORD[now["default"]] + " at 75%", raw, shown))

    if a.sheet:
        sheet(a.sheet, rows, F, S, T)
        print("\nPicture saved:", a.sheet)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
