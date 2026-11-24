import Foundation

/// Features that are built but switched off until they are ready. Flip one to
/// true to bring it back; the code behind it is untouched.
enum LumaFeatures {
    /// Cut to the beat: Home's beat-cut template rail (Home shows a plain
    /// Templates rail instead), the beat-cut templates in the editor's
    /// template lists, and the Cut to the beat button and its every-N-beats
    /// menu in the editor's music lane panel. Off until it has had more work
    /// (Edem, 23 Nov 2026).
    static let cutToTheBeat = false

    /// Templates: Home's Templates row and quick tile, the Templates pills
    /// and starter grid in Projects, and the editor's "Start from a
    /// template" band. Off until templates are up to the standard of the
    /// best editors (Edem, 23 Nov 2026). Projects and edits already made
    /// from a template still open as normal.
    static let templates = false

    /// Auto on the look screen: one tap that sets exposure and white balance
    /// from the picture's average colour. A portrait's average is mostly
    /// skin, so Auto took warm skin for a colour cast and cooled it: 11 of
    /// the 16 test portraits came out bluer, three as far as it can go, and
    /// nothing on screen showed it was on or took it off again. Off until it
    /// is rebuilt to leave skin alone (found 24 Nov 2026 on Edem's own
    /// picture). `AppModel.autoGrade` and its tile are kept.
    static let autoGrade = false
}

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
    /// Beats per minute the slots are cut to. Optional (synthesised Codable
    /// decodes it with decodeIfPresent), so older templates.json files load.
    var bpm: Int? = nil
    /// True when every cut lands on a beat: Home's "Cut to the beat" rail
    /// shows only these. Optional for the same reason as `bpm`.
    var beatCut: Bool? = nil
    /// Bundled poster photo, a `HeroPhoto` rawValue such as "hero_party".
    var poster: String? = nil

    /// Nominal runtime before the applier clamps slots to real asset lengths, so
    /// the grid can show "≈4.8s" without touching the photo library.
    var totalDuration: Double { slots.reduce(0) { $0 + $1.duration } }

    /// How many clips the template is built for (one per slot).
    var clipCount: Int { slots.count }

    /// Cut to the beat: only templates flagged as such (a missing flag is false).
    var isBeatCut: Bool { beatCut ?? false }

    init(id: String,
         name: String,
         blurb: String,
         icon: String,
         aspect: String,
         slots: [TemplateSlot],
         lookName: String? = nil,
         canvasMode: String? = nil,
         audioReactive: String? = nil,
         bpm: Int? = nil,
         beatCut: Bool? = nil,
         poster: String? = nil) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.icon = icon
        self.aspect = aspect
        self.slots = slots
        self.lookName = lookName
        self.canvasMode = canvasMode
        self.audioReactive = audioReactive
        self.bpm = bpm
        self.beatCut = beatCut
        self.poster = poster
    }
}

enum TemplateLibrary {
    private static let lock = NSLock()
    private static var cached: [VideoTemplate]?

    /// Templates loaded from the bundled Templates/templates.json, falling back
    /// to `builtIn` when the resource is missing or malformed. Decoded once and
    /// memoised — the card grid re-reads this on every layout pass.
    /// The templates offered in lists (Home, the editor's template panel and
    /// library). While Cut to the beat is off the beat-cut ones are left out;
    /// a template id already in a project still resolves through `all`.
    static var shown: [VideoTemplate] {
        LumaFeatures.cutToTheBeat ? all : all.filter { !$0.isBeatCut }
    }

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
            audioReactive: "pulse",
            // Half-second slots are one beat each at 120 BPM.
            bpm: 120,
            beatCut: true,
            poster: "hero_rain"
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
        ),

        // Cut to the beat (Home rail). Every slot holds a whole number of
        // beats at the template's tempo, so each cut lands on a beat, with a
        // flash on the drops. Free looks only, like every bundled template.
        VideoTemplate(
            id: "night-out-recap",
            name: "Night out recap",
            blurb: "Six clips on a 112 BPM beat, with a flash on the drops.",
            icon: "music.note",
            aspect: "9:16",
            slots: onBeat([4, 4, 6, 4, 4, 6], bpm: 112, flashAfter: [1, 4]),
            lookName: "KD2 · Golden Hour",
            audioReactive: "pulse",
            bpm: 112,
            beatCut: true,
            poster: "hero_party"
        ),
        VideoTemplate(
            id: "front-row",
            name: "Front row",
            blurb: "Five clips at 128 BPM for gig and festival footage.",
            icon: "music.mic",
            aspect: "9:16",
            slots: onBeat([4, 6, 4, 6, 6], bpm: 128, flashAfter: [2]),
            lookName: "KD52 · Cine Negative",
            audioReactive: "glow",
            bpm: 128,
            beatCut: true,
            poster: "hero_gig"
        ),
        VideoTemplate(
            id: "city-walk",
            name: "City walk",
            blurb: "Four easy clips at 96 BPM. Hard cuts, no tricks.",
            icon: "figure.walk",
            aspect: "9:16",
            slots: onBeat([4, 4, 4, 4], bpm: 96),
            lookName: "KD4 · Clean Neutral",
            bpm: 96,
            beatCut: true,
            poster: "hero_bridge"
        )
    ]

    /// Slots cut on the beat. Each entry is how many beats that clip holds at
    /// `bpm`, so every cut lands on a beat of the track. Cuts are hard
    /// ("none") except after the slot indices in `flashAfter`; the last slot
    /// has no outgoing transition.
    private static func onBeat(_ beats: [Int], bpm: Int, flashAfter: Set<Int> = []) -> [TemplateSlot] {
        let beat = 60.0 / Double(max(bpm, 1))
        var slots: [TemplateSlot] = []
        for index in 0..<beats.count {
            let isLast = index == beats.count - 1
            let flash = !isLast && flashAfter.contains(index)
            let transition: String? = isLast ? nil : (flash ? "flash" : "none")
            slots.append(TemplateSlot(duration: Double(beats[index]) * beat,
                                      transitionAfter: transition,
                                      transitionDuration: flash ? 0.12 : nil))
        }
        return slots
    }

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
