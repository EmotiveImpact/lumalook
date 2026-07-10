# LumaLook Roadmap

_Last updated 2026-07-10. Active scope agreed: Waves A + B, then a review/polish
round on both, plus C4. Everything else is parked (do not lose)._

## ACTIVE — Wave A: finish the editor
- [ ] Wire chrome kit into screens: trim / looks / music panels become undimmed
      bottom sheets (`.lumaToolSheet`, micro/small detents), `LumaHaptics`
      replaces ad-hoc haptics, `.lumaEdgeFade` on horizontal tool strips
- [ ] Drag-to-reorder clips (long-press lift → floating clip → drop slots →
      sibling cascade; full algorithm in the img.ly mine reports)
- [ ] Real per-second filmstrip frames in clip cells (AVAssetImageGenerator
      strip, cached; replaces tiled single thumb)
- [ ] Snap indicators + haptic detents (playhead / clip edges)
- [ ] Music trim handles + simple waveform on the music lane

## ACTIVE — Wave B: grade room restructure
- [ ] Media-first full-bleed grade room: footage owns the screen, look strip +
      intensity + tools in a pinned bottom glass drawer
- [ ] Haptic intensity dial (Halide-style precision wheel)
- [ ] Before/After as press-and-hold on the image (keep wipe screen too)

## ACTIVE — after A+B: review round
- [ ] On-device feel pass (scrub, pinch, dial, haptics) and fix list
- [ ] Clip transitions — cross-fade first (opacity ramp on overlapping
      AVMutableComposition ranges), from the Banuba primer checklist
- [ ] Anything the competitive-research dossier flags as table stakes

## ACTIVE — C4: real LUT packs
- [ ] Generate real .cube packs; render per-pack preview strips from hero
      photos through the pipeline
- [ ] Pack Detail actually installs packs into the LUT repository
- [ ] Filter Store rows reflect installed/owned state

## PARKED (do not lose)
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
