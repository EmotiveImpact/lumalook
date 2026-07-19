import SwiftUI
import CoreMotion

/// C11 — gyroscope horizon level: a centre line that counter-rotates with
/// device roll and snaps solid green when level (±1°), the standard cue for
/// keeping horizons straight. Dead in the simulator (no motion hardware) —
/// the line simply stays at 0°, which is honest.
struct LevelIndicator: View {
    @StateObject private var motion = MotionRollModel()

    private var isLevel: Bool { abs(motion.rollDegrees) < 1.0 }

    var body: some View {
        ZStack {
            // Fixed reference ticks either side.
            HStack {
                tick
                Spacer()
                tick
            }
            .frame(width: 150)

            // The rolling horizon line.
            RoundedRectangle(cornerRadius: 1)
                .fill(isLevel ? Color.green : .white.opacity(0.85))
                .frame(width: isLevel ? 150 : 84, height: 2)
                .rotationEffect(.degrees(-motion.rollDegrees))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .animation(.easeOut(duration: 0.12), value: isLevel)
        }
        .allowsHitTesting(false)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    private var tick: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white.opacity(0.55))
            .frame(width: 22, height: 2)
            .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

/// Publishes device roll at ~15 Hz — enough for a smooth line without
/// burning the main thread during recording.
private final class MotionRollModel: ObservableObject {
    @Published var rollDegrees: Double = 0
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 15.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            // Portrait: gravity.x maps to roll about the screen axis.
            let roll = atan2(data.gravity.x, -data.gravity.y) * 180 / .pi
            self?.rollDegrees = max(-45, min(45, roll))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
