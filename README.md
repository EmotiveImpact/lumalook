# LumaLook

iPhone-first cinematic LUT, camera and video editing app. Built from the
`LumaLook_Full_iPhone_Build_Package_Codex` handoff pack (PRD, design system,
screen specs, technical specs).

## Requirements

- Xcode 16+, iOS 17+ simulator or device

## Build & run

The Xcode project is generated with [XcodeGen](https://github.com/yonas/xcodegen)
(`brew install xcodegen`):

```sh
xcodegen generate
open LumaLook.xcodeproj        # or:
xcodebuild -project LumaLook.xcodeproj -scheme LumaLook \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

Code signing is disabled for simulator builds (`CODE_SIGNING_ALLOWED=NO` in
`project.yml`). To run on a device, set your team in Xcode's Signing settings.

## What's implemented

**Phase 1 — visual shell (done):** all 16 reference screens in SwiftUI, dark
cinematic theme, glass cards, gradient CTAs, custom tab bar, full navigation.

**Phase 2 — Apply a Look MVP (done):** pick a video with PhotosPicker, live
graded preview via `AVMutableVideoComposition` + Core Image, 10 built-in looks
as real filter recipes (temperature/tint, contrast, saturation, bloom,
vignette), intensity blending, before/after peek (hold the viewer), 1080p
export with progress + cancel, save to Photos, Export Complete with ShareLink.

**Phase 3 — LUT import (done):** `.cube` file importer, parser with
validation, JSON-persisted repository (favourites, delete), imported LUTs
join the look carousel and apply via `CIColorCubeWithColorSpace`. Sample LUTs
are bundled and seeded on first launch.

**Phase 4 — Camera (done, MVP compromise per CAMERA_SPEC):** AVFoundation
1080p live preview, look carousel, record via `AVCaptureMovieFileOutput`,
save to Photos, graceful permission-denied / no-camera states. Live look is
selected in UI; baked-in filtered recording is a TODO (`AVAssetWriter`).

**Phase 5 — Editor (done):** real `AVMutableComposition` timeline — add
clips from Photos, select/trim/split-at-playhead/delete, per-clip speed
(0.5–2×, pitch-corrected preview), drag-to-scrub timeline with playhead,
undo/redo, format/crop (9:16, 16:9, 1:1, 4:5 + zoom applied via the CI
handler), audio volume/fade-in/fade-out/mute via `AVAudioMix`, and full
timeline export through the shared look pipeline. Audio tracks are added
lazily (an empty audio track makes `AVAssetExportSession` fail).

**Post-MVP fold-in (done, per SPEC_ADDENDUM.md in the package):**
- **Persistence** — projects auto-save (debounced) to `Documents/Projects.json`
  with clips copied into `Documents/Clips/`; Project Library and Home's
  Recent Projects list real projects; saved custom looks persist and
  re-apply from Saved Looks.
- **Still images** — Apply a Look accepts photos as well as video (the
  VIDEO/PHOTOS segments switch the picker); stills grade live and export
  to the photo library as JPEGs.
- **HDR policy** — every video composition (preview + both export paths)
  forces BT.709 so HDR iPhone footage tone-maps before grading.
- **True live camera** — filtered preview via `AVCaptureVideoDataOutput`
  through the shared pipeline, recording bakes the look in with
  `AVAssetWriter` (needs real-device verification; simulator has no camera).
- **Before/After wipe** — draggable split rendered in the composition
  (original left / graded right); never baked into exports.
- Clip reordering (context menu), app icon, editor undo/redo.

**Phase 6 — Store, StoreKit (visual shells):** filter store, pack detail
and settings remain styled shells; StoreKit 2 is the final milestone.

## Layout

- `LumaLook/App` — entry point, root navigation
- `LumaLook/Design` — theme tokens + reusable components
- `LumaLook/Models` — app models incl. `LookRecipe` grading parameters
- `LumaLook/Data` — `AppModel` (navigation + look state), mock data
- `LumaLook/Screens` — one SwiftUI view per reference screen
- `LumaLook/Engine` — `LookPipeline`, `LUTParser`, `LUTRepository`,
  `VideoExporter`, `CameraController`
- `LumaLook/Resources/SampleLUTs` — bundled `.cube` files

## Debug helpers

Launch straight into a screen:
`SIMCTL_CHILD_LUMA_ROUTE=applyLook xcrun simctl launch booted com.emotiveimpact.lumalook`
(routes: selectClip, applyLook, beforeAfter, lutManager, camera, editor,
exportComplete, filterStore, settings)
