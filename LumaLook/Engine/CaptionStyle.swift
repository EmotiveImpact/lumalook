import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// How a caption marks the word being spoken.
enum CaptionHighlight: Equatable {
    case none
    /// The spoken word turns signal yellow.
    case colour
    /// The spoken word sits on a signal-yellow box, in dark ink.
    case box
}

/// The caption looks the Captions panel offers. Raw values persist on caption
/// layers (`OverlayItem.captionStyle`), so never rename a case, only add.
enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case karaoke, highlight, pop, clean, boxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .karaoke:   return "Karaoke"
        case .highlight: return "Highlight"
        case .pop:       return "Pop"
        case .clean:     return "Clean"
        case .boxed:     return "Boxed"
        }
    }

    /// Bundled Inter cut (see Resources/Fonts and UIAppFonts).
    var fontName: String {
        switch self {
        case .karaoke, .highlight, .pop: return "InterDisplay-ExtraBold"
        case .clean:                     return "InterDisplay-SemiBold"
        case .boxed:                     return "InterDisplay-Bold"
        }
    }

    var highlight: CaptionHighlight {
        switch self {
        case .karaoke, .pop: return .colour
        case .highlight:     return .box
        case .clean, .boxed: return .none
        }
    }

    /// Words appear one by one as they are spoken, each with a small pop.
    var popsIn: Bool { self == .pop }

    /// A soft dark glow behind the glyphs so white text reads on any footage.
    var hasShadow: Bool {
        switch self {
        case .karaoke, .highlight, .clean: return true
        case .pop, .boxed:                 return false
        }
    }

    /// A dark outline around every glyph (Pop).
    var isOutlined: Bool { self == .pop }

    /// Each line sits on its own dark rounded box (Boxed).
    var hasLineBoxes: Bool { self == .boxed }

    /// True when the picture changes word by word, so the renderer needs the
    /// line's word timings. Clean and Boxed render one raster per line.
    var tracksWords: Bool { highlight != .none || popsIn }
}

/// Where the caption block sits in the frame.
enum CaptionPosition: String, CaseIterable, Identifiable {
    case top, middle, lower

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top:    return "Top"
        case .middle: return "Middle"
        case .lower:  return "Lower third"
        }
    }

    /// Unit y of the caption centre (y down). Lower third clears the caption
    /// and button area social apps lay over the bottom of a vertical video.
    var centerY: Double {
        switch self {
        case .top:    return 0.2
        case .middle: return 0.5
        case .lower:  return 0.74
        }
    }

    static func nearest(to y: Double) -> CaptionPosition {
        allCases.min(by: { abs($0.centerY - y) < abs($1.centerY - y) }) ?? .lower
    }
}

/// Caption type size. Every caption line is rasterised at the same width
/// (`CaptionMetrics`), so one size fraction gives one type size on screen.
enum CaptionSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small:  return "S"
        case .medium: return "M"
        case .large:  return "L"
        }
    }

    /// Type size (point size) as a fraction of the frame height. On a 9:16
    /// frame, Large matches the Night Lab captions mock.
    private var targetHeight: Double {
        switch self {
        case .small:  return 0.040
        case .medium: return 0.047
        case .large:  return 0.053
        }
    }

    /// Layer width / canvas width giving this type size in a frame of
    /// `aspect` (width / height). Wide frames get a boost so the lines do not
    /// shrink into a narrow column in the middle of the picture.
    func sizeFraction(aspect: CGFloat) -> Double {
        let a = Double(max(0.2, aspect))
        let perHeight = Double(CaptionMetrics.canvasWidth) / (Double(CaptionMetrics.pointSize) * a)
        let boost = max(1, 0.42 / (0.047 * perHeight))
        let raw = targetHeight * perHeight * boost
        return min(max(raw, 0.25), 0.96)
    }

    static func nearest(to fraction: Double, aspect: CGFloat) -> CaptionSize {
        allCases.min(by: {
            abs($0.sizeFraction(aspect: aspect) - fraction) < abs($1.sizeFraction(aspect: aspect) - fraction)
        }) ?? .medium
    }
}

/// Fixed geometry for caption rasters. Every caption line is laid out in the
/// SAME wrap width, so every line lands at the same type size on screen and a
/// long line wraps instead of shrinking.
enum CaptionMetrics {
    static let pointSize: CGFloat = 128
    /// About 17 characters of Inter ExtraBold per line: two short lines for a
    /// caption of up to 32 characters, as in the mock.
    static let wrapWidth: CGFloat = 1232
    /// Room for the shadow, the Pop outline and the word and line boxes.
    static let padding: CGFloat = 41
    static let canvasWidth: CGFloat = (wrapWidth + padding * 2).rounded(.up)
    /// Signal yellow, and the ink that sits on it (LumaTheme.signal / onSignal).
    static let signalHex = "#FFC53D"
    static let onSignalHex = "#120D00"
}

/// Builds the compositor payload for a styled caption layer.
enum CaptionLayout {
    /// The OverlaySpec for a styled caption, measured with the caption layout
    /// so preview, export and the on-picture handles agree on its size. nil
    /// when the layer is hidden from the picture (kept only for the SRT) or
    /// has nothing to draw.
    static func overlaySpec(for overlay: EditorState.OverlayItem,
                            start: Double, end: Double) -> OverlaySpec? {
        guard !overlay.captionHidden,
              let text = overlay.text,
              let raw = overlay.captionStyle,
              let style = CaptionStyle(rawValue: raw),
              let extent = TextRasterizer.captionExtent(text, style: style) else { return nil }
        var spec = OverlaySpec(id: overlay.id,
                               trackID: kCMPersistentTrackID_Invalid,
                               imageURL: nil,
                               transform: .identity,
                               sourceExtent: extent,
                               start: start, end: end,
                               text: text,
                               textSpec: overlay.textSpec,
                               textAnimation: overlay.textAnimation,
                               lane: overlay.lane)
        spec.captionStyle = style.rawValue
        spec.captionWords = overlay.captionWords
        return spec
    }
}

// MARK: - Transcribing the edit

extension EditorState {
    /// Listens to the edit's own mixed sound and returns caption lines in
    /// timeline time, without touching the timeline (the Captions panel lays
    /// them in with `replaceCaptions`). Throws `CaptionEngineError` for the
    /// states the panel explains: permission, no sound, no speech, language.
    func transcribeCaptions(locale: Locale,
                            onProgress: CaptionProgressHandler? = nil) async throws -> CaptionTranscript {
        guard totalDuration > 0.2 else { throw CaptionEngineError.noAudio }
        guard await CaptionEngine.requestAuthorization() else { throw CaptionEngineError.notAuthorized }
        onProgress?(.preparingAudio)
        let built = try await buildComposition(renderScale: 1)
        guard !built.composition.tracks(withMediaType: .audio).isEmpty else {
            throw CaptionEngineError.noAudio
        }
        let audioURL = try await VideoExporter().exportAudioOnly(asset: built.composition,
                                                                 audioMix: built.audioMix)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        return try await CaptionEngine.transcribeDetailed(url: audioURL, locale: locale,
                                                          maxWords: 6, maxDuration: 3.0,
                                                          maxCharacters: 32,
                                                          totalDuration: built.duration,
                                                          onProgress: onProgress)
    }
}
