import SwiftUI
import CoreImage

/// Renders the look strip's thumbnails from a REAL source frame — the
/// user's actual clip or photo — through the full grading pipeline, so
/// every thumbnail shows exactly what that look does to their footage.
/// This is the difference between a mockup and a grading tool.
@MainActor
final class LookThumbs: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var renderTask: Task<Void, Never>?
    private var lastStamp = ""
    private static let stampContext = CIContext(options: [.cacheIntermediates: false])

    /// The unified cache key — one scheme for every surface (`LibraryLook.id`,
    /// which is stable across launches, unlike `LookPreset.id`).
    static func key(_ look: LibraryLook) -> String { look.thumbKey }

    /// Reference swatch for the empty state before any media is selected —
    /// thumbnails are individually graded from day one. `LookSwatch` owns the
    /// frame itself: a wide-gamut photograph plus a skin/grey/highlight patch
    /// band, so twelve different grades read as twelve different tiles.
    static let fallbackFrame: CIImage = LookSwatch.referenceFrame

    /// A portrait for the Looks tab's poster tiles: every look shown on a
    /// face, without the calibration band the strip swatch carries.
    static let portraitFrame: CIImage = {
        guard let photo = HeroPhoto.bridge.ciImage else { return fallbackFrame }
        let longest = max(photo.extent.width, photo.extent.height)
        let scale = longest > 900 ? 900 / longest : 1
        let scaled = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: -scaled.extent.minX, y: -scaled.extent.minY))
    }()

    /// One render job per library look, resolved on the main actor so the
    /// detached render loop never touches the repository.
    private struct Job {
        let key: String
        let recipe: LookRecipe?
        let settings: LookSettings
        let lutURL: URL?
    }

    /// A small pixel digest makes equal-sized clips distinct, while recipe,
    /// settings and LUT file metadata invalidate thumbnails when a look is
    /// edited or its cube is replaced in place.
    private static func renderStamp(frame: CIImage, isFallback: Bool,
                                    jobs: [Job]) -> String {
        var hasher = Hasher()
        hasher.combine(isFallback)
        // CGRect is only Hashable from iOS 18; hash its parts so iOS 17
        // devices never reach a conformance they don't have.
        let extent = frame.extent
        hasher.combine(extent.origin.x)
        hasher.combine(extent.origin.y)
        hasher.combine(extent.size.width)
        hasher.combine(extent.size.height)

        let sampleBounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let normalized = frame
            .transformed(by: CGAffineTransform(
                translationX: -frame.extent.minX, y: -frame.extent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: sampleBounds.width / max(frame.extent.width, 1),
                y: sampleBounds.height / max(frame.extent.height, 1)))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            Self.stampContext.render(normalized, toBitmap: baseAddress,
                                     rowBytes: 8 * 4, bounds: sampleBounds,
                                     format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        pixels.withUnsafeBytes { hasher.combine(bytes: $0) }

        let encoder = JSONEncoder()
        for job in jobs {
            hasher.combine(job.key)
            hasher.combine(job.recipe)
            if let settings = try? encoder.encode(job.settings) {
                settings.withUnsafeBytes { hasher.combine(bytes: $0) }
            }
            if let url = job.lutURL {
                hasher.combine(url.standardizedFileURL.path)
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    hasher.combine(values.fileSize)
                    hasher.combine(values.contentModificationDate)
                }
            }
        }
        return String(hasher.finalize())
    }

    /// Renders a thumbnail for EVERY kind of library look through the real
    /// pipeline: builtIn → recipe, lut → cube, saved → recipe + the user's
    /// saved settings + optional cube. `fileURL` resolves a LUT's cube path
    /// (pass `lutRepository.fileURL(for:)`).
    func render(source: CIImage?, library: [LibraryLook], fileURL: (LUTFile) -> URL,
                maxDimension: CGFloat = 220) {
        let frame = source ?? Self.fallbackFrame
        var fullStrength = LookSettings()
        fullStrength.intensity = 100
        // Saved looks reference their cube by id — resolve against the
        // library's own LUT entries.
        let lutByID = Dictionary(
            library.compactMap { look -> (UUID, LUTFile)? in
                guard case .lut(let f) = look.source else { return nil }
                return (f.id, f)
            },
            uniquingKeysWith: { a, _ in a })

        let jobs: [Job] = library.map { look in
            switch look.source {
            case .builtIn(let p):
                return Job(key: look.thumbKey, recipe: p.recipe,
                           settings: fullStrength, lutURL: nil)
            case .lut(let f):
                return Job(key: look.thumbKey, recipe: nil,
                           settings: fullStrength, lutURL: fileURL(f))
            case .saved(let s):
                let recipe = MockData.looks.first { $0.name == s.baseLookName }?.recipe
                let url = s.lutID.flatMap { lutByID[$0] }.map(fileURL)
                return Job(key: look.thumbKey, recipe: recipe,
                           settings: s.settings, lutURL: url)
            }
        }

        let stamp = Self.renderStamp(frame: frame, isFallback: source == nil, jobs: jobs)
        guard stamp != lastStamp else { return }
        lastStamp = stamp

        renderTask?.cancel()
        images = [:]
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let pipeline = LookPipeline.shared
            for job in jobs {
                if Task.isCancelled { return }
                let state = LookState()
                if let recipe = job.recipe { state.recipe = recipe }
                state.settings = job.settings
                if let url = job.lutURL {
                    guard let parsed = try? pipeline.loadLUT(at: url) else { continue }
                    state.lut = parsed
                }
                if let cg = pipeline.gradedStill(frame, state: state, maxDimension: maxDimension),
                   !Task.isCancelled {
                    await MainActor.run {
                        guard self?.lastStamp == stamp else { return }
                        self?.images[job.key] = cg
                    }
                }
            }
        }
    }
}

/// A real graded-frame thumbnail with the standard selection chrome.
struct GradedThumb: View {
    let image: CGImage
    var size: CGSize = CGSize(width: 96, height: 96)
    var radius: CGFloat = 16
    var selected: Bool = false

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            // clipShape clips PIXELS, not touches: a landscape frame scaled to
            // fill a portrait tile overflows well past its bounds, so in a rail
            // each tile's invisible overflow sat on top of its neighbours and
            // ate their taps — which is why look tiles could not be selected.
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? .white : .white.opacity(0.08),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .shadow(color: selected ? .black.opacity(0.6) : .clear, radius: 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}
