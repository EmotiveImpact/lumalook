import Foundation
import SwiftUI

// MARK: - Stored models (SPEC_ADDENDUM §2)

struct StoredClip: Codable, Identifiable {
    var id: UUID
    var fileName: String        // inside Documents/Clips
    var assetDuration: Double
    var trimStart: Double
    var trimEnd: Double
    var speed: Double
    // Optional so pre-per-clip-audio projects still decode.
    var volume: Double? = nil
    var isMuted: Bool? = nil
    /// TransitionStyle rawValue at this clip's out-point (optional: legacy).
    var transitionAfter: String? = nil
    /// Photo clip on the main track (T7). Optional so pre-photo projects
    /// still decode; nil means video.
    var isImage: Bool? = nil
    /// Per-clip grade override. Optional so older projects still decode;
    /// nil means the clip follows the timeline's global grade.
    var grade: ClipGrade? = nil
    /// Custom transition duration at this clip's out-point (nil = style default).
    var transitionDuration: Double? = nil
    /// User display transforms (rotate/mirror). Optional-at-end so older
    /// projects decode; nil = no user orientation.
    var rotationQuarterTurns: Int? = nil
    var isMirrored: Bool? = nil
    /// Free crop (unit rect) + straighten degrees. Optional-at-end; nil = full.
    var cropX: Double? = nil
    var cropY: Double? = nil
    var cropW: Double? = nil
    var cropH: Double? = nil
    var straightenDegrees: Double? = nil
    /// Ken Burns pan/zoom keyframes. Optional-at-end; nil = static.
    var transformKeyframes: [ClipTransformKeyframe]? = nil
    /// Speed-ramp preset rawValue. Optional-at-end; nil = none.
    var speedRamp: String? = nil
    /// Per-clip audio fades (A3). Optional-at-end.
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
    var fadeCurve: String? = nil
}

/// A pinned overlay placement at an offset within the overlay's run (T5).
struct OverlayKeyframe: Codable, Equatable {
    var time: Double
    var sizeFraction: Double
    var centerX: Double
    var centerY: Double
    var opacity: Double
    var rotationDegrees: Double
    /// Easing for the segment leaving this keyframe (rawValue; nil = linear).
    var easing: String? = nil
}

/// A picture-in-picture overlay (video or still) attached to a project.
struct StoredOverlay: Codable {
    var id: UUID
    var fileName: String        // inside Documents/Clips
    var isImage: Bool
    var title: String? = nil
    var timelineOffset: Double
    var duration: Double
    var sizeFraction: Double
    var centerX: Double
    var centerY: Double
    var opacity: Double
    /// Overlay audio mix (optional: pre-overlay-audio projects decode).
    var volume: Double? = nil
    var isMuted: Bool? = nil
    /// Keyframed motion (optional-at-end: legacy projects decode).
    var rotationDegrees: Double? = nil
    var keyframes: [OverlayKeyframe]? = nil
    /// Trim window into the overlay's own media (optional-at-end).
    var mediaStart: Double? = nil
    var mediaDuration: Double? = nil
    /// Text layer (optional-at-end): the string, style raw value, colour hex.
    var text: String? = nil
    var textStyle: String? = nil
    var textColorHex: String? = nil
    /// Stacking lane / z-order. Optional-at-end; nil = lane 0.
    var lane: Int? = nil
    /// Effect stack (blend/chroma/mask/adjust/border). Optional-at-end.
    var effects: OverlayEffects? = nil
}

/// Background-music track attached to a project.
struct StoredMusic: Codable {
    var id: UUID
    var fileName: String        // inside Documents/Audio
    var title: String
    var assetDuration: Double
    var trimStart: Double
    var trimEnd: Double
    var timelineOffset: Double
    var volume: Double
    var isMuted: Bool
    /// Lane kind (music/voice/sfx/extracted). Optional-at-end; nil = music.
    var kind: String? = nil
    /// Fades (A3), volume envelope (A4), ducking (A5), looping (A6).
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
    var fadeCurve: String? = nil
    var volumePoints: [AudioVolumePoint]? = nil
    var duckingEnabled: Bool? = nil
    var isLooping: Bool? = nil
    /// Audio effect stack (EQ/pitch/voice/reverb/gain). Optional-at-end.
    var effects: AudioEffectSettings? = nil
}

struct StoredProject: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var clips: [StoredClip]
    var format: String          // EditorFormat rawValue
    var zoom: Double
    var volume: Double
    var fadeIn: Double
    var fadeOut: Double
    var muteAudio: Bool
    var duration: Double
    // Optional so pre-music Projects.json files still decode. Never add a
    // non-optional field here: `load` uses try? and would wipe every project.
    var music: StoredMusic? = nil
    /// Multi-audio lanes (music/voiceover/sound). Optional so both legacy
    /// generations of Projects.json still decode; `music` above is only read
    /// for migration.
    var audioTracks: [StoredMusic]? = nil
    /// PIP overlay lane (T1). Optional with nil default AT THE STRUCT END —
    /// every earlier generation of Projects.json must keep decoding.
    var overlays: [StoredOverlay]? = nil
    /// Canvas background (fill/fit/blur/solid/gradient) + its colours.
    /// Optional-at-end; nil = fill (the legacy behaviour).
    var canvasMode: String? = nil
    var canvasSolidHex: String? = nil
    var canvasGradientTopHex: String? = nil
    var canvasGradientBottomHex: String? = nil
    /// Adjustment layers (full-frame grades over time). Optional-at-end.
    var adjustmentLayers: [AdjustmentLayer]? = nil
    /// Audio-reactive visual config (D1). Optional-at-end.
    var audioReactive: StoredAudioReactive? = nil
}

/// Persisted audio-reactive config.
struct StoredAudioReactive: Codable {
    var style: String
    var strength: Double
    var sourceTrackID: UUID?
}

/// An Apply-a-Look session: the media + the exact grade, restorable from
/// Recent Projects (queue #13 — all three LUT-niche competitors converge).
struct GradeSession: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var mediaFileName: String       // inside Documents/Clips
    var isVideo: Bool
    var baseLookName: String
    var settings: LookSettings
    var lutID: UUID?
    var conversionLUTID: UUID?
    var conversionOpacity: Double?
    var creativeOpacity: Double?
    var creativeBlend: String?
}

struct SavedLook: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var baseLookName: String
    var settings: LookSettings
    var lutID: UUID?
}

// MARK: - Store

@MainActor
final class PersistenceStore: ObservableObject {
    @Published private(set) var projects: [StoredProject] = []
    @Published private(set) var savedLooks: [SavedLook] = []
    @Published private(set) var gradeSessions: [GradeSession] = []

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var clipsFolder: URL { documents.appendingPathComponent("Clips", isDirectory: true) }
    var audioFolder: URL { documents.appendingPathComponent("Audio", isDirectory: true) }
    private var projectsURL: URL { documents.appendingPathComponent("Projects.json") }
    private var looksURL: URL { documents.appendingPathComponent("SavedLooks.json") }
    private var sessionsURL: URL { documents.appendingPathComponent("GradeSessions.json") }

    init() {
        try? FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        projects = Self.load([StoredProject].self, from: projectsURL) ?? []
        savedLooks = Self.load([SavedLook].self, from: looksURL) ?? []
        gradeSessions = Self.load([GradeSession].self, from: sessionsURL) ?? []
    }

    // MARK: Clips library

    /// Copies a picked/temp media file into the durable clip library.
    func importClipFile(from url: URL) -> URL? {
        let name = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        let destination = clipsFolder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    func clipURL(for stored: StoredClip) -> URL {
        clipsFolder.appendingPathComponent(stored.fileName)
    }

    // MARK: Audio library

    /// Copies a picked audio file into the durable audio library.
    /// Must be called synchronously while any security scope is still open.
    func importAudioFile(from url: URL) -> URL? {
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let destination = audioFolder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    func audioURL(for stored: StoredMusic) -> URL {
        audioFolder.appendingPathComponent(stored.fileName)
    }

    // MARK: Projects

    func upsert(project: StoredProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
        Self.save(projects, to: projectsURL)
    }

    func deleteProject(_ id: UUID) {
        let removed = projects.first { $0.id == id }
        projects.removeAll { $0.id == id }
        Self.save(projects, to: projectsURL)
        cleanUpMedia(of: removed)
    }

    /// Deleting a project must also delete its copied media, or Documents
    /// balloons forever — but only files no OTHER project still references.
    private func cleanUpMedia(of removed: StoredProject?) {
        guard let removed else { return }
        // Clip library files are shared by clips AND overlays across projects.
        let liveClipFiles = Set(projects.flatMap { project in
            project.clips.map(\.fileName) + (project.overlays ?? []).map(\.fileName)
        })
        let removedClipFiles = removed.clips.map(\.fileName) + (removed.overlays ?? []).map(\.fileName)
        for fileName in removedClipFiles where !liveClipFiles.contains(fileName) {
            try? FileManager.default.removeItem(at: clipsFolder.appendingPathComponent(fileName))
        }
        let removedAudio = (removed.audioTracks ?? []) + (removed.music.map { [$0] } ?? [])
        let liveAudioFiles = Set(projects.flatMap { project in
            (project.audioTracks ?? []).map(\.fileName) + (project.music.map { [$0.fileName] } ?? [])
        })
        for audio in removedAudio where !liveAudioFiles.contains(audio.fileName) {
            try? FileManager.default.removeItem(at: audioFolder.appendingPathComponent(audio.fileName))
        }
    }

    // MARK: Grade sessions

    func upsert(session: GradeSession) {
        if let index = gradeSessions.firstIndex(where: { $0.id == session.id }) {
            gradeSessions[index] = session
        } else {
            gradeSessions.insert(session, at: 0)
        }
        gradeSessions.sort { $0.updatedAt > $1.updatedAt }
        // Keep the ten most recent; older sessions age out with their media
        // (unless a project also references the file).
        while gradeSessions.count > 10 {
            let dropped = gradeSessions.removeLast()
            deleteSessionMediaIfOrphaned(dropped)
        }
        Self.save(gradeSessions, to: sessionsURL)
    }

    func deleteSession(_ id: UUID) {
        guard let session = gradeSessions.first(where: { $0.id == id }) else { return }
        gradeSessions.removeAll { $0.id == id }
        Self.save(gradeSessions, to: sessionsURL)
        deleteSessionMediaIfOrphaned(session)
    }

    func sessionMediaURL(_ session: GradeSession) -> URL {
        clipsFolder.appendingPathComponent(session.mediaFileName)
    }

    private func deleteSessionMediaIfOrphaned(_ session: GradeSession) {
        let inProjects = projects.contains { project in
            project.clips.contains { $0.fileName == session.mediaFileName }
                || (project.overlays ?? []).contains { $0.fileName == session.mediaFileName }
        }
        let inSessions = gradeSessions.contains { $0.mediaFileName == session.mediaFileName }
        if !inProjects && !inSessions {
            try? FileManager.default.removeItem(at: clipsFolder.appendingPathComponent(session.mediaFileName))
        }
    }

    // MARK: Saved looks

    func saveLook(_ look: SavedLook) {
        savedLooks.insert(look, at: 0)
        Self.save(savedLooks, to: looksURL)
    }

    func deleteLook(_ id: UUID) {
        savedLooks.removeAll { $0.id == id }
        Self.save(savedLooks, to: looksURL)
    }

    // MARK: IO

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
