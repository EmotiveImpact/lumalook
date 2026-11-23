"""The gate: what every look has to pass before it ships.

    python3 gate.py                  check every look
    python3 gate.py --only neon,cp   only looks whose id contains one of these
    python3 gate.py --accept         record today's results as the new baseline

Every look is judged the way people see it in the app, with True Colour on:
recipe looks through the engine's lightness-only tone, film cubes through the
skin guard. Both come from the Mac runner's bake of the app's own code
(out/luts_tc, out/film_tc), so this needs no Mac. It runs the same yardstick
as the skin test: 16 portraits of Black and brown skin in four kinds of light,
plus the Monk skin-tone chart.

The rules
  1. No look may need rework: not at full strength, not at the 75% the app
     opens every look at.
  2. A look already in the app may not get worse than its line in
     baseline.json (verdict at full strength, verdict at 75%, number of
     portraits it fails, and how much lightness the deepest skin tone keeps).
  3. A new look has to be skin-true at 75%, and its deepest skin tone (Monk
     10) has to keep at least 0.20 lightness (Oklab L) at full strength.

A failure prints what went wrong and what to change. `--accept` is for the
rare time a result is a decision, not an accident: it rewrites baseline.json,
which then shows up in the pull request for someone to agree to.

Exit code 0 when everything passes, 1 when anything fails.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter
from multiprocessing import Pool
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE = HERE / "baseline.json"
RANK = {"true": 0, "tweak": 1, "rework": 2}
WORD = {"true": "skin-true", "tweak": "near", "rework": "needs rework"}
MONK10_FLOOR = 0.20
MONK10_SLACK = 0.005

PROBLEM = {
    "crush": "shadows crushed, deep skin loses its detail",
    "dark": "skin pushed too dark",
    "ashy": "skin goes ashy or grey",
    "green": "green or sallow cast on skin",
    "magenta": "magenta or pink cast on skin",
    "oversat": "skin turns orange or red",
    "mono_flat": "flat, muddy black-and-white",
}
REMEDY = {
    "crush": "lower the contrast, or raise the brightness a little; for a film cube, lift its shadows",
    "dark": "raise the brightness, or lower the contrast",
    "ashy": "raise the saturation; for a film cube, give skin tones more colour",
    "green": "move the tint towards magenta, or warm the look up",
    "magenta": "move the tint towards green",
    "oversat": "lower the saturation, or pull the warmth back",
    "mono_flat": "raise the contrast a little so faces keep their shape",
}


def summarise(r):
    """The four facts the gate keeps about one look."""
    return {"full": r["on"]["category"], "default": r["on75"]["category"],
            "bad_frames": r["on"]["bad_main"], "monk10": r["on_targets"]["mst10_L"]}


def judge(now, old):
    """Problems with one look: a list of plain sentences, empty when it passes."""
    out = []
    if now["full"] == "rework":
        out.append("needs rework at full strength")
    if now["default"] == "rework":
        out.append("needs rework even at the 75% the app opens it at")
    if old is None:
        if now["default"] != "true":
            out.append("is a new look and is only " + WORD[now["default"]] + " at 75%; new looks must be skin-true there")
        if now["monk10"] < MONK10_FLOOR:
            out.append(f"is a new look and takes the deepest skin tone down to {now['monk10']:.3f} lightness; "
                       f"new looks must keep {MONK10_FLOOR:.2f}")
        return out
    for key, where in (("full", "at full strength"), ("default", "at 75%")):
        if RANK[now[key]] > RANK[old[key]]:
            out.append(f"was {WORD[old[key]]} {where} and is now {WORD[now[key]]}")
    if now["bad_frames"] > old["bad_frames"]:
        out.append(f"now fails {now['bad_frames']} portraits at full strength, up from {old['bad_frames']}")
    if now["monk10"] < old["monk10"] - MONK10_SLACK:
        out.append(f"deepest skin tone fell from {old['monk10']:.3f} to {now['monk10']:.3f} lightness")
    return out


def main():
    ap = argparse.ArgumentParser(description="The skin-true gate for every look.")
    ap.add_argument("--only", default="", help="comma-separated parts of look ids")
    ap.add_argument("--accept", action="store_true", help="record today's results as the baseline")
    ap.add_argument("--no-extract", action="store_true", help="use looks.json as it is")
    a = ap.parse_args()

    if not a.no_extract:
        subprocess.run([sys.executable, str(HERE / "extract_looks.py")], check=True, stdout=subprocess.DEVNULL)
    looks = json.loads((HERE / "looks.json").read_text())
    names = {l["id"]: f"{l['code']} {l['name']}".strip() for l in looks}
    only = [s for s in a.only.split(",") if s]
    ids = [l["id"] for l in looks if not only or any(s in l["id"] for s in only)]

    missing = [l["id"] for l in looks if l["id"] in ids and not
               (HERE / "out" / ("luts_tc" if l["recipe"] else "film_tc") / f"{l['id']}.u16").exists()]
    if missing:
        print(f"{len(missing)} looks have not been through the Mac runner's bake yet:")
        for lid in missing:
            print("  ", lid, "-", names[lid])
        print("Push to a claude/ branch (the Skin test bake workflow runs and commits the bake), then run this again.")
        return 1
    if not (HERE / "out" / "portraits").exists():
        print("Test portraits are not prepared. Run: python3 tools/skin-test/prep_portraits.py")
        return 1

    # The measuring code reads its scratch folder from argv when it is imported.
    scratch = Path(tempfile.mkdtemp(prefix="skin-gate-"))
    (scratch / "chart_fix").mkdir()
    os.environ["VERIFY_NO_THUMBS"] = "1"
    sys.argv = [sys.argv[0], str(scratch)]
    import fixes as F
    import verify as V

    results = {}
    with Pool(4, initializer=F._init) as pool:
        for r in pool.imap_unordered(V.job, ids):
            results[r["id"]] = r
    now = {lid: summarise(results[lid]) for lid in ids}

    if a.accept:
        kept = json.loads(BASELINE.read_text())["looks"] if BASELINE.exists() and only else {}
        kept.update(now)
        all_ids = {l["id"] for l in looks}
        BASELINE.write_text(json.dumps({
            "what": "The skin test result of every look, True Colour on. gate.py fails a change that makes "
                    "any of these worse. Rewritten only with `gate.py --accept`.",
            "looks": {k: kept[k] for k in sorted(kept) if k in all_ids}}, indent=1) + "\n")
        print(f"Baseline recorded for {len(now)} looks -> {BASELINE.name}")

    base = json.loads(BASELINE.read_text())["looks"] if BASELINE.exists() else {}
    failures, new = [], []
    for lid in ids:
        if lid not in base:
            new.append(lid)
        problems = judge(now[lid], base.get(lid))
        if problems:
            failures.append((lid, problems))

    full, default = Counter(n["full"] for n in now.values()), Counter(n["default"] for n in now.values())
    print(f"{len(ids)} looks, True Colour on")
    print(f"  full strength: {full['true']} skin-true, {full['tweak']} near, {full['rework']} need rework")
    print(f"  75% default:   {default['true']} skin-true, {default['tweak']} near, {default['rework']} need rework")
    print(f"  deepest skin tone keeps at least {min(n['monk10'] for n in now.values()):.3f} lightness on every look")
    edge = [names[i] for i in ids if now[i]["default"] != "true"]
    if edge:
        print(f"  still only near at 75% (allowed for looks already in the app, not for new ones): {', '.join(edge)}")
    if new:
        print(f"  new since the baseline: {', '.join(names[i] for i in new)}")
    gone = sorted(set(base) - {l["id"] for l in looks})
    if gone:
        print(f"  in the baseline but no longer in the app: {', '.join(gone)}")

    if not failures:
        print("PASS: every look meets the rules.")
        return 0
    print(f"\nFAIL: {len(failures)} look{'s' if len(failures) > 1 else ''} did not pass.")
    for lid, problems in failures:
        r = results[lid]
        print(f"\n  {names[lid]}  ({lid}, {r['kind']})")
        for p in problems:
            print("    -", p)
        issues = r["on"]["issues"] or r["on75"]["issues"]
        for k in issues[:3]:
            print(f"    what it does: {PROBLEM.get(k, k)}. Try: {REMEDY.get(k, 'see the rulebook')}.")
    print("\nSee the pictures: python3 tools/skin-test/try_photos.py OUT.jpg tools/skin-test/out/portraits/*.png --looks <id>")
    print("If a result is a decision and not an accident: python3 tools/skin-test/gate.py --accept")
    return 1


if __name__ == "__main__":
    sys.exit(main())
