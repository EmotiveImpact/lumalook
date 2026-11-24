"""Rules the app's own source has to keep, so nothing goes around True Colour.

    python3 source_rules.py

The skin test bakes looks through TrueColour.swift, LUTParser.swift and
LUTDensifier.swift only, so a change elsewhere in the app could bring the old
deep-skin bug back without any look's bake changing. This reads the Swift
sources and fails on the known ways to do that:

  1. Apple's stock CIColorControls filter anywhere it is not listed below.
     Its contrast and brightness work on raw light values and crush deep skin
     to black: that was the original bug. Tone goes through
     TrueColour.toneFilter.
  2. LookPipeline no longer sending recipes, the sliders and overlays through
     TrueColour.toneFilter, or creative LUTs through the skin guard.
  3. The Grade Room's colour cubes (curves, wheels, HSL bands, split tone, in
     ColorMath.swift) applied with Apple's plain CIColorCube filter. Those
     cubes hold the numbers a screen shows; the plain filter works on raw
     light values, where every control did several times what its number
     said. That made the Skin first presets milky and teal (24 Nov 2026).
     They go through CIColorCubeWithColorSpace, as True Colour's cubes do.
     tools/skin-test/check_grade.swift checks the result on real Core Image.
  4. The Shadows and Highlights sliders going back to Apple's
     CIHighlightShadowAdjust filter. It works on each channel in raw light
     values around a blur: Shadows pulled down took the green and blue out
     of deep skin, Highlights pulled down did a tenth of what Shadows did,
     and an exported cube did not match the picture. They are one curve on
     lightness, TrueColour.shadowHighlightFilter.
  5. A playing preview handing the pipeline a frame clamped to its extent.
     Such a frame has no bounds, so the lens was skipped and the vignette,
     halation and wipe had nothing to measure against: the preview was not
     the clip that got saved. Frames go in with their bounds, as the export
     sends them; the blurs clamp their own input.

gate.py runs this too. Exit code 0 when the rules hold, 1 when one is broken.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
APP = REPO / "LumaLook"

# Every use of CIColorControls the app is allowed, as file -> how many, and
# why each is safe. A new use fails until someone adds it here on purpose.
ALLOWED_COLOR_CONTROLS = {
    # the VHS effect: saturation only, which does not touch how dark skin is
    "Engine/EffectRenderer.swift": 1,
    # the blurred fill behind a letterboxed picture: never the picture itself
    "Engine/LumaCompositor.swift": 1,
}

# What LookPipeline has to keep calling, and at least how many times.
PIPELINE_MUST_CALL = {
    # recipes, the Exposure/Contrast/Saturation sliders, overlay adjustments, the Plastic lens
    "TrueColour.toneFilter(": 4,
    # the creative LUT slot, with the skin guard
    "TrueColour.lutData(": 1,
    # the Shadows and Highlights sliders
    "TrueColour.shadowHighlightFilter(": 1,
}


# Files whose cubes are worked out on screen (sRGB) numbers, so must be
# applied to screen numbers.
SCREEN_NUMBER_CUBES = ["Engine/ColorMath.swift"]


def code_only(text):
    """Swift source with comments blanked out (strings are left alone)."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def check(app=APP):
    """A list of broken rules as plain sentences; empty when all hold."""
    problems = []
    found = {}
    for path in sorted(app.rglob("*.swift")):
        n = len(re.findall(r"colorControls\s*\(|CIColorControls", code_only(path.read_text(errors="replace"))))
        if n:
            found[path.relative_to(app).as_posix()] = n
    for name, n in sorted(found.items()):
        allowed = ALLOWED_COLOR_CONTROLS.get(name, 0)
        if n > allowed:
            problems.append(
                f"{name} uses Apple's CIColorControls filter {n} time{'s' if n > 1 else ''} "
                f"({allowed} allowed). Its contrast and brightness crush deep skin; send tone through "
                "TrueColour.toneFilter. If this use is saturation only, or never touches a person's picture, "
                "add it to ALLOWED_COLOR_CONTROLS in tools/skin-test/source_rules.py with the reason.")
    pipeline = app / "Engine" / "LookPipeline.swift"
    if not pipeline.exists():
        problems.append("LumaLook/Engine/LookPipeline.swift is missing; update tools/skin-test/source_rules.py "
                        "to point at the file that applies looks.")
    else:
        code = code_only(pipeline.read_text(errors="replace"))
        for call, least in PIPELINE_MUST_CALL.items():
            n = code.count(call)
            if n < least:
                problems.append(
                    f"LookPipeline.swift calls {call}...) {n} time{'s' if n != 1 else ''}, fewer than the {least} it "
                    "needs: a recipe, slider, overlay, lens or LUT path has stopped going through True Colour.")
        if re.search(r'highlightShadowAdjust\s*\(|"CIHighlightShadowAdjust"', code):
            problems.append(
                "LookPipeline.swift uses Apple's CIHighlightShadowAdjust filter. It works on each channel in raw "
                "light values around a blur: it takes the colour out of deep skin when shadows are pulled down, "
                "and an exported cube cannot carry it. Shadows and Highlights go through "
                "TrueColour.shadowHighlightFilter.")
    for path in sorted(app.rglob("*.swift")):
        code = code_only(path.read_text(errors="replace"))
        if re.search(r"\.apply\(\s*state:", code) and re.search(r"sourceImage\s*\.clampedToExtent\(\)", code):
            problems.append(
                f"{path.relative_to(app).as_posix()} clamps a video frame to its extent and grades it. A clamped "
                "frame has no bounds, so the lens is skipped and the vignette, halation and wipe are drawn "
                "against nothing: the preview stops matching the saved clip. Hand the pipeline the frame as it "
                "is (request.sourceImage); its blurs clamp their own input.")
    for name in SCREEN_NUMBER_CUBES:
        path = app / name
        if not path.exists():
            problems.append(f"LumaLook/{name} is missing; update SCREEN_NUMBER_CUBES in "
                            "tools/skin-test/source_rules.py to point at the file that builds the Grade Room's cubes.")
            continue
        code = code_only(path.read_text(errors="replace"))
        plain = len(re.findall(r'"CIColorCube"|\.colorCube\s*\(', code))
        spaced = len(re.findall(r'"CIColorCubeWithColorSpace"|\.colorCubeWithColorSpace\s*\(', code))
        if plain or not spaced:
            problems.append(
                f"{name} applies a colour cube with Apple's plain CIColorCube filter"
                + (f" ({plain} time{'s' if plain != 1 else ''})" if plain else " (no CIColorCubeWithColorSpace found)")
                + ". Its cubes hold the numbers a screen shows, and the plain filter works on raw light values: "
                "curves, wheels, HSL bands and split tones come out several times too strong. "
                "Use CIColorCubeWithColorSpace with sRGB.")
    return problems


if __name__ == "__main__":
    broken = check()
    if not broken:
        print("PASS: nothing in the app's source goes around True Colour.")
        sys.exit(0)
    print("FAIL: the app's source breaks a True Colour rule.")
    for p in broken:
        print("  -", p)
    sys.exit(1)
