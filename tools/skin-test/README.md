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
- **Film looks** are the app's own `.cube` files, sampled tetrahedrally, which
  is what the app's 64-point densify (`LUTDensifier.swift`) does. Until
  23 Nov 2026 the densify had one of its six cases missing and was up to 29
  of 255 off on a sixth of each cell; `check_truecolour.swift` now checks it.
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

# the rules for new looks
python3 gate.py                             # every look against the rules and baseline.json
python3 check_look.py NEW.cube              # a new film LUT, no Mac needed
python3 selftest_gate.py                    # the gate itself, on two pretend new looks
python3 source_rules.py                     # nothing in the app goes around True Colour
```

Needs numpy, scipy and Pillow.

## When a new look comes in

True Colour protects skin on every look without anyone doing anything: recipe
looks get lightness-only tone, and any LUT the app did not make itself gets
the skin guard. The gate checks that the protection was enough for this look.

**The rule a new look has to pass** (`gate.py`):

1. Skin-true at 75%, the strength the app opens every look at.
2. Never "needs rework", not even at full strength.
3. The deepest skin tone (Monk 10) keeps at least 0.20 lightness (Oklab L),
   on the exact measurement, not the rounded one that gets printed.
4. No look already in the app gets worse than its line in `baseline.json`.
5. A film LUT uses the standard input range, 0 to 1. A `.cube` file that sets
   its own (`DOMAIN_MIN` / `DOMAIN_MAX`) is shown by the app as authored, with
   no skin guard, and the test cannot read it, so the gate and `check_look.py`
   turn it away. Export it again with the standard range.

The gate also runs `source_rules.py` (see "Things not to do"), and
`selftest_gate.py` checks the gate itself: it pretends a new recipe and a new
film look were just added and checks that the first gets a verdict and the
second, which is only near at 75%, is turned away.

**A film LUT (.cube file)**

```sh
python3 tools/skin-test/check_look.py NEW.cube --sheet new.jpg   # no Mac needed
```

It prints PASS or FAIL with the reason and what to change, and saves a
picture on four test portraits. It judges the same colours the gate does
(the app's cube read back on the Mac bake's 25-point lattice), so the two
agree. If it passes, put the file in
`LumaLook/Resources/FilmLUTs/`, add the look to its pack in `LookPacks.swift`
and push to a `claude/` branch. The Mac runner bakes it through the app's own
code and the gate has the last word.

**A recipe look (warmth, contrast and so on)**

Add it to `LookPacks.swift` (or `MockData.swift` for a Signature look) and
push to a `claude/` branch; the Mac runner tests it, because warmth runs
through Core Image. Where recipes pass, from `sweep.py` (True Colour on;
"passes" means skin-true at 75%):

| Setting | Comfortable | The edge | Fails |
|---|---|---|---|
| Saturation | 0.85 to 1.15 | 0.70 (only with brightness below 0) and 1.30 | 1.45 and up: skin turns orange |
| Contrast | 0.90 to 1.40, the whole range in use | | no longer the risk it was |
| Brightness | -0.04 to +0.06 | -0.06 | |
| Warmth | 5000 to 7000 K | 7600 K (goes ashy) | warmer than about 4600 K (orange, green), cooler than about 8300 K (ashy) |
| Tint | -6 to +10 | +11 to +14 (goes magenta) | +15 and up; +20 and up needs rework |

Settings add up. Low saturation with a cool white balance, or with low
contrast and raised brightness (0.85, 0.90 and +0.06 together), washes skin
out. High saturation with a warm white balance turns it orange. A look on the
edge in one setting should sit in the comfortable column for the others. At
full strength the picture is stricter: saturation 0.85 to 1.15 with
brightness at 0 or above stays skin-true at any contrast. The table is a
guide to where to start; the gate decides. Black-and-white recipes
(saturation 0) are judged on tone alone; the ones in the app go up to
contrast 1.40 and pass.

**When a look fails**

The gate names the problem and the remedy. In short: ashy, raise saturation
or warm it; orange or red, lower saturation or cool it; magenta, move tint
towards green; green, move tint towards magenta; too dark or crushed, raise
brightness or lower contrast. For a film cube the same changes go into the
cube itself. A look that cannot pass at 75% does not ship.

**Things not to do**

- No `CIColorControls` for contrast or brightness anywhere. It works in
  linear light and crushes deep skin to black; that was the original bug.
  Tone goes through `TrueColour.toneFilter`.
- No new colour filter that skips `TrueColour`. If a look needs something
  new, add it there, with a check in `check_truecolour.swift`.

  `source_rules.py` reads the app's Swift sources for both: any new use of
  `CIColorControls`, and `LookPipeline.swift` no longer sending recipes,
  sliders, overlays and LUTs through `TrueColour`. It runs in the gate and,
  on every pull request, in the Build workflow. It is a tripwire for the
  known ways round, not a render of the whole app: the Mac programs compile
  the three engine files only, because `LookPipeline` needs the whole app.
- No `gate.py --accept` to make a failure go away. It records a decision
  that somebody made on purpose, and the baseline change shows in the pull
  request.

**When the engine itself changes** (`TrueColour.swift`, `LUTParser.swift`,
`LUTDensifier.swift`)

1. `check_truecolour.swift` has to pass (the Mac runner runs it before it
   bakes). Add a check for whatever changed.
2. If the tone maths changed, bump the stamp in `TrueColour.stamp(on:)`
   (`tone2` today), so pack looks already installed on phones are baked again.
   `TrueColour.Rebake` keeps the books for that: the stamp is cleared when a
   batch starts, the whole batch is baked for one position of the switch, and
   the stamp is saved only for a batch that finished with the switch where it
   started. A batch that is interrupted, or that the switch moves under, is
   simply done again.
3. The gate has to pass on the new bake, then
   `python3 tools/skin-test/check_look.py --self-test` has to pass, which
   proves the Python copy of the guard (`fixes.skin_guard`) still matches.
   The workflow runs both, and `selftest_gate.py`, on every push.

**What the skin guard cannot do**

It judges skin by colour alone. The deepest skin tones sit a few steps from
neutral grey, so on the most extreme looks (the Instant Lab cold looks at
full strength) the edge between protected skin and the look's own colour can
still show as a hard line in dark hair and shadow. A guard that knows where
the people are in the picture (Apple's Vision person segmentation) would not
have that limit; that is the next step if it matters on real photos.

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
| Film looks (97) | 40 | 81 (16 near, none to rework) | 92 | 79 to 10 |
| All looks (128) | 40 | 107 | 123 | 298 to 10 |

With True Colour off, 54 of 128 are skin-true: the linear-light bug stays
fixed either way. Monk 10 keeps at least 0.20 Oklab L on 125 of 128 looks
(CP2383, CP3513 and CP2393 sit at 0.19 to 0.20).

The film row read 78 and 90 in the first True Colour build. The smoother skin
guard and the densify fix moved it to 81 and 92 with no look worse; these are
the numbers in `baseline.json`. Five film looks are still only near at the 75%
default (PX70W, PX70C, PX680, PX680W and PX680C, all instant films). They
stay because they were already in the app; a new look that read the same
would fail the gate.
