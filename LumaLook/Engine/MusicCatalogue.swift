import SwiftUI

// MARK: - Music catalogue
//
// The tracks LumaLook renders itself (see MusicSynth.swift). Royalty-free by
// construction: nothing here was recorded, sampled or licensed. Each entry is
// a recipe (genre, tempo, key, chord progression, seed), so the catalogue is
// tiny and the audio is made on first use and cached.

enum MusicGenre: String, CaseIterable {
    case afrobeats, amapiano, house, garage, drill, lofi, pop, cinematic, trap, rnb

    var label: String {
        switch self {
        case .afrobeats: return "Afrobeats"
        case .amapiano: return "Amapiano"
        case .house: return "House"
        case .garage: return "UK garage"
        case .drill: return "Drill"
        case .lofi: return "Lo-fi"
        case .pop: return "Pop"
        case .cinematic: return "Cinematic"
        case .trap: return "Trap"
        case .rnb: return "R&B"
        }
    }
}

enum MusicMood: String, CaseIterable {
    case party, chill, happy, lateNight, hype, cinematic, romantic

    var label: String {
        switch self {
        case .party: return "Party"
        case .chill: return "Chill"
        case .happy: return "Happy"
        case .lateNight: return "Late night"
        case .hype: return "Hype"
        case .cinematic: return "Cinematic"
        case .romantic: return "Romantic"
        }
    }
}

/// One generated track: everything the synth needs, plus what the library shows.
struct GeneratedTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let genre: MusicGenre
    let mood: MusicMood
    let bpm: Double
    /// Length in bars (a multiple of eight: the arrangement works in sections).
    let bars: Int
    /// 1 (calm) … 5 (flat out).
    let energy: Int
    let colourHex: UInt32
    let seed: UInt32
    /// Key root as a MIDI note in octave three (48…59).
    let root: Int
    let minor: Bool
    /// Scale degrees, one chord per bar, repeating every four bars.
    let progression: [Int]

    var beatSeconds: Double { 60 / bpm }
    var barSeconds: Double { 4 * 60 / bpm }
    var duration: Double { Double(bars) * barSeconds }
    var beatCount: Int { bars * 4 }

    /// Exact beat times in seconds from the start of the file. Beat 0 is the
    /// downbeat of bar one, so every fourth beat is a bar line.
    var beatTimes: [Double] {
        (0..<beatCount).map { Double($0) * beatSeconds }
    }

    var colour: Color { Color(hex: colourHex) }

    var bpmLabel: String { "\(Int(bpm.rounded())) BPM" }

    var lengthLabel: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var keyLabel: String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let name = names[((root % 12) + 12) % 12]
        return minor ? "\(name) minor" : "\(name) major"
    }

    /// Where an audition starts: the first bar with drums.
    var previewStart: Double {
        Double(MusicArrangement.previewBar(for: self)) * barSeconds
    }

    /// Two bars of the groove as bar heights (kick tallest, then snare, hats,
    /// percussion): the row's beat preview, drawn without rendering audio.
    var beatPreview: [Float] {
        let recipe = SynthRecipe.recipe(for: genre)
        func hit(_ pattern: [String], bar: Int, step: Int) -> Character {
            guard !pattern.isEmpty else { return "." }
            let chars = Array(pattern[bar % pattern.count])
            return step < chars.count ? chars[step] : "."
        }
        var bars: [Float] = []
        for bar in 0..<2 {
            for step in 0..<16 {
                var v: Float = 0.12
                let perc = hit(recipe.perc, bar: bar, step: step)
                if perc != "." { v = max(v, 0.32) }
                let hat = hit(recipe.hats, bar: bar, step: step)
                if hat != "." { v = max(v, hat == "o" ? 0.26 : 0.4) }
                let snare = hit(recipe.snare, bar: bar, step: step)
                if snare == "x" || snare == "X" { v = max(v, 0.78) } else if snare == "o" { v = max(v, 0.45) }
                let kick = hit(recipe.kick, bar: bar, step: step)
                if kick == "x" || kick == "X" { v = max(v, 1) } else if kick == "o" { v = max(v, 0.6) }
                bars.append(v)
            }
        }
        return bars
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if name.lowercased().contains(q) { return true }
        if genre.label.lowercased().contains(q) { return true }
        if mood.label.lowercased().contains(q) { return true }
        if "\(Int(bpm.rounded()))".hasPrefix(q) { return true }
        return false
    }
}

enum MusicCatalogue {
    // Progressions are scale degrees from 0 (the tonic): in a major key
    // 0 4 5 3 is I V vi IV; in a minor key 0 5 6 4 is i VI VII v.
    static let tracks: [GeneratedTrack] = [
        GeneratedTrack(id: "lagos-sunset", name: "Lagos Sunset", genre: .afrobeats, mood: .happy,
                       bpm: 104, bars: 40, energy: 3, colourHex: 0xFF8A3D, seed: 104_001,
                       root: 54, minor: false, progression: [0, 5, 3, 4]),
        GeneratedTrack(id: "danfo-ride", name: "Danfo Ride", genre: .afrobeats, mood: .party,
                       bpm: 108, bars: 40, energy: 4, colourHex: 0xFFB547, seed: 108_002,
                       root: 57, minor: true, progression: [0, 3, 6, 5]),
        GeneratedTrack(id: "coastline", name: "Coastline", genre: .afrobeats, mood: .chill,
                       bpm: 100, bars: 32, energy: 2, colourHex: 0x2EC4B6, seed: 100_003,
                       root: 56, minor: false, progression: [0, 4, 5, 3]),
        GeneratedTrack(id: "pretoria-nights", name: "Pretoria Nights", genre: .amapiano, mood: .lateNight,
                       bpm: 112, bars: 48, energy: 3, colourHex: 0x2EC4B6, seed: 112_004,
                       root: 53, minor: true, progression: [0, 5, 3, 6]),
        GeneratedTrack(id: "piano-hands", name: "Piano Hands", genre: .amapiano, mood: .party,
                       bpm: 113, bars: 40, energy: 4, colourHex: 0xD4AF6A, seed: 113_005,
                       root: 55, minor: false, progression: [1, 4, 0, 5]),
        GeneratedTrack(id: "warehouse-hours", name: "Warehouse Hours", genre: .house, mood: .party,
                       bpm: 124, bars: 48, energy: 5, colourHex: 0xFF3DB4, seed: 124_006,
                       root: 52, minor: true, progression: [0, 5, 6, 4]),
        GeneratedTrack(id: "mirrorball", name: "Mirrorball", genre: .house, mood: .happy,
                       bpm: 122, bars: 48, energy: 4, colourHex: 0xFF8FB8, seed: 122_007,
                       root: 57, minor: false, progression: [0, 4, 5, 3]),
        GeneratedTrack(id: "southside-shuffle", name: "Southside Shuffle", genre: .garage, mood: .lateNight,
                       bpm: 132, bars: 48, energy: 4, colourHex: 0x7C9CFF, seed: 132_008,
                       root: 50, minor: true, progression: [0, 6, 5, 4]),
        GeneratedTrack(id: "night-bus", name: "Night Bus", genre: .garage, mood: .lateNight,
                       bpm: 130, bars: 48, energy: 3, colourHex: 0x8DB3D6, seed: 130_009,
                       root: 56, minor: true, progression: [0, 3, 5, 6]),
        GeneratedTrack(id: "concrete", name: "Concrete", genre: .drill, mood: .hype,
                       bpm: 140, bars: 56, energy: 4, colourHex: 0xFF4B3E, seed: 140_010,
                       root: 49, minor: true, progression: [0, 5, 0, 6]),
        GeneratedTrack(id: "smoke-signals", name: "Smoke Signals", genre: .drill, mood: .hype,
                       bpm: 142, bars: 48, energy: 5, colourHex: 0xC8C8C8, seed: 142_011,
                       root: 51, minor: true, progression: [0, 5, 3, 4]),
        GeneratedTrack(id: "late-library", name: "Late Library", genre: .lofi, mood: .chill,
                       bpm: 84, bars: 32, energy: 1, colourHex: 0xC9A27E, seed: 84_012,
                       root: 53, minor: false, progression: [1, 4, 0, 5]),
        GeneratedTrack(id: "rain-on-glass", name: "Rain on Glass", genre: .lofi, mood: .chill,
                       bpm: 80, bars: 32, energy: 1, colourHex: 0x86C98B, seed: 80_013,
                       root: 57, minor: true, progression: [0, 3, 6, 2]),
        GeneratedTrack(id: "sunday-best", name: "Sunday Best", genre: .pop, mood: .happy,
                       bpm: 118, bars: 48, energy: 3, colourHex: 0xE8E2D6, seed: 118_014,
                       root: 48, minor: false, progression: [0, 4, 5, 3]),
        GeneratedTrack(id: "main-character", name: "Main Character", genre: .pop, mood: .hype,
                       bpm: 120, bars: 48, energy: 4, colourHex: 0xFFB547, seed: 120_015,
                       root: 55, minor: false, progression: [5, 3, 0, 4]),
        GeneratedTrack(id: "opening-titles", name: "Opening Titles", genre: .cinematic, mood: .cinematic,
                       bpm: 90, bars: 32, energy: 3, colourHex: 0xD4AF6A, seed: 90_016,
                       root: 50, minor: true, progression: [0, 5, 3, 4]),
        GeneratedTrack(id: "last-light", name: "Last Light", genre: .cinematic, mood: .cinematic,
                       bpm: 76, bars: 32, energy: 2, colourHex: 0xFF8A3D, seed: 76_017,
                       root: 55, minor: true, progression: [0, 3, 5, 4]),
        GeneratedTrack(id: "neon-rush", name: "Neon Rush", genre: .trap, mood: .hype,
                       bpm: 145, bars: 56, energy: 5, colourHex: 0xFF3DB4, seed: 145_018,
                       root: 54, minor: true, progression: [0, 5, 6, 5]),
        GeneratedTrack(id: "velvet-hour", name: "Velvet Hour", genre: .rnb, mood: .romantic,
                       bpm: 92, bars: 32, energy: 2, colourHex: 0xFF8FB8, seed: 92_019,
                       root: 52, minor: true, progression: [0, 3, 5, 4]),
        GeneratedTrack(id: "slow-burn", name: "Slow Burn", genre: .rnb, mood: .romantic,
                       bpm: 88, bars: 32, energy: 2, colourHex: 0xC9A27E, seed: 88_020,
                       root: 51, minor: false, progression: [1, 4, 0, 5]),
    ]

    static func track(id: String) -> GeneratedTrack? {
        tracks.first { $0.id == id }
    }
}

// MARK: - Beat grid registry

/// Remembers which imported audio files are generated tracks, so their beat
/// grid stays exact after the project is closed and opened again (lane beat
/// markers are not persisted). Keyed by the file name in the project's audio
/// folder, which survives reloads. UserDefaults is thread-safe, so the beat
/// detector can ask from any thread.
enum MusicBeatGrid {
    private static let key = "lumalook.generatedMusicGrids"

    struct Entry {
        let trackID: String
        let bpm: Double
        let beatCount: Int

        var beats: [Double] {
            guard bpm > 0 else { return [] }
            return (0..<beatCount).map { Double($0) * 60 / bpm }
        }
    }

    static func register(fileName: String, track: GeneratedTrack) {
        var all: [String: Any] = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        let value: [String: Any] = ["id": track.id, "bpm": track.bpm, "beats": track.beatCount]
        all[fileName] = value
        UserDefaults.standard.set(all, forKey: key)
    }

    static func entry(fileName: String) -> Entry? {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let raw = all[fileName] as? [String: Any],
              let id = raw["id"] as? String,
              let bpm = raw["bpm"] as? Double,
              let count = raw["beats"] as? Int else { return nil }
        return Entry(trackID: id, bpm: bpm, beatCount: count)
    }

    static func entry(for url: URL) -> Entry? {
        entry(fileName: url.lastPathComponent)
    }

    /// The generated track a lane plays: from the registry, or from a file
    /// straight out of the render cache ("<track id>-v<n>.m4a").
    static func track(for url: URL) -> GeneratedTrack? {
        if let entry = entry(for: url), let track = MusicCatalogue.track(id: entry.trackID) {
            return track
        }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let dash = stem.range(of: "-v", options: .backwards) else { return nil }
        return MusicCatalogue.track(id: String(stem[..<dash.lowerBound]))
    }
}

// MARK: - Library store

/// Renders tracks on demand (once each, then cached in Caches) and keeps the
/// listener's favourites.
@MainActor
final class MusicLibraryStore: ObservableObject {
    static let shared = MusicLibraryStore()

    /// Track ids being rendered right now.
    @Published private(set) var rendering: Set<String> = []
    @Published private(set) var favourites: Set<String> = []

    private var tasks: [String: Task<URL?, Never>] = [:]
    private static let favouritesKey = "lumalook.musicFavourites"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.favouritesKey) ?? []
        favourites = Set(saved)
    }

    nonisolated static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("GeneratedMusic", isDirectory: true)
    }

    nonisolated static func fileURL(for track: GeneratedTrack) -> URL {
        folder.appendingPathComponent("\(track.id)-v\(MusicSynth.version).m4a")
    }

    /// The rendered file if it is already on disk (AAC, or the PCM fallback).
    func cachedURL(for track: GeneratedTrack) -> URL? {
        let m4a = Self.fileURL(for: track)
        if FileManager.default.fileExists(atPath: m4a.path) { return m4a }
        let caf = m4a.deletingPathExtension().appendingPathExtension("caf")
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        return nil
    }

    func isRendering(_ track: GeneratedTrack) -> Bool {
        rendering.contains(track.id)
    }

    /// Renders on first use (off the main thread), then serves the cache.
    func prepare(_ track: GeneratedTrack) async -> URL? {
        if let url = cachedURL(for: track) { return url }
        if let running = tasks[track.id] { return await running.value }
        rendering.insert(track.id)
        let destination = Self.fileURL(for: track)
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            MusicSynth.renderFile(track, to: destination)
        }
        tasks[track.id] = task
        let url = await task.value
        tasks[track.id] = nil
        rendering.remove(track.id)
        return url
    }

    /// Renders (if needed) and lays the track on a new music lane with its
    /// exact beat grid. Returns false when the file could not be made.
    @discardableResult
    func use(_ track: GeneratedTrack, in editor: EditorState) async -> Bool {
        guard let url = await prepare(track) else { return false }
        guard let imported = editor.importMusicFile(from: url) else { return false }
        MusicBeatGrid.register(fileName: imported.lastPathComponent, track: track)
        await editor.addAudioTrack(importedURL: imported, title: track.name, kind: .music)
        if let lane = editor.audioTracks.last(where: { $0.url == imported }) {
            editor.setBeatMarkers(trackID: lane.id, track.beatTimes)
        }
        return true
    }

    func isFavourite(_ track: GeneratedTrack) -> Bool {
        favourites.contains(track.id)
    }

    func toggleFavourite(_ track: GeneratedTrack) {
        if favourites.contains(track.id) {
            favourites.remove(track.id)
        } else {
            favourites.insert(track.id)
        }
        UserDefaults.standard.set(Array(favourites).sorted(), forKey: Self.favouritesKey)
    }
}
