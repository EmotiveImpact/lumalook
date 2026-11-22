import SwiftUI
import CoreMotion

/// The camera's level, as the Camera Lab draws it: a line either side of a
/// small signal-yellow ring, 180 pt across. The lines stay on the horizon as
/// the phone rolls, and light up when it is level (within a degree), upright
/// or sideways.
///
/// The simulator has no motion hardware, so there the mark rests at
/// `restTurn`: flat upright, and turned with the controls when the preview
/// forces the sideways layout.
struct LevelIndicator: View {
    /// Where the mark rests when there is no motion to read.
    var restTurn: Double = 0

    @StateObject private var motion = MotionRollModel()

    var body: some View {
        let live = motion.isLive
        let roll = motion.rollDegrees
        // How far off the nearest of upright and sideways.
        let off = abs(roll.remainder(dividingBy: 90))
        let isLevel = live && off < 1.0
        let line = isLevel ? CamLab.sig : Color.white.opacity(0.6)
        HStack(spacing: 8) {
            Rectangle().fill(line).frame(height: 1.5)
            Circle()
                .strokeBorder(CamLab.sig, lineWidth: 1.5)
                .background(Circle().fill(isLevel ? CamLab.sig.opacity(0.35) : Color.clear))
                .frame(width: 14, height: 14)
            Rectangle().fill(line).frame(height: 1.5)
        }
        .frame(width: 180, height: 14)
        .rotationEffect(.degrees(live ? -roll : restTurn))
        .animation(.easeOut(duration: 0.12), value: isLevel)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}

/// Publishes device roll at about 15 Hz: enough for a smooth line without
/// burning the main thread during recording.
private final class MotionRollModel: ObservableObject {
    /// 0 upright, ±90 on either side.
    @Published var rollDegrees: Double = 0
    /// False until the first reading (always, in the simulator).
    @Published var isLive = false
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 15.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // Lying flat there is no horizon to read; hold the last angle.
            guard hypot(data.gravity.x, data.gravity.y) > 0.25 else { return }
            self.rollDegrees = atan2(data.gravity.x, -data.gravity.y) * 180 / .pi
            if !self.isLive { self.isLive = true }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
