import SwiftUI
import UIKit

// MARK: - Semantic haptics engine

/// Central haptics engine for the editor and camera surfaces.
///
/// SwiftUI's `.sensoryFeedback` is great for state-driven feedback (and remains
/// the preferred tool for simple "value changed" cases — see `LumaTabBar`,
/// `InlineSlider`). But gesture-driven surfaces like the timeline need
/// *imperative*, low-latency ticks fired from the middle of a drag, often
/// dozens of times per second. For that we keep a small set of pre-warmed
/// `UIFeedbackGenerator`s alive and expose **semantic** methods
/// (`timelineSnap()`, not `light.impactOccurred()`), so call sites read as
/// intent and the exact feel can be retuned in one place.
///
/// Usage:
/// ```swift
/// LumaHaptics.shared.timelineSnap()          // playhead crossed a clip edge
/// LumaHaptics.shared.reorderStart()          // long-press lifted a clip
/// LumaHaptics.shared.trimRubberband(0.7)     // trim handle resisting past a limit
/// ```
///
/// All generators are prepared at init and re-prepared after every fire, so
/// the Taptic Engine stays spun up during continuous interactions.
@MainActor
final class LumaHaptics {

    static let shared = LumaHaptics()

    // Pre-warmed generators. Keeping dedicated instances per style avoids
    // re-allocating (and cold-starting) the Taptic Engine mid-gesture.
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    /// Minimum spacing between rapid-fire ticks (snap / rubber-band), so a
    /// fast scrub doesn't degenerate into a continuous buzz.
    private let minTickInterval: TimeInterval = 1.0 / 30.0
    private var lastTick: TimeInterval = 0

    private init() {
        prepare()
    }

    /// Spin up the Taptic Engine ahead of an interaction-heavy screen
    /// (call from `.onAppear` of the editor / camera if desired).
    func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        rigidImpact.prepare()
        softImpact.prepare()
        selection.prepare()
        notification.prepare()
    }

    /// Rate limiter for continuous ticks. Returns `true` when enough time has
    /// passed since the previous tick to fire again.
    private func admitTick() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastTick >= minTickInterval else { return false }
        lastTick = now
        return true
    }

    // MARK: Semantic events

    /// The playhead or a dragged clip edge snapped to a boundary
    /// (clip edge, second marker, other clip's edge). Crisp, tiny.
    func timelineSnap() {
        guard admitTick() else { return }
        selection.selectionChanged()
        selection.prepare()
    }

    /// A long-press "picked up" a clip for reordering — the moment the clip
    /// lifts out of the track. One solid, deliberate thunk.
    func reorderStart() {
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    /// A dragged clip settled into its slot on release. Softer than pickup —
    /// the object landing back on the shelf.
    func reorderDrop() {
        softImpact.impactOccurred(intensity: 0.9)
        softImpact.prepare()
    }

    /// A trim handle is being pulled past its limit and rubber-banding.
    /// Fire continuously while overscrolled; `intensity` (0...1) should track
    /// how hard the user is pulling against the limit.
    func trimRubberband(_ intensity: CGFloat = 0.6) {
        guard admitTick() else { return }
        rigidImpact.impactOccurred(intensity: max(0.2, min(intensity, 1)))
        rigidImpact.prepare()
    }

    /// Record button engaged / shutter fired. Heavy and mechanical.
    func shutter() {
        rigidImpact.impactOccurred(intensity: 1.0)
        rigidImpact.prepare()
    }

    /// Export finished writing to the photo library. Success flourish.
    func exportSuccess() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// Something failed in a user-visible way (export error, load failure).
    func failure() {
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    /// Generic light tap for small confirmations (tool selected, chip toggled)
    /// where no dedicated semantic method exists yet.
    func tap() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }
}

// MARK: - Preview

/// Haptics only fire on a physical device; this preview is a semantic
/// "sound board" for tuning each event by feel.
#Preview("LumaHaptics sound board") {
    struct HapticRow: View {
        let title: String
        let subtitle: String
        let fire: () -> Void

        var body: some View {
            Button(action: fire) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.luma(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.luma(size: 13))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .buttonStyle(.lumaPress)
            .lumaCard()
        }
    }

    return ScrollView {
        VStack(spacing: 12) {
            HapticRow(title: "timelineSnap()", subtitle: "Playhead crossed a clip edge") {
                LumaHaptics.shared.timelineSnap()
            }
            HapticRow(title: "reorderStart()", subtitle: "Clip lifted for drag") {
                LumaHaptics.shared.reorderStart()
            }
            HapticRow(title: "reorderDrop()", subtitle: "Clip settled into slot") {
                LumaHaptics.shared.reorderDrop()
            }
            HapticRow(title: "trimRubberband(0.8)", subtitle: "Trim handle past its limit") {
                LumaHaptics.shared.trimRubberband(0.8)
            }
            HapticRow(title: "shutter()", subtitle: "Record engaged") {
                LumaHaptics.shared.shutter()
            }
            HapticRow(title: "exportSuccess()", subtitle: "Saved to photo library") {
                LumaHaptics.shared.exportSuccess()
            }
            HapticRow(title: "failure()", subtitle: "Export error") {
                LumaHaptics.shared.failure()
            }
            HapticRow(title: "tap()", subtitle: "Generic light confirmation") {
                LumaHaptics.shared.tap()
            }
        }
        .padding(22)
    }
    .background(LumaTheme.background)
    .preferredColorScheme(.dark)
}
