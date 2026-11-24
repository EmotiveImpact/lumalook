"""Does the gate itself still work on looks nobody has added yet?

    python3 selftest_gate.py

gate.py is the rule for new looks, but on an ordinary day it only ever sees
looks that are already in the app. This pretends two looks were just added
and checks what the gate says about them, then checks the smaller rules one
by one:

  1. A new recipe look. It has today's bakes but no bake from before True
     Colour (out/luts), which is the state every new recipe is in. The gate
     must give it a verdict, not stall.
  2. A new film look that is only near at 75% (a copy of one in the app that
     is allowed that as an old look). The gate must turn it away.
  3. The lightness floor for new looks uses the exact measurement, not the
     rounded one.
  4. A film LUT that sets its own input range is turned away, by the gate's
     rule and by check_look.py.
  5. source_rules.py notices a new CIColorControls, a look path that no
     longer goes through True Colour, the Grade Room's cubes going back
     to the plain cube filter, Shadows and Highlights going back to Apple's
     filter, a preview that grades a frame without bounds, and a place that
     grades video frames without their time.

It adds two entries to looks.json and four small files under out/ while it
runs and takes them away again. Exit code 0 when everything holds.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
LOOKS = HERE / "looks.json"
RECIPE_ID, FILM_ID = "selftest-new-recipe", "selftest-new-film"
ADDED = [OUT / "luts_tc" / f"{RECIPE_ID}.u16", OUT / "luts_classic" / f"{RECIPE_ID}.u16",
         OUT / "film_tc" / f"{FILM_ID}.u16"]

results = []


def check(ok, name, detail=""):
    results.append(ok)
    print(("  ok    " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def run(*args):
    p = subprocess.run([sys.executable, *args], capture_output=True, text=True, timeout=600)
    return p.returncode, p.stdout + p.stderr


def new_looks():
    """Cases 1 and 2: the gate on two pretend new looks."""
    original = LOOKS.read_text()
    looks = json.loads(original)
    base = json.loads((HERE / "baseline.json").read_text())["looks"]
    recipe = next(l for l in looks if l["recipe"] and (OUT / "luts_tc" / f"{l['id']}.u16").exists())
    near = next((l for l in looks if l["cube"] and base.get(l["id"], {}).get("default") == "tweak"), None)
    try:
        added = [dict(recipe, id=RECIPE_ID, code="ST1", name="Selftest Recipe")]
        for d in ("luts_tc", "luts_classic"):
            shutil.copy(OUT / d / f"{recipe['id']}.u16", OUT / d / f"{RECIPE_ID}.u16")
        if near:
            added.append(dict(near, id=FILM_ID, code="ST2", name="Selftest Film"))
            shutil.copy(OUT / "film_tc" / f"{near['id']}.u16", OUT / "film_tc" / f"{FILM_ID}.u16")
        LOOKS.write_text(json.dumps(looks + added, indent=1))
        try:
            code, out = run(str(HERE / "gate.py"), "--no-extract", "--only", "selftest-new-")
        except subprocess.TimeoutExpired:
            code, out = -1, "the gate did not finish in ten minutes"
    finally:
        LOOKS.write_text(original)
        for f in ADDED:
            f.unlink(missing_ok=True)

    has_before = (OUT / "luts" / f"{RECIPE_ID}.u16").exists()
    listed = next((l for l in out.splitlines() if "new since the baseline" in l), "")
    failing = out.split("FAIL:", 1)[1] if "FAIL:" in out else ""
    check(not has_before and "ST1 Selftest Recipe" in listed and RECIPE_ID not in failing,
          "a new recipe look, with no bake from before True Colour, gets a verdict and passes",
          f"like {recipe['name']}" if "ST1" in listed else out.strip().splitlines()[-1][:120] if out.strip() else "no output")
    if near:
        check(code == 1 and FILM_ID in failing and "new looks must be skin-true there" in failing,
              "a new film look that is only near at 75% is turned away, with the reason",
              f"a copy of {near['name']}, which is allowed that as a look already in the app")
    else:
        print("  note  no look in the app is near at 75% any more, so there is nothing to copy for case 2")


def floor_rule():
    sys.argv = [sys.argv[0]]
    import gate as G
    look = {"full": "true", "default": "true", "bad_frames": 0, "monk10": 0.2}      # 0.1998 rounds to 0.200
    under = G.judge(look, None, floor_ok=False)
    over = G.judge(look, None, floor_ok=True)
    check(len(under) == 1 and "deepest skin tone" in under[0] and not over,
          "a new look a hair under the lightness floor fails even though it rounds to 0.200")
    old = G.judge(look, dict(look), floor_ok=False)
    check(not old, "a look already in the app is held to its own recorded result, not to the floor for new looks")


def input_range():
    import skinlib as S
    head = "TITLE \"selftest\"\nLUT_3D_SIZE 2\n"
    body = "".join(f"{r} {g} {b}\n" for b in (0, 1) for g in (0, 1) for r in (0, 1))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "plain.cube").write_text(head + body)
        (tmp / "stated.cube").write_text(head + "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n" + body)
        (tmp / "wide.cube").write_text(head + "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 4 4 4\n" + body)
        check(not S.own_input_range(tmp / "plain.cube") and not S.own_input_range(tmp / "stated.cube")
              and S.own_input_range(tmp / "wide.cube"),
              "a cube that sets its own input range is recognised; the standard range, stated or not, is not")
        bundled = sorted(S.FILM_DIR.glob("*.cube"))
        own = [p.name for p in bundled if S.own_input_range(p)]
        check(not own, f"none of the {len(bundled)} film LUTs in the app sets its own input range", ", ".join(own[:4]))
        code, out = run(str(HERE / "check_look.py"), str(tmp / "wide.cube"))
        check(code == 1 and "sets its own input range" in out and "PASS" not in out,
              "check_look.py turns such a file away and does not give it a verdict it cannot stand behind")


def source():
    import source_rules as R
    engine = R.APP / "Engine"
    check(not R.check(), "the app's source as it stands keeps the True Colour rules")
    with tempfile.TemporaryDirectory() as tmp:
        app = Path(tmp) / "LumaLook"
        (app / "Engine").mkdir(parents=True)
        (app / "Data").mkdir()
        for name in ("LookPipeline.swift", "EffectRenderer.swift", "LumaCompositor.swift", "ColorMath.swift",
                     "VideoExporter.swift", "CameraController.swift"):
            shutil.copy(engine / name, app / "Engine" / name)
        shutil.copy(R.APP / "Data" / "AppModel.swift", app / "Data" / "AppModel.swift")
        check(not R.check(app), "a copy of the seven files that matter passes on its own")
        (app / "Screens").mkdir()
        (app / "Screens" / "New.swift").write_text(
            "// CIColorControls in a comment is fine\nlet f = CIFilter.colorControls()\nf.contrast = 1.2\n")
        found = R.check(app)
        check(len(found) == 1 and "Screens/New.swift" in found[0],
              "a new use of Apple's CIColorControls anywhere in the app is caught (a mention in a comment is not)")
        (app / "Screens" / "New.swift").unlink()
        pipeline = app / "Engine" / "LookPipeline.swift"
        text = pipeline.read_text()
        pipeline.write_text(text.replace("TrueColour.toneFilter(", "Old.toneFilter(", 1))
        found = R.check(app)
        check(len(found) == 1 and "TrueColour.toneFilter(" in found[0],
              "a look path in LookPipeline that stops going through True Colour is caught")
        pipeline.write_text(text.replace("TrueColour.lutData(", "raw(", 1))
        found = R.check(app)
        check(len(found) == 1 and "TrueColour.lutData(" in found[0],
              "a creative LUT that stops going through the skin guard is caught")
        pipeline.write_text(text.replace("TrueColour.shadowHighlightFilter(", "old(", 1)
                            + "\nlet hs = CIFilter.highlightShadowAdjust()\n")
        found = R.check(app)
        check(len(found) == 2 and any("TrueColour.shadowHighlightFilter(" in f for f in found)
              and any("CIHighlightShadowAdjust" in f for f in found),
              "Shadows and Highlights going back to Apple's CIHighlightShadowAdjust filter is caught")
        pipeline.write_text(text)
        (app / "Screens" / "Player.swift").write_text(
            "let source = request.sourceImage.clampedToExtent()\n"
            "let out = pipeline.apply(state: state, to: source)\n")
        found = R.check(app)
        check(len(found) == 1 and "Screens/Player.swift" in found[0] and "no bounds" in found[0],
              "a preview that clamps a video frame to its extent before grading it is caught")
        (app / "Screens" / "Player.swift").unlink()
        editor = app / "Engine" / "LumaCompositor.swift"
        text = editor.read_text()
        editor.write_text(text.replace("includeSplit: false, at: seconds)", "includeSplit: false)", 1))
        found = R.check(app)
        check(len(found) == 1 and "Engine/LumaCompositor.swift" in found[0] and "grain" in found[0],
              "a place that grades video frames without telling the pipeline when each frame is, is caught")
        editor.write_text(text)
        maths = app / "Engine" / "ColorMath.swift"
        text = maths.read_text()
        maths.write_text(text.replace('CIFilter(name: "CIColorCubeWithColorSpace")', 'CIFilter(name: "CIColorCube")', 1))
        found = R.check(app)
        check(len(found) == 1 and "Engine/ColorMath.swift" in found[0] and "plain CIColorCube" in found[0],
              "the Grade Room's cubes going back to Apple's plain CIColorCube filter is caught "
              "(a mention in a comment is not)")
        maths.write_text(text)
        check(not R.check(app), "and put back, the copy passes again")


if __name__ == "__main__":
    if not (OUT / "portraits").exists():
        print("Test portraits are not prepared. Run: python3 tools/skin-test/prep_portraits.py")
        sys.exit(1)
    for f in ADDED:                      # left over from a run that was stopped half way
        f.unlink(missing_ok=True)
    sys.path.insert(0, str(HERE))
    print("The gate, on looks nobody has added yet")
    new_looks()
    floor_rule()
    input_range()
    source()
    bad = results.count(False)
    print(f"\n{len(results)} checks, {bad} failed")
    sys.exit(1 if bad else 0)
