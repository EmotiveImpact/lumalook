import Foundation

/// One clip slot in a template — a recipe for a single timeline clip, not a clip
/// itself. The applier pairs slot `i` with the user's `i`th picked media.
struct TemplateSlot: Codable, Equatable {
    /// Seconds this slot occupies on the timeline. The applier is expected to
    /// clamp against the real asset duration — a slot cannot invent footage.
    var duration: Double
    var speed: Double? = nil
    var transitionAfter: String? = nil      // TransitionStyle rawValue
    var transitionDuration: Double? = nil
    var kenBurns: String? = nil             // KenBurnsPreset rawValue, e.g. "zoomIn"
    var lookName: String? = nil             // built-in look preset name (MockData.looks)

    init(duration: Double,
         speed: Double? = nil,
         transitionAfter: String? = nil,
         transitionDuration: Double? = nil,
         kenBurns: String? = nil,
         lookName: String? = nil) {
        self.duration = duration
        self.speed = speed
        self.transitionAfter = transitionAfter
        self.transitionDuration = transitionDuration
        self.kenBurns = kenBurns
        self.lookName = lookName
    }
}

/// A full template: ordered slots + optional global look/canvas/effect hints.
/// Pure data — the applier owns every interpretation of these strings.
struct VideoTemplate: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var blurb: String
    var icon: String                        // SF Symbol
    var aspect: String                      // "9:16" | "1:1" | "16:9"
    var slots: [TemplateSlot]
    var lookName: String? = nil
    var canvasMode: String? = nil           // CanvasBackgroundMode rawValue
    var audioReactive: String? = nil        // AudioReactiveStyle rawValue

    /// Nominal runtime before the applier clamps slots to real asset lengths, so
    /// the grid can show "≈4.8s" without touching the photo library.
    var totalDuration: Double { slots.reduce(0) { $0 + $1.duration } }

    init(id: String,
         name: String,
         blurb: String,
         icon: String,
         aspect: String,
         slots: [TemplateSlot],
         lookName: String? = nil,
         canvasMode: String? = nil,
         audioReactive: String? = nil) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.icon = icon
        self.aspect = aspect
        self.slots = slots
        self.lookName = lookName
        self.canvasMode = canvasMode
        self.audioReactive = audioReactive
    }
}

enum TemplateLibrary {
    private static let lock = NSLock()
    private static var cached: [VideoTemplate]?

    /// Templates loaded from the bundled Templates/templates.json, falling back
    /// to `builtIn` when the resource is missing or malformed. Decoded once and
    /// memoised — the card grid re-reads this on every layout pass.
    static var all: [VideoTemplate] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = loadFromBundle() ?? builtIn
        cached = loaded
        return loaded
    }

    /// Any failure falls back rather than throwing: a missing JSON must never
    /// cost the user the whole feature, since `builtIn` is already complete.
    private static func loadFromBundle() -> [VideoTemplate]? {
        // Blue-folder references keep the subdirectory; a flat "Copy Bundle
        // Resources" build phase drops it. Try both before giving up.
        let url = Bundle.main.url(forResource: "templates", withExtension: "json", subdirectory: "Templates")
            ?? Bundle.main.url(forResource: "templates", withExtension: "json")
        guard let url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([VideoTemplate].self, from: data)
            return decoded.isEmpty ? nil : decoded
        } catch {
            return nil
        }
    }

    /// Hard-coded fallbacks so the feature always works.
    /// Look names must match `MockData.looks` exactly (note the "·" separator),
    /// and none are premium — a bundled template that opens a paywall is a bug.
    static let builtIn: [VideoTemplate] = [
        VideoTemplate(
            id: "quick-cuts",
            name: "Quick Cuts",
            blurb: "Six snappy beats with soft dissolves. Good for a day-in-the-life.",
            icon: "scissors",
            aspect: "9:16",
            slots: run(6, duration: 0.8, transition: "dissolve", transitionDuration: 0.2),
            lookName: "KD4 · Clean Neutral"
        ),
        VideoTemplate(
            id: "slow-reveal",
            name: "Slow Reveal",
            blurb: "Three lingering shots that push in. Lets the grade do the talking.",
            icon: "camera.aperture",
            aspect: "9:16",
            slots: [
                TemplateSlot(duration: 2.5, transitionAfter: "dissolve", transitionDuration: 0.6, kenBurns: "zoomIn"),
                TemplateSlot(duration: 2.5, transitionAfter: "dissolve", transitionDuration: 0.6, kenBurns: "zoomIn"),
                TemplateSlot(duration: 3.0, kenBurns: "zoomIn")
            ],
            lookName: "KD52 · Cine Negative"
        ),
        VideoTemplate(
            id: "beat-drop",
            name: "Beat Drop",
            blurb: "Eight half-second hits pushing left, pulsing to the track.",
            icon: "waveform",
            aspect: "9:16",
            slots: run(8, duration: 0.5, transition: "slideLeft", transitionDuration: 0.12),
            lookName: "AG60 · London Rain",
            audioReactive: "pulse"
        ),
        VideoTemplate(
            id: "story-intro",
            name: "Story Intro",
            blurb: "A short hook into a longer beat, blurred canvas for off-ratio media.",
            icon: "text.bubble",
            aspect: "9:16",
            slots: [
                TemplateSlot(duration: 3.0, transitionAfter: "lumaWipe", transitionDuration: 0.5),
                TemplateSlot(duration: 4.0)
            ],
            lookName: "KD2 · Golden Hour",
            canvasMode: "blur"
        ),
        VideoTemplate(
            id: "product-hero",
            name: "Product Hero",
            blurb: "Four square beats easing out. Built for the feed, not the story.",
            icon: "shippingbox",
            aspect: "1:1",
            slots: [
                TemplateSlot(duration: 2.0, transitionAfter: "dissolve", transitionDuration: 0.3, kenBurns: "zoomOut"),
                TemplateSlot(duration: 2.0, transitionAfter: "dissolve", transitionDuration: 0.3, kenBurns: "zoomOut"),
                TemplateSlot(duration: 2.0, transitionAfter: "dissolve", transitionDuration: 0.3, kenBurns: "zoomOut"),
                TemplateSlot(duration: 2.0, kenBurns: "zoomOut")
            ],
            lookName: "KD4 · Clean Neutral"
        )
    ]

    /// N identical slots where only the last one has no outgoing transition —
    /// a trailing transition would dissolve into nothing.
    private static func run(_ count: Int,
                            duration: Double,
                            transition: String,
                            transitionDuration: Double,
                            kenBurns: String? = nil) -> [TemplateSlot] {
        (0..<max(count, 1)).map { i in
            let isLast = i == count - 1
            return TemplateSlot(duration: duration,
                                transitionAfter: isLast ? nil : transition,
                                transitionDuration: isLast ? nil : transitionDuration,
                                kenBurns: kenBurns)
        }
    }
}
