# LumaLook Roadmap

_Last updated 2026-07-13. The "Recommended Next 10" run is COMPLETE, plus a
follow-on wave (lenses, film archive, monetization, portrait, polish). All
shipped build-green with seeded sim verification and pushed to master
(auto-TestFlight via Xcode Cloud)._

## SHIPPED — follow-on wave (2026-07-12/13)
- [x] **7 lens effects** (Anamorphic, Vintage Prime, Diffusion, Fisheye,
      Tilt-Shift, Swirl 58, Toy Cam) — procedural glass in LookPipeline,
      rides everywhere, stripped from cube bakes. Also fixed a latent bug:
      all apply() call sites fed infinite-extent images, silently breaking
      spatial ops (halation radius was ∞).
- [x] **102 measured film emulations** from the open G'MIC / Pat David
      collection (CC BY-SA) as 6 Store packs — Film Stocks 01 + Negative /
      Slide / Mono / Instant / Mirrorless archives.
- [x] **Monetization split** — free: Negative Set + Film Stocks 01 (19
      looks), Diffusion + Fisheye. Pro: the 5 archives (88 stocks) +
      5 cinematic lenses. Crown badges + soft paywall, everything
      previewable, no watermark.
- [x] **Portrait-first editor** (first clip decides canvas) + TikTok-style
      fullscreen preview.
- [x] **Photos-access fix** — exports never dead-end on denied/limited
      permission; success screen explains + deep-links to the exact toggle.
- [x] **UI polish** — sticky home header, PRO badge on profile tab, dark
      nav surfaces app-wide (LumaTheme.bar), header material only on scroll,
      tab-bar hairline removed, home wordmark placement.

---

_Below: the original Next-10 run, complete._

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

## SHIPPED — Pro Color Room (2026-07-13, flagship expansion tranche 1)
- [x] RGB + per-channel tone **curves** (draggable editor, monotone spline)
- [x] Lift/Gamma/Gain 3-way **colour wheels** (balance pads + master sliders)
- [x] 8-band **HSL** secondary (band chips + H/S/L)
- [x] Video **scopes**: RGB waveform / parade / vectorscope+skin-line / histogram
- Engine: ColorMath.swift (curves+wheels → one separable cube; HSL 3D cube),
  Scopes.swift. All on LookSettings → preview/export/per-clip/camera/bake.
- Full 118-item flagship backlog: research/BUILD_BACKLOG.md.

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
### Ship-blockers (do before App Store)
- [ ] **App Store Connect products** — recreate the `LumaLook.storekit` IDs
      (pro.yearly, pro.lifetime, 3 pack IDs) as real products in ASC, or
      NOTHING can be purchased on a real build. The single hard revenue gate.
- [ ] **Real-device QA session** — the one thing the sim can't do: camera
      flip/zoom/still on hardware, filtered recording, export thermals,
      haptics feel, voiceover mic quality.
- [ ] **Close the premium-look leak** — one `isPremium: true` built-in look
      (Afrobeats Glow) is still exportable free. Everything else gates at
      acquisition (can't install Pro packs / select Pro lenses), but this
      one look needs an export/save entitlement check. Small but real.
- [ ] App Store submission kit (D9): screenshots (film packs, lenses,
      dissolve, paywall), preview video, ASO strings from OPPORTUNITY_MAP §5,
      privacy labels, age rating.

### High-value next
- [ ] **Camera-profile normalization + Apple Log capture** — the
      calendar-locked September-iPhone-cycle item; the community's #1 gripe.
- [ ] #94 writer pipeline (bitrate slider, ProRes) — unlocks 10-bit/HDR
      parity cells.
- [ ] Film Stocks Vol. 2 — generate NEW stocks from datasheets
      (spectral_film_lut) as original, fully-owned content.

### Slot-in delights (each ≤2 days, high delight-per-effort)
- [ ] Freeze frame, duplicate clip, contact sheet, per-pack grain size,
      letterbox guides, first-frame gate, confirm-before-discard.

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
