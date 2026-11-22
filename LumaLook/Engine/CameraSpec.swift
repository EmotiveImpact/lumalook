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

/// The photo camera's still format: HEIF or JPEG, and the size in megapixels.
/// Persisted like `CameraSpec`. The size is what the user asked for; the
/// controller only ever offers sizes the current camera can deliver
/// (`AVCaptureDevice.Format.supportedMaxPhotoDimensions`).
struct PhotoCaptureSpec: Equatable {
    enum Format: String, CaseIterable {
        case heif = "HEIF", jpeg = "JPEG"
    }

    enum Size: Int, CaseIterable {
        case mp12 = 12, mp24 = 24, mp48 = 48

        var label: String { "\(rawValue) MP" }

        /// Nominal pixel count of the iPhone sensor modes (4032×3024,
        /// 5712×4284, 8064×6048).
        var pixelCount: Int64 {
            switch self {
            case .mp12: return 12_192_768
            case .mp24: return 24_470_208
            case .mp48: return 48_771_072
            }
        }

        /// The size a delivered photo resolution belongs to, if any. Anything
        /// smaller than about 10 MP (a video-sized still) matches none.
        static func matching(width: Int32, height: Int32) -> Size? {
            let pixels = Int64(width) * Int64(height)
            if pixels < 10_000_000 { return nil }
            if pixels < 18_000_000 { return .mp12 }
            if pixels < 36_000_000 { return .mp24 }
            return .mp48
        }
    }

    var format: Format = .heif
    var size: Size = .mp12

    // MARK: persistence

    var rawValue: String { "\(format.rawValue)|\(size.rawValue)" }

    static func from(rawValue: String) -> PhotoCaptureSpec {
        var spec = PhotoCaptureSpec()
        let parts = rawValue.split(separator: "|").map(String.init)
        if parts.count >= 2 {
            spec.format = Format(rawValue: parts[0]) ?? .heif
            spec.size = Int(parts[1]).flatMap(Size.init(rawValue:)) ?? .mp12
        }
        return spec
    }

    static func load() -> PhotoCaptureSpec {
        UserDefaults.standard.string(forKey: "cameraPhotoSpec").map(from(rawValue:)) ?? PhotoCaptureSpec()
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "cameraPhotoSpec")
    }
}
