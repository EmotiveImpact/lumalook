import SwiftUI

/// Halide-style precision dial: a tick ruler slides under a fixed centre
/// indicator; every 5-unit detent ticks. Feels like a machined wheel, reads
/// like an instrument — the control equivalent of a focus ring.
struct LumaDial: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100

    @State private var dragStartValue: Double?
    private let pointsPerUnit: CGFloat = 4.5

    private var detent: Int { Int(value / 5) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(LumaTheme.textSecondary)
                Text("\(Int(value))")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: Int(value))
                    .foregroundStyle(.white)
            }

            ZStack {
                ruler
                // Fixed centre indicator.
                Rectangle()
                    .fill(LumaTheme.accentBright)
                    .frame(width: 2, height: 22)
                    .shadow(color: LumaTheme.accent.opacity(0.8), radius: 3)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragStartValue == nil { dragStartValue = value }
                        let delta = Double(-drag.translation.width / pointsPerUnit)
                        value = min(max(range.lowerBound, (dragStartValue ?? value) + delta),
                                    range.upperBound)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .sensoryFeedback(.selection, trigger: detent)
        }
    }

    /// Tick ruler that slides with the value: major tick every 10 units,
    /// minor every 2, fading at the edges.
    private var ruler: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let unitsVisible = size.width / pointsPerUnit
            let first = max(range.lowerBound, value - Double(unitsVisible / 2) - 2)
            let last = min(range.upperBound, value + Double(unitsVisible / 2) + 2)
            var unit = (first / 2).rounded(.down) * 2
            while unit <= last {
                let x = centerX + CGFloat(unit - value) * pointsPerUnit
                let isMajor = Int(unit) % 10 == 0
                let height: CGFloat = isMajor ? 16 : 8
                let edgeFade = 1 - abs(x - centerX) / centerX
                context.fill(
                    Path(CGRect(x: x - 0.5, y: (size.height - height) / 2,
                                width: 1, height: height)),
                    with: .color(.white.opacity((isMajor ? 0.55 : 0.25) * Double(edgeFade)))
                )
                unit += 2
            }
        }
        .allowsHitTesting(false)
    }
}
