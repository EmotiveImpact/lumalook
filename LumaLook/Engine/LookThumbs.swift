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

    /// The unified cache key — one scheme for every surface (`LibraryLook.id`,
    /// which is stable across launches, unlike `LookPreset.id`).
    static func key(_ look: LibraryLook) -> String { look.thumbKey }

    /// Real bundled photograph for the empty state before any media is
    /// selected — thumbnails are individually graded from day one.
    static let fallbackFrame: CIImage = {
        if let ci = HeroPhoto.golden.ciImage {
            let longest = max(ci.extent.width, ci.extent.height)
            let scale = longest > 440 ? 440 / longest : 1
            return ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let renderer = ImageRenderer(content: SceneArt(scene: .sunsetRoad)
            .frame(width: 440, height: 440))
        renderer.scale = 1
        if let cg = renderer.cgImage { return CIImage(cgImage: cg) }
        return CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.13))
            .cropped(to: CGRect(x: 0, y: 0, width: 440, height: 440))
    }()

    /// One render job per library look, resolved on the main actor so the
    /// detached render loop never touches the repository.
    private struct Job {
        let key: String
        let recipe: LookRecipe?
        let settings: LookSettings
        let lutURL: URL?
    }

    /// Renders a thumbnail for EVERY kind of library look through the real
    /// pipeline: builtIn → recipe, lut → cube, saved → recipe + the user's
    /// saved settings + optional cube. `fileURL` resolves a LUT's cube path
    /// (pass `lutRepository.fileURL(for:)`).
    func render(source: CIImage?, library: [LibraryLook], fileURL: (LUTFile) -> URL) {
        let frame = source ?? Self.fallbackFrame
        let stamp = "\(frame.extent)-\(source == nil)-\(library.map(\.id).joined())"
        guard stamp != lastStamp else { return }
        lastStamp = stamp

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

        renderTask?.cancel()
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
                if let cg = pipeline.gradedStill(frame, state: state, maxDimension: 220) {
                    await MainActor.run { self?.images[job.key] = cg }
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
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? LumaTheme.accentBright : .white.opacity(0.08),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .shadow(color: selected ? LumaTheme.accent.opacity(0.45) : .clear, radius: 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}
