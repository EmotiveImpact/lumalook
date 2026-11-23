"""Ranked list: skin-true, needs a tweak (with the fix), drop or rework.

    python3 report.py RENDER_DIR OUT_DIR

Writes OUT_DIR/ranked-list.csv, OUT_DIR/ranked-list.md and
RENDER_DIR/ranked.json (used for the written report).
"""
import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RENDER = Path(sys.argv[1])
OUT = Path(sys.argv[2])
LOOKS = {l["id"]: l for l in json.loads((HERE / "looks.json").read_text())}
V = {v["id"]: v for v in json.loads((RENDER / "verdicts.json").read_text())}
FX = json.loads((RENDER / "fixes.json").read_text())
WORDS = {"crush": "crushed shadows", "dark": "skin too dark", "ashy": "ashy / grey",
         "green": "green cast", "magenta": "magenta cast", "oversat": "orange / red oversaturation"}
RANK = {"true": 0, "tweak": 1, "rework": 2}


def issues(v, n=3):
    return [WORDS[k] for k in v["issues"][:n] if k in WORDS and v["issue_weight"].get(k, 0) >= 1]


def tweak_text(lk, p):
    r = lk["recipe"]
    ch = []
    for k in ("contrast", "saturation", "brightness", "vignette"):
        if abs(p[k] - r[k]) > 1e-6:
            ch.append(f"{k} {r[k]:g} to {p[k]:g}")
    if p["wb_scale"] < 1:
        if r["temperature"] != 6500:
            ch.append(f"temperature {r['temperature']:g} K to about {p['temperature']:g} K")
        if r["tint"]:
            ch.append(f"tint {r['tint']:g} to {p['tint']:g}")
    return ", ".join(ch)


def outcome(r):
    """How a fixed look ends up, in words."""
    if r["category"] == "true":
        return "skin-true"
    return f"nearly: {r['bad_main']} bad, {r['warn_main']} mild"


def decide(lid):
    v, lk, fx = V[lid], LOOKS[lid], FX.get(lid, {})
    row = dict(id=lid, section=lk["section"], code=lk["code"], name=lk["name"],
               kind="recipe" if lk["recipe"] else "film cube", free=lk["free"],
               now=v["category"], score=v["score"], bad_main=v["bad_main"], warn_main=v["warn_main"],
               bad_neon=v["bad_neon"], chart_bad=v["chart_bad"], stress_lost=len(v["stress_lost"]),
               problems=", ".join(issues(v)), mono=v["mono"], at75=v["at75"]["category"])
    if v["category"] == "true":
        row.update(group="skin-true", fix="", after="skin-true", fix_kind="", after_bad=v["bad_main"])
        return row
    cands = []   # (after verdict, fix kind, text)
    if row["kind"] == "recipe":
        e, t = fx.get("engine"), fx.get("tweak")
        if e:
            cands.append((e, "engine", "Engine fix only; no recipe change."))
        if t and not t.get("none_found"):
            cands.append((t, "engine+recipe", "Engine fix, then " + tweak_text(lk, t["params"]) + "."))
    else:
        g, si = fx.get("guard"), fx.get("safe_intensity")
        if si and si >= 0.75:
            cands.append(({"category": "true", "bad_main": 0, "warn_main": 0}, "intensity",
                          f"Ship with the default intensity at {int(si * 100)}%."))
        if g:
            kind = "shadow floor" if v["mono"] else "skin guard"
            txt = ("Bake a shadow floor into the cube (the deepest tones keep their separation)." if v["mono"] else
                   "Bake the skin guard into the cube (skin hue, chroma and depth held close to the photo).")
            if si and si >= 0.75:
                txt += f" Or leave the cube and default to {int(si * 100)}%."
            cands.append((g, kind, txt))
    def key(c):
        r = c[0]
        # skin-true first; then fewest bad frames; the skin guard beats a
        # lower intensity (it keeps the look at full strength)
        return (RANK[r["category"]], r["bad_main"], r.get("warn_main", 0), c[1] == "intensity")
    if not cands:
        row.update(group="rework", fix="No fix found. Rebuild, or drop.", after="?", fix_kind="rework", after_bad=None)
        return row
    cands.sort(key=key)
    # prefer the guard over intensity when both reach skin-true
    best = cands[0]
    if best[1] == "intensity":
        for c in cands[1:]:
            if c[0]["category"] == "true":
                best = c
                break
    r, kind, txt = best
    ok = r["category"] == "true" or (r["category"] == "tweak" and r["bad_main"] <= 1)
    if ok:
        row.update(group="tweak", fix_kind=kind, fix=txt, after=outcome(r), after_bad=r["bad_main"])
    else:
        row.update(group="rework", fix_kind=kind, after=outcome(r).replace("nearly", "still"),
                   after_bad=r["bad_main"],
                   fix=f"Best small fix tried: {txt[0].lower() + txt[1:]} It still leaves {r['bad_main']} of 10 frames bad, "
                       + ("so rebuild the recipe around skin." if row["kind"] == "recipe" else "so rebuild the cube or drop it."))
    return row


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    rows = [decide(lid) for lid in LOOKS]
    order = {"skin-true": 0, "tweak": 1, "rework": 2}
    rows.sort(key=lambda r: (order[r["group"]], RANK[r["now"]], r["score"]))
    for r in rows:
        r["name"] = r["name"].strip()
        r["look"] = f"{r['code']} {r['name']}".strip()
    for i, r in enumerate(rows, 1):
        r["rank"] = i
    cols = ["rank", "group", "section", "code", "name", "kind", "now", "bad_main", "warn_main", "chart_bad",
            "stress_lost", "at75", "problems", "fix", "after", "score", "id"]
    with open(OUT / "ranked-list.csv", "w", newline="") as f:
        w = csv.DictWriter(f, cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    (RENDER / "ranked.json").write_text(json.dumps(rows, indent=1))
    titles = {"skin-true": "Skin-true as they are", "tweak": "Need a tweak (fix in the last column)",
              "rework": "Drop or rework"}
    md = ["# Lumalook skin test: ranked list", "",
          "Every look, ranked within each group from best to worst. 'Bad' counts the 10 main test frames "
          "(daylight, warm indoor and backlit; neon and the two extreme low-key frames are counted separately).", ""]
    for g in ("skin-true", "tweak", "rework"):
        sel = [r for r in rows if r["group"] == g]
        md += [f"## {titles[g]} ({len(sel)})", ""]
        if g == "skin-true":
            md += ["| # | Pack | Look | Kind | Mild flags |", "|---|---|---|---|---|"]
            md += [f"| {r['rank']} | {r['section']} | {r['look']} | {r['kind']} | {r['warn_main']} |" for r in sel]
        else:
            md += ["| # | Pack | Look | Now | What goes wrong | Suggested fix | After the fix |", "|---|---|---|---|---|---|---|"]
            md += [f"| {r['rank']} | {r['section']} | {r['look']} | {r['bad_main']}/10 bad, {r['warn_main']} mild | "
                   f"{r['problems'] or 'mild shifts'} | {r['fix']} | {r['after']} |" for r in sel]
        md.append("")
    (OUT / "ranked-list.md").write_text("\n".join(md))
    from collections import Counter
    print(Counter(r["group"] for r in rows))
    print(Counter((r["kind"], r["group"]) for r in rows))
    print(Counter(r["fix_kind"] for r in rows))
