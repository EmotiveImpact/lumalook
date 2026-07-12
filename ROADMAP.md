# LumaLook Roadmap

_Last updated 2026-07-12. The "Recommended Next 10" run (research/MASTER_BACKLOG.md)
is COMPLETE: every item below shipped build-green with seeded simulator
verification (screenshots or export analysis) and pushed to master
(auto-TestFlight via Xcode Cloud)._

## SHIPPED — Next-10 run (2026-07-12)
- [x] **#1 Per-clip looks + copy grade** — ClipGrade per clip, compositor
      resolves `clipLookState ?? global`, inspector Look tool + context strip,
      timeline badge. Verified: A/B export frame analysis (graded half SATAVG
      21.8 vs 39.4; ungraded half pixel-identical, PSNR 46.8 dB).
- [x] **#2 StoreKit 2 + paywall + onboarding** — local `LumaLook.storekit`
      at LOCKED pricing ($24.99/yr + 7-day trial, $49.99 lifetime, packs
      $2.99–3.99, NO weekly/monthly). StoreService entitlements + restore +
      transaction listener; PaywallView (yearly/lifetime picker, offline
      price fallback); 3-page onboarding ending in a SOFT paywall; pack
      detail buys through StoreKit; Settings shows live status.
- [x] **#3 Export hardening + D1 parity matrix** — disk preflight, thermal
      gate, background-task lock-screen survival, partial-file cleanup,
      stale-export sweep. research/PARITY_MATRIX.md: 8 measured cells — and
      it caught a REAL bug (4K exports silently capped at 1080p by
      renderSize; fixed via `buildComposition(renderScale:)`, re-verified
      3840×2160@24).
- [x] **#4 On-cell trim handles** — bracket grips on the selected clip, live
      width preview, one undo per drag, out-point anchored on head trim.
- [x] **#5 True dissolves + wipes** — aux A/B-roll track with pre/post-roll
      material; CIDissolveTransition + soft-edge wipe; per-clip grades on
      each side; cut times never move. Verified by frame-mean progression
      across the span (dissolve blends uniformly; wipe reveals left→right).
- [x] **#6 Keyframes** — OverlayLayout placement keyframes (size/centre/
      opacity/rotation), linear interpolation per frame, zero rebuilds;
      CapCut-style pin-at-playhead authoring. Verified by quadrant analysis
      of an animated overlay in export.
- [x] **#7 Text/title layers** — CITextImageGenerator path on the overlay
      lane (placement/keyframes/trim free), alpha-mask colourisation
      (generator draws black glyphs — caught in export analysis), drop
      shadow, 3 typography presets + 6 swatches, ungraded by design.
- [x] **#8 Voiceover** — record-to-picture (muted playback, no echo), takes
      land on their own lane at the recording start, auto-numbered.
- [x] **#9 Open-in-place .cube + ZIP packs** — document types + in-place
      opening; dependency-free minimal ZIP reader (stored/deflate); packs
      extract + import with clean names, confirmation banner, routes to
      My LUTs.

## SHIPPED — code-level gaps (same run)
- [x] PIP overlay AUDIO (own lazy track + per-overlay volume/mute; verified
      by bandpass: 880 Hz overlay tone at −23 dB in export)
- [x] Editable transition durations (0.3/0.6/1.0/1.5 s chips, persisted)
- [x] Camera flip/zoom placebos now real (input swap + mirroring; ramped
      1x/2x/3x zoom with live HUD) + graded still capture + library routing
- [x] Overlay trim handles (media window honored by buildComposition)

## SHIPPED — Apple-native tranche 2
- [x] Settings / My LUTs / Projects as native inset-grouped Lists (swipe
      delete/favourite, native section headers, project thumbnails)
- [x] Editor strings de-shouted (Add a Clip, Apply Trim)

## Earlier shipped waves (2026-07-09 → 07-11)
Waves A+B (tool sheets, drag-reorder, filmstrips, waveform+trim, media-first
grade room, LumaDial, compare mode, TS5 naming), C4 packs with on-device cube
baking, LUT stacking, batch export, .cube grade export, scopes, grade
sessions, per-clip volume, export spec sheet, custom compositor (PIP overlays,
photo clips, multi-audio), Apple-native tranche 1, grain/halation.

## NEXT (recommended order)
- [ ] **Real-device QA session (D7/TS3)** — the one thing the sim can't do:
      camera flip/zoom/still on hardware, filtered recording, export
      thermals, haptics feel, voiceover mic quality.
- [ ] **Camera-profile normalization + Apple Log capture (#42/#70)** — the
      calendar-locked September-iPhone-cycle item.
- [ ] App Store submission kit (D9): screenshots (per-clip looks, dissolve,
      text, paywall), preview video, ASO strings from OPPORTUNITY_MAP §5,
      privacy labels. Products must be recreated in App Store Connect to
      match LumaLook.storekit IDs before release.
- [ ] Slot-in delights (each ≤2 days): freeze frame, duplicate clip, contact
      sheet, grain size per pack, letterbox guides, first-frame gate,
      confirm-discard.
- [ ] #94 writer pipeline (bitrate slider, ProRes) — unlocks parity cells
      for 10-bit/HDR.
- [ ] Premium-look gating pass: `isPremium` looks + pack looks check
      StoreService entitlements at export/save (preview stays free).

## PARKED (do not lose)
- Codex audit leftovers: camera manual controls/waveform/peaking;
  Rec.709-vs-Log LUT targets + SDR/HDR colour policy beyond current pin.
- D8 Performance: thumbnail render caching, rebuild debouncing, 4K export
  memory profile.
- Housekeeping: iOS-16 deprecation warnings (TimelineEngine), iOS 18 minimum
  decision, music fades/looping.

## Verification infrastructure (keep using)
Seeds: `LUMA_ROUTE`, `LUMA_SEED_CLIP/_CLIP2/_PHOTO/_OVERLAY/_MUSIC/_MUSIC2`,
`LUMA_SEED_CLIPLOOK`, `LUMA_SEED_TRANSITION`, `LUMA_SEED_KEYFRAMES`,
`LUMA_SEED_TEXT`, `LUMA_SEED_VOICEOVER`, `LUMA_SEED_FORMAT`, `LUMA_SEED_SPEC`,
`LUMA_SEED_EXPORT/_PLAY/_DEBUG`, `LUMA_SEED_ONBOARDING`, `LUMA_SEED_PAYWALL`,
`LUMA_OPEN_FILE`, `LUMA_AUTO_INSTALL`. Parity matrix + measurements:
research/PARITY_MATRIX.md.
