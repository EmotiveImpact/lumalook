import CoreImage
import SwiftUI

/// T2.4 — renders the CURRENT preview frame through candidate grades that
/// clone the live look and swap ONLY the creative LUT (+ its remembered
/// strength/blend): an honest "same grade, different LUT" A/B. Ephemeral —
/// nothing persists; mirrors LookThumbs' detached, cancellable shape.
@MainActor
final class CompareRenderer: ObservableObject {
    @Published var images: [String: CGImage] = [:]
    private var renderTask: Task<Void, Never>?
    private var lastStamp = ""

    /// `nil` in `candidates` = the Original (no creative LUT) cell.
    func render(frame: CIImage?, baseSettings: LookSettings,
                candidates: [(file: LUTFile, url: URL)?]) {
        guard let frame else { return }
        let stamp = "\(frame.extent)-\(baseSettings)-\(candidates.compactMap { $0?.file.id.uuidString }.joined())"
        guard stamp != lastStamp else { return }
        lastStamp = stamp

        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let pipeline = LookPipeline.shared
            for candidate in candidates {
                if Task.isCancelled { return }
                let state = LookState()
                state.settings = baseSettings
                if let candidate {
                    guard let parsed = try? pipeline.loadLUT(at: candidate.url) else { continue }
                    state.lut = parsed
                    state.lutOpacity = (candidate.file.defaultOpacity ?? 100) / 100
                    state.lutBlend = candidate.file.defaultBlend.flatMap(LUTBlendMode.init) ?? .normal
                }
                let key = candidate.map { "lut-\($0.file.id)" } ?? "original"
                if let cg = pipeline.gradedStill(frame, state: state, maxDimension: 700) {
                    await MainActor.run { self?.images[key] = cg }
                }
            }
        }
    }
}
