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

    static func key(look: LookPreset) -> String { "look-\(look.id)" }
    static func key(lut: LUTFile) -> String { "lut-\(lut.id)" }

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

    func render(source: CIImage?, looks: [LookPreset], luts: [(file: LUTFile, url: URL)]) {
        let frame = source ?? Self.fallbackFrame
        let stamp = "\(frame.extent)-\(source == nil)-\(looks.map(\.name).joined())-\(luts.count)"
        guard stamp != lastStamp else { return }
        lastStamp = stamp

        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let pipeline = LookPipeline.shared
            var fullStrength = LookSettings()
            fullStrength.intensity = 100

            for look in looks {
                if Task.isCancelled { return }
                let state = LookState()
                state.recipe = look.recipe
                state.settings = fullStrength
                if let cg = pipeline.gradedStill(frame, state: state, maxDimension: 220) {
                    let key = "look-\(look.id)"
                    await MainActor.run { self?.images[key] = cg }
                }
            }
            for lut in luts {
                if Task.isCancelled { return }
                guard let parsed = try? pipeline.loadLUT(at: lut.url) else { continue }
                let state = LookState()
                state.settings = fullStrength
                state.lut = parsed
                if let cg = pipeline.gradedStill(frame, state: state, maxDimension: 220) {
                    let key = "lut-\(lut.file.id)"
                    await MainActor.run { self?.images[key] = cg }
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
