import Foundation

/// One royalty-free clip bundled with the app.
struct BundledAudioEntry: Identifiable, Codable {
    let id: String
    let title: String
    let category: String     // "sfx" | "music"
    let fileName: String
    let duration: Double
}

/// Loads the bundled audio-library manifest and resolves asset URLs.
enum BundledAudioLibrary {
    static let all: [BundledAudioEntry] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json",
                                        subdirectory: "AudioLibrary")
                ?? Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BundledAudioEntry].self, from: data) else {
            return []
        }
        return entries
    }()

    static func entries(category: String) -> [BundledAudioEntry] {
        all.filter { $0.category == category }
    }

    static func url(for entry: BundledAudioEntry) -> URL? {
        let name = (entry.fileName as NSString).deletingPathExtension
        let ext = (entry.fileName as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "AudioLibrary")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }
}
