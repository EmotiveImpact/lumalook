"""List every Lumalook look, straight from the app's Swift sources.

Reads LumaLook/Data/MockData.swift (the ten Signature looks) and
LumaLook/Engine/LookPacks.swift (every pack) and writes looks.json:
one entry per look with its recipe numbers or its bundled .cube file.

    python3 tools/skin-test/extract_looks.py [repo root] [out json]
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name("looks.json")

DEFAULTS = dict(temperature=6500.0, tint=0.0, contrast=1.0, saturation=1.0,
                brightness=0.0, vignette=0.0, bloom=0.0)


def recipe_of(text):
    m = re.search(r"LookRecipe\(([^)]*)\)", text, re.S)
    if not m:
        return None
    r = dict(DEFAULTS)
    for key, value in re.findall(r"(\w+):\s*(-?[\d.]+)", m.group(1)):
        r[key] = float(value)
    return r


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


looks = []

mock = (ROOT / "LumaLook/Data/MockData.swift").read_text()
block = mock[mock.index("static let looks"):mock.index("static var defaultLook")]
for chunk in block.split(".init(name: ")[1:]:
    name = re.match(r'"([^"]+)"', chunk).group(1)
    code, _, title = name.partition(" · ")
    if not title:
        code, title = "", name
    looks.append(dict(id="sig-" + slug(name), code=code, name=title, section="Signature",
                      pack="signature", free="isPremium: true" not in chunk,
                      recipe=recipe_of(chunk), cube=None))

packs = (ROOT / "LumaLook/Engine/LookPacks.swift").read_text()
body = packs[packs.index("static let packs"):packs.index("static func pack(id")]
for chunk in re.split(r"\n        LookPack\(", body)[1:]:
    pid = re.search(r'id: "([^"]+)"', chunk).group(1)
    pname = re.search(r'name: "([^"]+)"', chunk).group(1)
    free = "isFree: true" in chunk
    for lk in re.split(r"PackLook\(", chunk)[1:]:
        code = re.search(r'code: "([^"]+)"', lk).group(1)
        name = re.search(r'name: "([^"]+)"', lk).group(1)
        title = name.split(" · ", 1)[1] if " · " in name else name
        cube = re.search(r'cubeFile: "([^"]+)"', lk)
        looks.append(dict(id=f"{pid}-{slug(code)}", code=code, name=title, section=pname,
                          pack=pid, free=free,
                          recipe=None if cube else recipe_of(lk),
                          cube=cube.group(1) if cube else None))

OUT.write_text(json.dumps(looks, indent=1))
print(f"{len(looks)} looks ({sum(1 for l in looks if l['recipe'])} recipes, "
      f"{sum(1 for l in looks if l['cube'])} film cubes) -> {OUT}")
