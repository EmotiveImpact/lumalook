import Foundation

/// C3 — the user-chosen capture format. Portrait-first (the writer records
/// upright buffers), persisted as a compact rawValue in UserDefaults so the
/// camera opens how you left it.
struct CameraSpec: Equatable {
    enum Resolution: String, CaseIterable {
        case hd720 = "720", hd1080 = "1080", uhd4K = "4K"

        /// Portrait output dimensions (width, height).
        var portrait: (w: Int, h: Int) {
            switch self {
            case .hd720:  return (720, 1280)
            case .hd1080: return (1080, 1920)
            case .uhd4K:  return (2160, 3840)
            }
        }
    }

    enum Codec: String, CaseIterable {
        case h264 = "H.264", hevc = "HEVC"
    }

    var resolution: Resolution = .hd1080
    var fps: Int = 30
    var codec: Codec = .hevc

    static let fpsOptions = [24, 25, 30, 60]

    /// The honest HUD readout ("4K • 60").
    var hudLabel: String { "\(resolution.rawValue) • \(fps)" }

    // MARK: persistence

    var rawValue: String { "\(resolution.rawValue)|\(fps)|\(codec.rawValue)" }

    static func from(rawValue: String) -> CameraSpec {
        var spec = CameraSpec()
        let parts = rawValue.split(separator: "|").map(String.init)
        if parts.count >= 3 {
            spec.resolution = Resolution(rawValue: parts[0]) ?? .hd1080
            spec.fps = Int(parts[1]) ?? 30
            spec.codec = Codec(rawValue: parts[2]) ?? .hevc
        }
        return spec
    }

    static func load() -> CameraSpec {
        UserDefaults.standard.string(forKey: "cameraSpec").map(from(rawValue:)) ?? CameraSpec()
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "cameraSpec")
    }
}
