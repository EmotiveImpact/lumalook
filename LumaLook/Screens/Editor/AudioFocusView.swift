import SwiftUI

/// When an audio panel is open, the preview area shows the AUDIO ASSET — its
/// waveform, name, kind and duration — as the focus, so the controls in the
/// sheet below clearly belong to it instead of floating over an unrelated
/// video frame. The video sits dimmed behind this scrim.
struct AudioFocusView: View {
    let title: String
    let subtitle: String
    let icon: String
    let samples: [Float]

    var body: some View {
        // Top-anchored: the preview frame extends behind the sheet, so the
        // VISIBLE band is its top. Pin the asset bar there so it always shows.
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.82), .black.opacity(0.42)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
                    .frame(width: 46, height: 46)
                    .background(Self.plate(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                AudioFocusWaveform(samples: samples)
                    .frame(width: 150, height: 46)
                    .background(Self.plate(cornerRadius: 11))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
    }

    /// An OPAQUE tile. `LumaTheme.surface` is a translucent white, so over a
    /// video frame these tiles picked up whatever colour happened to be behind
    /// them (colour bars showed through and read as a render glitch). Backing
    /// the surface with the solid bar colour makes the asset row read as chrome
    /// regardless of the frame underneath.
    private static func plate(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LumaTheme.bar)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(LumaTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// The asset's waveform. Falls back to a soft flat pulse when the source has
/// no precomputed samples (e.g. a clip's own audio).
private struct AudioFocusWaveform: View {
    let samples: [Float]

    var body: some View {
        Canvas { ctx, size in
            let n = max(8, Int(size.width / 4))
            let opacity = samples.isEmpty ? 0.22 : 0.85
            for i in 0..<n {
                let frac = Double(i) / Double(n)
                let value: CGFloat
                if samples.isEmpty {
                    value = 0.22 + 0.14 * CGFloat(abs(sin(frac * 26)))   // gentle placeholder
                } else {
                    value = CGFloat(abs(samples[min(samples.count - 1, Int(frac * Double(samples.count)))]))
                }
                let h = max(2, value * size.height * 0.92)
                let x = CGFloat(i) * size.width / CGFloat(n)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: 2.6, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.3),
                         with: .color(.white.opacity(opacity)))
            }
        }
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }
}
