import SwiftUI

/// A 12-segment horizontal LED meter (green → yellow → red) driven by a live
/// 0…1 input level. Shown over the dock while recording a voiceover (B2).
struct InputMeterView: View {
    let level: Double        // 0…1
    private let segments = 12

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LumaTheme.teal)
            ForEach(0..<segments, id: \.self) { i in
                let threshold = Double(i + 1) / Double(segments)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level >= threshold ? color(for: i) : Color.white.opacity(0.12))
                    .frame(width: 10, height: 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func color(for index: Int) -> Color {
        let f = Double(index) / Double(segments)
        if f > 0.85 { return .red }
        if f > 0.6 { return .yellow }
        return .green
    }
}
