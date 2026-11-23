# Skin test

Runs every Lumalook look over Black and brown skin, in four kinds of light,
and flags looks that shift skin badly: ashy or grey, green or magenta casts,
crushed shadows, skin pushed too dark, orange or red oversaturation.

It measures looks, tries fixes, and verifies the True Colour engine
(`LumaLook/Engine/TrueColour.swift`) on the real Core Image bake.

## What it uses

- **Looks**: `extract_looks.py` reads the Signature looks from `MockData.swift`
  and the packs from `LookPacks.swift` into `looks.json` (133 looks).
- **Recipe looks** are rendered through real Core Image on a Mac:
  `bake_recipes.swift` (run by `.github/workflows/skin-test.yml`) bakes each
  recipe's colour stage into a 25-point cube in `out/luts/`, and renders probe
  images for bloom, vignette and the intensity dissolve in `out/probes/`.
  `recipe_model.py` fits a model to that bake (exact to 0.00/255), so fixes can
  be tried without a Mac.
- **True Colour (the shipping engine)**: `bake_truecolour.swift` is compiled
  on the Mac runner together with the app's own `TrueColour.swift`,
  `LUTParser.swift` and `LUTDensifier.swift`, so it runs the shipping code:
  recipe looks with True Colour on (`out/luts_tc`) and off
  (`out/luts_classic`), and every film cube with the runtime skin guard
  (`out/film_tc`). `verify.py` judges those and `after_sheets.py` draws the
  before and after. `out/luts` keeps the bake of the looks as they shipped
  before the fix (the "before").
- **Film looks** are the app's own `.cube` files, sampled tetrahedrally (what
  the app's 64-point densify comes to).
- **Portraits**: 16 photos from Pexels (Pexels Licence), four per light
  (daylight, warm indoor, night and neon, backlit), listed with credits, crops
  and skin areas in `portraits.json`. The Mac runner downloads them
  (`candidates.txt`); `prep_portraits.py` crops them to 4:5 and draws skin masks.
- **Monk Skin Tone chart** (Google, CC BY 4.0), tones 4 to 10, under the same
  four lights and at four exposures.

## Running it

```sh
python3 prep_portraits.py
python3 run_test.py  RENDER_DIR          # thumbs, chart and raw numbers
python3 analyse.py   RENDER_DIR          # flags and a verdict per look
python3 fixes.py     RENDER_DIR          # engine fix, recipe tweaks, skin guard, safe intensity
python3 sheets.py    RENDER_DIR OUT_DIR  # contact sheets, one per pack
python3 report.py    RENDER_DIR OUT_DIR  # ranked list (csv and markdown)
python3 engine_variants.py RENDER_DIR    # engine fix with and without the soft toe
python3 export_cubes.py RENDER_DIR OUT_DIR  # guarded cubes as .cube files

# after the Mac runner has baked the True Colour engine (skin-test.yml)
python3 verify.py RENDER_DIR                # before, on, off, and the research targets
python3 after_sheets.py RENDER_DIR OUT_DIR  # before and after sheets and PDF
python3 try_photos.py OUT.jpg PHOTO...      # any photo: as shipped, True Colour off and on
```

Needs numpy, scipy and Pillow.

## How a look is judged

Measured on the skin mask, in CIELAB, look against original:

| Flag | Mild | Bad |
|---|---|---|
| Crushed shadows | 3% more skin goes to black, or shadow texture under 60% | 10% more, texture under 35%, or the darkest tenth of the face goes from visible to black |
| Skin too dark (L* under 45) | 8 L* darker | 14 L* darker |
| Ashy / grey | chroma under 75% of the original, or lifted milky blacks | under 60% |
| Green cast | hue 8 degrees towards green and a visible change | 15 degrees |
| Magenta cast | hue 10 degrees towards magenta | 18 degrees |
| Oversaturation | chroma over 1.35x (and over 28) | over 1.6x (and over 34) |

Neon frames are judged on shadows only, because the light is coloured on
purpose. Two extreme low-key frames are stress tests and count half.

- **Skin-true**: no bad flag on the 10 main frames, at most 2 mild, at most
  one bad neon frame and at most 2 bad chart cells.
- **Rework**: 4 or more main frames bad, or 3 with 6 bad chart cells.
- **Tweak**: everything in between.

## True Colour results (23 Nov 2026)

From the Mac runner's Core Image bake of the shipping engine, at 100%
intensity unless stated. "Near" means mild flags only.

| | Skin-true before | True Colour on | On at the 75% default | Bad main frames |
|---|---|---|---|---|
| Recipe looks (31) | 0 | 26 (5 near) | 31 | 219 to 0 |
| Film looks (97) | 40 | 78 (19 near, none to rework) | 90 | 79 to 12 |
| All looks (128) | 40 | 104 | 121 | 298 to 12 |

With True Colour off, 54 of 128 are skin-true: the linear-light bug stays
fixed either way. Monk 10 keeps at least 0.20 Oklab L on 125 of 128 looks
(CP2383, CP3513 and CP2393 sit at 0.18 to 0.19).
