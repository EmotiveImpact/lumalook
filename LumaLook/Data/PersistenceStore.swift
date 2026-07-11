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

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var clipsFolder: URL { documents.appendingPathComponent("Clips", isDirectory: true) }
    var audioFolder: URL { documents.appendingPathComponent("Audio", isDirectory: true) }
    private var projectsURL: URL { documents.appendingPathComponent("Projects.json") }
    private var looksURL: URL { documents.appendingPathComponent("SavedLooks.json") }

    init() {
        try? FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        projects = Self.load([StoredProject].self, from: projectsURL) ?? []
        savedLooks = Self.load([SavedLook].self, from: looksURL) ?? []
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
        let liveClipFiles = Set(projects.flatMap { $0.clips.map(\.fileName) })
        for clip in removed.clips where !liveClipFiles.contains(clip.fileName) {
            try? FileManager.default.removeItem(at: clipsFolder.appendingPathComponent(clip.fileName))
        }
        let removedAudio = (removed.audioTracks ?? []) + (removed.music.map { [$0] } ?? [])
        let liveAudioFiles = Set(projects.flatMap { project in
            (project.audioTracks ?? []).map(\.fileName) + (project.music.map { [$0.fileName] } ?? [])
        })
        for audio in removedAudio where !liveAudioFiles.contains(audio.fileName) {
            try? FileManager.default.removeItem(at: audioFolder.appendingPathComponent(audio.fileName))
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
