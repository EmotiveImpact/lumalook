import CoreImage
import SwiftUI

/// T2.4 — renders the CURRENT preview frame through candidate grades that
/// clone the live look and swap ONLY the creative LUT (+ its remembered
/// strength/blend): an honest "same grade, different LUT" A/B. Ephemeral —
/// nothing persists; mirrors LookThumbs' detached, cancellable shape.
///
/// Every cell shows what tapping it gives. The cell without a LUT is the
/// built-in look the app falls back to, with the grade as it stands. A LUT
/// cell wears the grade a pick leaves (`AppModel.settingsAfterPick`): a Skin
/// first preset or a saved look comes off when a look is picked, so the cell
/// is drawn without it. Both keep the conversion slot, which a pick never
/// touches.
@MainActor
final class CompareRenderer: ObservableObject {
    /// The live state every candidate is cloned from.
    struct Live: @unchecked Sendable {
        /// The built-in look shown when no LUT is selected.
        var recipe: LookRecipe
        /// The grade as it stands: the cell without a LUT.
        var settings: LookSettings
        /// The grade a picked LUT is shown with.
        var pickedSettings: LookSettings
        var conversionLUT: ParsedLUT?
        var conversionOpacity: Double
        var conversionProfile: LogProfile?
    }

    @Published var images: [String: CGImage] = [:]
    private var renderTask: Task<Void, Never>?
    private var lastStamp = ""

    /// `nil` in `candidates` = the cell without a creative LUT.
    func render(frame: CIImage?, live: Live, stamp liveStamp: String,
                candidates: [(file: LUTFile, url: URL)?]) {
        guard let frame else { return }
        let stamp = "\(frame.extent)-\(liveStamp)-\(live.settings)-\(live.pickedSettings)-"
            + candidates.compactMap { c in
                c.map { "\($0.file.id.uuidString):\($0.file.defaultOpacity ?? 100):\($0.file.defaultBlend ?? "")" }
            }.joined()
        guard stamp != lastStamp else { return }
        lastStamp = stamp

        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let pipeline = LookPipeline.shared
            for candidate in candidates {
                if Task.isCancelled { return }
                let state = LookState()
                state.conversionLUT = live.conversionLUT
                state.conversionOpacity = live.conversionOpacity
                state.conversionProfile = live.conversionProfile
                if let candidate {
                    guard let parsed = try? pipeline.loadLUT(at: candidate.url) else { continue }
                    state.settings = live.pickedSettings
                    state.lut = parsed
                    state.lutOpacity = (candidate.file.defaultOpacity ?? 100) / 100
                    state.lutBlend = candidate.file.defaultBlend.flatMap(LUTBlendMode.init) ?? .normal
                } else {
                    state.settings = live.settings
                    state.recipe = live.recipe
                }
                let key = candidate.map { "lut-\($0.file.id)" } ?? "original"
                if let cg = pipeline.gradedStill(frame, state: state, maxDimension: 700) {
                    await MainActor.run { self?.images[key] = cg }
                }
            }
        }
    }
}
