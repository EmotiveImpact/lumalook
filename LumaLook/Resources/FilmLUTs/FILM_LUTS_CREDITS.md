# Film Stocks 01 — bundled LUT credits

These 3D LUTs derive from the open film-emulation collection created by
Pat David for G'MIC / RawTherapee (the community-measured "HaldCLUT" film
set), converted to .cube. Sources:

- G'MIC film emulation CLUTs — https://gmic.eu (CeCILL/free licence)
- Pat David's film emulation work — https://patdavid.net
- .cube conversions mirrored from https://github.com/YahiaAngelo/Film-Luts
  (repository wrapper: MIT)

The LUT data is redistributed under Creative Commons Attribution-ShareAlike
(CC BY-SA). Attribution is shown in-app; the LUT files themselves remain
under CC BY-SA wherever they travel. Bundled files are renamed to
trademark-safe LumaLook codes; original stock references appear only in
the files' internal TITLE metadata as historical provenance.

## Lumalook's own looks

These files in this folder are not from the collection above. Lumalook made
them, and they are not under CC BY-SA:

- `FS_PM800.cube` (PM800 · Press Mono 800, in Mono Archive): made by
  `tools/skin-test/make_mono_cube.py` from a colour sensitivity and a tone
  curve of our own. It took the place of `FS_HPS800.cube`, whose measured data
  was the same as `FS_HP400.cube`.
