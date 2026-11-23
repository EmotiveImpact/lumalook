"""Turn the raw skin numbers into flags, a verdict per look and a ranking.

    python3 analyse.py RENDER_DIR
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RENDER = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "out" / "render"

P = json.loads((HERE / "portraits.json").read_text())
LOOKS = json.loads((HERE / "looks.json").read_text())
PORTRAIT = {p["id"]: p for p in P}
# Stress tests: skin that sits at the very bottom of the range (low-key studio,
# a face into the sun). Reported on their own so one extreme frame does not
# decide a look, but a look that loses these faces is called out.
STRESS = {"day-pexels-31579771", "back-pexels-14253763"}
NEON = {p["id"] for p in P if p["light"] == "Night / neon"}

WARN, BAD = 1, 3
NAMES = {
    "crush": "crushed shadows",
    "dark": "skin pushed too dark",
    "ashy": "ashy / grey",
    "green": "green or sallow cast",
    "magenta": "magenta / pink cast",
    "oversat": "orange / red oversaturation",
    "mono_flat": "flat, muddy mono",
}


def portrait_flags(s, mono):
    """Flags for one look on one portrait: {flag: severity}."""
    f = {}
    def put(k, v):
        if v:
            f[k] = max(f.get(k, 0), v)
    clip = s["clip_after"] - s["clip_before"]
    put("crush", BAD if clip > 0.10 or s["shadow_detail"] < 0.35 else WARN if clip > 0.03 or s["shadow_detail"] < 0.6 else 0)
    if s["L_dark_before"] >= 6 and s["L_dark_after"] < 3:
        put("crush", BAD)
    dL = s["L_after"] - s["L_before"]
    if s["L_before"] < 45:
        put("dark", BAD if dL < -14 else WARN if dL < -8 else 0)
    if mono:
        return f
    lost = s["L_after"] < 6          # colour gone because the skin went black: that is the crush
    if s["C_before"] >= 6 and not lost:
        cr = s["C_after"] / s["C_before"]
        put("ashy", BAD if cr < 0.6 else WARN if cr < 0.75 else 0)
        if (s["L_dark_after"] - s["L_dark_before"]) > 8 and cr < 0.9:
            put("ashy", WARN)        # milky, lifted blacks
        if s["C_after"] > 28:
            put("oversat", BAD if (cr > 1.6 and s["C_after"] > 34) else WARN if cr > 1.35 else 0)
    if s["C_before"] >= 8 and not lost and s["_id"] not in NEON:
        hue_flags(put, s["dh"], s["C_before"], s["C_after"])
    return f


def hue_flags(put, dh, cb, ca):
    """Hue shift counts only when it is big in degrees AND as a visible colour
    difference (CIE dH, in Lab units): on low-chroma skin a large angle can be
    a tiny colour change."""
    dH = 2 * np.sqrt(max(cb, 0) * max(ca, 0)) * abs(np.sin(np.radians(dh) / 2))
    put("green", BAD if (dh > 15 and dH > 6.5) else WARN if (dh > 8 and dH > 3.5) else 0)
    put("magenta", BAD if (dh < -18 and dH > 7.5) else WARN if (dh < -10 and dH > 4.5) else 0)


def chart_flags(chart, mono):
    """Flags from the Monk chart: per light (not neon), per tone."""
    lb = np.asarray(chart["lab_before"])   # (lights, tones, stops, 3)
    la = np.asarray(chart["lab_after"])
    out = {}
    lights = ["Daylight", "Warm indoor", "Night / neon", "Backlit"]
    for li, light in enumerate(lights):
        for ti in range(lb.shape[1]):
            f = {}
            B, A = lb[li, ti], la[li, ti]
            # tonal separation across the two darkest steps
            sep_b = B[2, 0] - B[3, 0]
            sep_a = A[2, 0] - A[3, 0]
            ratio = sep_a / max(sep_b, 1e-3)
            if ratio < 0.25 or (B[3, 0] > 5 and A[3, 0] < 2.5):
                f["crush"] = BAD
            elif ratio < 0.5:
                f["crush"] = WARN
            if not mono and light != "Night / neon":
                for si in (1, 2):   # mid and one stop under
                    Cb = np.hypot(*B[si, 1:]); Ca = np.hypot(*A[si, 1:])
                    if Cb < 6 or A[si, 0] < 6:
                        continue
                    cr = Ca / Cb
                    dh = (np.degrees(np.arctan2(A[si, 2], A[si, 1]) - np.arctan2(B[si, 2], B[si, 1])) + 180) % 360 - 180
                    if cr < 0.6: f["ashy"] = BAD
                    elif cr < 0.75: f["ashy"] = max(f.get("ashy", 0), WARN)
                    if Ca > 28 and cr > 1.6: f["oversat"] = BAD
                    elif Ca > 28 and cr > 1.35: f["oversat"] = max(f.get("oversat", 0), WARN)
                    if Cb >= 8:
                        def put(k, v, f=f):
                            if v:
                                f[k] = max(f.get(k, 0), v)
                        hue_flags(put, dh, Cb, Ca)
            out[f"{light}|{ti}"] = f
    return out


def toned_mono(stats):
    """Looks that drain nearly all colour on purpose (silver shade, bleach
    bypass): skin keeps under 30% of its chroma. Judged like black and white,
    on tone only, since greyness is the point of the look."""
    r = [s["C_after"] / s["C_before"] for s in stats.values() if s["C_before"] >= 6]
    return bool(r) and float(np.median(r)) < 0.3


def summarise(res, key="portraits", mono=None):
    flags, per = {}, {}
    if mono is None:
        mono = all(v["mono"] for v in res[key].values()) or toned_mono(res[key])
    for pid, s in res[key].items():
        s = dict(s, _id=pid)
        f = portrait_flags(s, mono)
        per[pid] = f
    return mono, per


def verdict(per, chart_f, mono):
    main = [pid for pid in per if pid not in STRESS and pid not in NEON]
    neon = [pid for pid in per if pid in NEON]
    bad_main = sum(1 for pid in main if max(per[pid].values(), default=0) >= BAD)
    warn_main = sum(1 for pid in main if max(per[pid].values(), default=0) == WARN)
    bad_neon = sum(1 for pid in neon if max(per[pid].values(), default=0) >= BAD)
    stress_bad = [pid for pid in STRESS if max(per[pid].values(), default=0) >= BAD]
    chart_bad = sum(1 for k, f in chart_f.items() if max(f.values(), default=0) >= BAD and not k.startswith("Night"))
    chart_cells = sum(1 for k in chart_f if not k.startswith("Night"))
    score = (sum(sum(f.values()) for pid, f in per.items() if pid not in STRESS)
             + 0.5 * sum(sum(f.values()) for f in per_stress(per).values())
             + 6 * chart_bad / max(chart_cells, 1))
    if bad_main == 0 and warn_main <= 2 and bad_neon <= 1 and chart_bad <= 2:
        cat = "true"
    elif bad_main >= 4 or (bad_main >= 3 and chart_bad >= 6):
        cat = "rework"
    else:
        cat = "tweak"
    counts = {}
    for pid, f in per.items():
        for k, v in f.items():
            counts[k] = counts.get(k, 0) + (2 if v >= BAD else 1) * (0.5 if pid in STRESS else 1)
    for k, f in chart_f.items():
        if k.startswith("Night"):
            continue
        for kk, v in f.items():
            counts[kk] = counts.get(kk, 0) + 0.25 * (2 if v >= BAD else 1)
    return dict(category=cat, score=round(score, 2), bad_main=bad_main, warn_main=warn_main,
                bad_neon=bad_neon, stress_lost=sorted(stress_bad), chart_bad=chart_bad,
                issues=sorted(counts, key=lambda k: -counts[k]), issue_weight=counts)


def per_stress(per):
    return {pid: f for pid, f in per.items() if pid in STRESS}


def main():
    R = json.loads((RENDER / "results.json").read_text())
    out = []
    for lk in LOOKS:
        res = R["looks"][lk["id"]]
        mono, per = summarise(res, "portraits")
        _, per75 = summarise(res, "portraits75", mono)
        cf = chart_flags(res["chart"], mono)
        v = verdict(per, cf, mono)
        v75 = verdict(per75, cf, mono)
        med = {}
        for key in ("portraits",):
            vals = [res[key][pid] for pid in res[key] if pid not in STRESS and pid not in NEON]
            cr = [x["C_after"] / x["C_before"] for x in vals if x["C_before"] >= 6]
            med = dict(chroma=float(np.median(cr)), dh=float(np.median([x["dh"] for x in vals if x["C_before"] >= 8])),
                       dL=float(np.median([x["L_after"] - x["L_before"] for x in vals])),
                       clip=float(np.mean([x["clip_after"] - x["clip_before"] for x in res[key].values()])))
        out.append(dict(id=lk["id"], code=lk["code"], name=lk["name"], section=lk["section"], pack=lk["pack"],
                        free=lk["free"], kind="recipe" if lk["recipe"] else "film cube", mono=mono,
                        flags=per, chart=cf, medians=med, at75=dict(category=v75["category"], score=v75["score"]),
                        **v))
    out.sort(key=lambda r: r["score"])
    (RENDER / "verdicts.json").write_text(json.dumps(out, indent=1))
    cats = {}
    for r in out:
        cats.setdefault(r["category"], []).append(r)
    for c in ("true", "tweak", "rework"):
        print(f"\n== {c}: {len(cats.get(c, []))}")
        for r in cats.get(c, []):
            iss = ", ".join(f"{k}" for k in r["issues"][:3])
            print(f"  {r['score']:6.1f}  {r['section'][:16]:16s} {r['code']:7s} {r['name'][:22]:22s} "
                  f"bad {r['bad_main']}/10 warn {r['warn_main']} neonbad {r['bad_neon']} stress {len(r['stress_lost'])} "
                  f"chartbad {r['chart_bad']:2d} | 75%: {r['at75']['category']:6s} | {iss}")


if __name__ == "__main__":
    main()
