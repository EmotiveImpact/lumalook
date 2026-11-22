import CoreGraphics
import Foundation

/// The animated text presets the title library ships. Raw values persist
/// (`StoredText.animation`), so never rename a case — add.
enum TextAnimation: String, Codable, CaseIterable {
    case none, fadeIn, popIn, slideUp, slideLeft, typewriter, bounce, kenBurns

    var label: String {
        switch self {
        case .none:       return "None"
        case .fadeIn:     return "Fade In"
        case .popIn:      return "Pop In"
        case .slideUp:    return "Slide Up"
        case .slideLeft:  return "Slide Left"
        case .typewriter: return "Typewriter"
        case .bounce:     return "Bounce"
        case .kenBurns:   return "Ken Burns"
        }
    }

    /// SF Symbol for the library sheet + lane chips.
    var icon: String {
        switch self {
        case .none:       return "nosign"
        case .fadeIn:     return "circle.lefthalf.filled"
        case .popIn:      return "sparkles"
        case .slideUp:    return "arrow.up"
        case .slideLeft:  return "arrow.left"
        case .typewriter: return "keyboard"
        case .bounce:     return "arrow.up.and.down.circle"
        case .kenBurns:   return "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// What the compositor should do to the text image this frame.
///
/// This is a DESCRIPTION, not pixels: `TextAnimator` never rasterises. The
/// caller owns the already-rendered text image and applies these four values to
/// it, which keeps the glyph raster cacheable across the whole layer instead of
/// being rebuilt every frame.
struct TextAnimationState {
    var opacity: Double = 1
    var scale: Double = 1
    /// Offset in UNIT canvas fractions (x right, y DOWN — UI convention).
    /// The compositor multiplies by the canvas size and flips y for Core Image.
    var offset: CGPoint = .zero
    /// 0...1 fraction of the string to reveal (typewriter); 1 = all.
    var reveal: Double = 1
}

/// The text library's animation curves, factored out of the compositor so the
/// render loop just calls `state(...)`. Every preset is a PURE function of
/// (preset, localTime, duration) — there is NO randomness anywhere, and no
/// dependence on wall-clock time or on the previous frame. A scrub preview and
/// the exported frame at the same timestamp therefore resolve to the same
/// maths, and 30 vs 60 fps sampling agrees because they sample one continuous
/// curve rather than stepping an animation state machine.
enum TextAnimator {

    /// Default in/out animation length in seconds.
    static let defaultDuration: Double = 0.6

    /// State at `localTime` seconds into a layer of `duration` seconds.
    /// Animates IN over the first `animateDuration`, and OUT over the last
    /// `animateDuration` (mirrored), holding steady in between.
    ///
    /// A layer shorter than `2 * animateDuration` overlaps its in and out
    /// ramps; `p` then peaks below 1 and the preset simply never fully lands.
    /// That is deliberate — it degrades smoothly rather than snapping.
    static func state(_ preset: TextAnimation, localTime: Double, duration: Double,
                      animateDuration: Double = defaultDuration) -> TextAnimationState {
        // Neutral is the identity for the compositor's transform, so any
        // nonsense input degrades to "draw the text as-is" instead of
        // propagating a NaN into a CGAffineTransform (which renders nothing).
        guard preset != .none,
              localTime.isFinite, duration.isFinite, animateDuration.isFinite,
              duration > 0, animateDuration > 0 else {
            return TextAnimationState()
        }

        let t = min(max(localTime, 0), duration)
        let inT = clamp01(t / animateDuration)
        let outT = clamp01((duration - t) / animateDuration)
        // Presence: 0→1 on the way in, 1 through the hold, 1→0 on the way out.
        // Eased once here so every preset below shares the same feel.
        let p = smoothstep(min(inT, outT))

        var s = TextAnimationState()
        switch preset {
        case .none:
            break                                   // unreachable: guarded above

        case .fadeIn:
            s.opacity = p

        case .popIn:
            s.opacity = p
            // Back-ease: overshoots ~1.02 near the end, then settles on 1.
            s.scale = 0.6 + 0.4 * overshoot(p)

        case .slideUp:
            s.opacity = p
            // y is DOWN, so a positive offset starts the text BELOW its mark.
            s.offset = CGPoint(x: 0, y: (1 - p) * 0.12)

        case .slideLeft:
            s.opacity = p
            s.offset = CGPoint(x: (1 - p) * 0.18, y: 0)

        case .typewriter:
            // Letters carry the animation, so the layer itself stays opaque.
            // `reveal` rides RAW inT, not `p`: typing is mechanical, and easing
            // it would bunch the letters up at both ends. It latches at 1 for
            // the hold AND the out — typed text does not un-type.
            s.reveal = inT

        case .bounce:
            s.opacity = p
            // Negative y = UP. The (1 - p) envelope damps the hop to nothing by
            // the time the text lands, so it settles instead of oscillating.
            s.offset = CGPoint(x: 0, y: -abs(sin(p * .pi * 2)) * 0.05 * (1 - p))

        case .kenBurns:
            s.opacity = p
            // Rides absolute time, not presence: the push is one slow
            // continuous ramp across the whole layer, independent of the
            // in/out ramps fading over the top of it.
            s.scale = 1 + 0.08 * (t / max(duration, 0.001))
        }
        return sanitised(s)
    }

    // MARK: - Easing

    private static func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    /// Mild back-ease: 0 at p = 0, 1 at p = 1, with a small overshoot before it
    /// settles. `c1` is the classic 1.70158 (the constant that makes the curve
    /// peak ~10% past its target); `c3 = c1 + 1` is what forces f(0) = 0.
    private static func overshoot(_ p: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let q = clamp01(p) - 1
        return 1 + c3 * q * q * q + c1 * q * q
    }

    // MARK: - Helpers

    /// Last line of defence: every field finite and in a range the compositor
    /// can actually build a transform from. `scale` never reaches 0 — a 0-scale
    /// affine transform is singular and collapses the image to nothing.
    private static func sanitised(_ s: TextAnimationState) -> TextAnimationState {
        var out = s
        out.opacity = clamp01(finite(s.opacity, fallback: 1))
        out.scale = min(max(finite(s.scale, fallback: 1), 0.001), 100)
        out.reveal = clamp01(finite(s.reveal, fallback: 1))
        out.offset = CGPoint(x: min(max(finite(s.offset.x, fallback: 0), -100), 100),
                             y: min(max(finite(s.offset.y, fallback: 0), -100), 100))
        return out
    }

    private static func finite(_ x: Double, fallback: Double) -> Double {
        x.isFinite ? x : fallback
    }

    private static func finite(_ x: CGFloat, fallback: CGFloat) -> CGFloat {
        x.isFinite ? x : fallback
    }
}

// MARK: - Caption word state (karaoke)

/// Which words of a caption line are lit, shown and popping at one instant.
/// A description, like `TextAnimationState`: `TextRasterizer.captionImage`
/// turns it into pixels, and equal states share one cached raster.
struct CaptionWordState: Equatable {
    /// Index of the highlighted word (whitespace-separated token); -1 = none.
    var active: Int = -1
    /// How many words are on screen (Pop reveals them one by one).
    var visible: Int = Int.max
    /// Pop-in progress of the newest word, 0...`TextAnimator.captionPopSteps`.
    /// Quantised so a pop is a handful of rasters, not one per frame.
    var popStep: Int = 6
}

extension TextAnimator {
    /// Pop-in is quantised into this many steps (the last one = settled).
    static let captionPopSteps = 6
    /// Seconds a newly spoken word takes to pop to full size.
    static let captionPopDuration: Double = 0.18

    /// The word state of a caption line `localTime` seconds into a layer of
    /// `duration` seconds. Pure, like `state(...)`: preview and export land on
    /// the same word at the same timestamp.
    ///
    /// `words` are the line's stored timings, relative to the layer start.
    /// When they no longer match the words on screen (the text was edited, or
    /// the line was typed) the line is shared out evenly instead.
    static func captionState(style: CaptionStyle, words: [CaptionWord], tokenCount: Int,
                             localTime: Double, duration: Double) -> CaptionWordState {
        guard style.tracksWords, tokenCount > 0,
              localTime.isFinite, duration.isFinite, duration > 0 else {
            return CaptionWordState()
        }
        let timings = CaptionTiming.resolve(words, tokenCount: tokenCount, duration: duration)
        guard !timings.isEmpty else { return CaptionWordState() }

        let t = min(max(localTime, 0), duration)
        var active = 0
        // A hair of lead so the highlight lands with the syllable, not after it.
        for (i, word) in timings.enumerated() where word.start <= t + 0.03 {
            active = i
        }
        active = min(active, tokenCount - 1)

        var out = CaptionWordState()
        if style.highlight != .none { out.active = active }
        if style.popsIn {
            out.active = active
            out.visible = active + 1
            let since = max(0, t - timings[active].start)
            let raw = Int((since / captionPopDuration * Double(captionPopSteps)).rounded(.down))
            out.popStep = min(captionPopSteps, max(0, raw))
        }
        return out
    }

    /// Scale of a popping word at progress `p` (0...1): from 55% up to full
    /// size, never past it, so the word can never spill out of its raster.
    static func captionPopScale(_ p: Double) -> Double {
        let t = min(max(p, 0), 1)
        let eased = 1 - (1 - t) * (1 - t) * (1 - t)
        return 0.55 + 0.45 * eased
    }
}
