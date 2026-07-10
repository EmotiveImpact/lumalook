# LumaLook Roadmap

_Last updated 2026-07-10. Active scope agreed: Waves A + B, then a review/polish
round on both, plus C4. Everything else is parked (do not lose)._

## ACTIVE — Wave A: finish the editor
- [x] Wire chrome kit into screens: trim / looks / music panels become undimmed
      bottom sheets (`.lumaToolSheet`, micro/small detents), `LumaHaptics`
      replaces ad-hoc haptics, `.lumaEdgeFade` on horizontal tool strips
- [x] Drag-to-reorder clips (long-press lift → floating clip → drop slots →
      sibling cascade; full algorithm in the img.ly mine reports)
- [x] Real per-second filmstrip frames in clip cells (AVAssetImageGenerator
      strip, cached; replaces tiled single thumb)
- [x] Snap indicators + haptic detents (playhead / clip edges)
- [x] Music trim handles + simple waveform on the music lane

## ACTIVE — Wave B: grade room restructure
- [x] Media-first full-bleed grade room: footage owns the screen, look strip +
      intensity + tools in a pinned bottom glass drawer
- [x] Haptic intensity dial (Halide-style precision wheel)
- [x] Before/After as press-and-hold on the image (keep wipe screen too)
- [x] TS5 (research): trademark-safe look renaming + RNI-style taxonomy
      (Negative/Slide/B&W/Instant/Cine/Original) — "Kodak 5207" in
      MockData.swift becomes KD52 etc., disclaimer line added. Do BEFORE any
      App Store screenshots
- [x] TS1 verify: look thumbs already render from user's frame (LookThumbs);
      confirm they survive the restructure + reduced-res render per look

## ACTIVE — after A+B: review round
- [ ] On-device feel pass (scrub, pinch, dial, haptics) and fix list
- [ ] Clip transitions — cross-fade first (opacity ramp on overlapping
      AVMutableComposition ranges), from the Banuba primer checklist
- [ ] Anything the competitive-research dossier flags as table stakes
- [ ] TS3 PULLED FORWARD: one real-device QA session (camera bake-in, export
      thermals, save reliability) — "everything else is decoration if
      recordings drop"
- [x] TS2: implement film grain + halation in LookPipeline (custom kernel;
      sliders already exist in UI/model) — the "premium physics" signal
- [ ] TS8: copy grade between clips (engine already shares LookState; UI only)
- [x] TS6: log-LUT tagging + mismatch hint on import (filename heuristics,
      badge, suggest lower intensity)
- [ ] D1: preview/export parity verification matrix (8/10-bit, HDR/SDR,
      photo/video) → becomes the marketed guarantee "the preview never lies"
- [ ] PRODUCT TRUTH fixes (Codex audit, research/codex-second-opinion.md):
      camera HUD must show the REAL capture format (currently says 4K•30 but
      records 1080p) or capture must move to 4K; hide-or-implement dead
      controls (Text/Overlay tools, grain/halation/HSL sliders not wired to
      the pipeline — implement grain + halation in LookPipeline first, they
      are core to "cinematic"); project delete must remove copied media files
      (PersistenceStore storage leak)

## ACTIVE — C4: real LUT packs (spec: research/OPPORTUNITY_MAP.md §4)
- [x] 4 launch packs, 5-7 looks each, KD/FJ/CN/AG/BW/LL naming with
      character + era copy per look; 33-point .cube generation + recipe
      defaults, installed via existing LUTRepository path
- [x] Pack Detail = hero graded frame + copy + look count; installs pack
- [x] Store rows reflect installed/owned; "N looks · M packs" header counts
- [x] Locked looks fully previewable on user media; gate export/save only
- [x] Free/paid flags per §4.5 (Negative Set 01 + half Originals free;
      no watermark EVER)

## C5 StoreKit 2 + paywall + onboarding — PRICING LOCKED BY USER 2026-07-10
LOCKED: Pro annual $24.99 w/ 7-day trial, lifetime $49.99, packs $2.99-4.99
à la carte. NO weekly, NO monthly, no trial toggle.
Single-screen paywall on the user's own graded media; onboarding folded into
the same funnel. ASO strings in §5.

## PARKED (do not lose)
- Codex audit follow-ups (research/codex-second-opinion.md): camera manual
  controls/waveform/peaking/4K formats; Rec.709-vs-Log LUT targets +
  SDR/HDR color policy; export reliability hardening (presets, disk/thermal/
  interruption recovery, dropped-frame handling); per-clip look model in the
  editor (big architectural win for LUT packs)
- C5 StoreKit 2 + paywall: products, entitlement matrix (SPEC_ADDENDUM),
  restore, paywall screen. **Blocked on user decisions: pricing + free vs Pro
  split.**
- C6 Onboarding: 3-screen cinematic first-launch intro
- D7 Real-device QA: filtered camera recording on hardware, thermals during
  export, haptics tuning
- D8 Performance: thumbnail render caching, rebuild debouncing, 4K export
  memory
- D9 App Store submission kit: screenshots, preview video, description /
  keywords, privacy labels, age rating, review submission
- Housekeeping: fix 3 iOS-16 deprecation warnings (TimelineEngine 536/537/540);
  decide iOS 18 minimum (zoom transitions, MeshGradient); Glur progressive blur
  if a surface still wants it after Wave B; music fades/looping; overlay video
  track (custom compositor)
