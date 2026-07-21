import SwiftUI

/// When an audio tool is open, a card pinned to the TOP of the preview names
/// the audio asset being edited — its waveform, name, kind and duration — so
/// the controls below clearly belong to it. It is a band, not a scrim: the
/// image stays the interface and is never covered.
struct AudioFocusView: View {
    let title: String
    let subtitle: String
    let icon: String
    let samples: [Float]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Self.plate(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            AudioFocusWaveform(samples: samples)
                .frame(width: 130, height: 38)
                .background(Self.plate(cornerRadius: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72))
    }

    /// An OPAQUE tile. `LumaTheme.surface` is a translucent white, so over a
    /// video frame these tiles picked up whatever colour happened to be behind
    /// them (colour bars showed through and read as a render glitch). Backing
    /// the surface with the solid bar colour makes the asset row read as chrome
    /// regardless of the frame underneath.
    private static func plate(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LumaTheme.bar)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(LumaTheme.card))
    }
}

/// The asset's real waveform. When there are genuinely no samples — silent
/// clip, or extraction still in flight — it draws a flat baseline rather than
/// a synthetic sine: a fake waveform claims the asset has content it doesn't.
private struct AudioFocusWaveform: View {
    let samples: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard !samples.isEmpty else {
                let rect = CGRect(x: 0, y: size.height / 2 - 0.75,
                                  width: size.width, height: 1.5)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.75),
                         with: .color(.white.opacity(0.28)))
                return
            }
            let n = max(8, Int(size.width / 4))
            for i in 0..<n {
                let frac = Double(i) / Double(n)
                let value = CGFloat(abs(samples[min(samples.count - 1,
                                                    Int(frac * Double(samples.count)))]))
                let h = max(2, value * size.height * 0.92)
                let x = CGFloat(i) * size.width / CGFloat(n)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: 2.6, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.3),
                         with: .color(.white.opacity(0.85)))
            }
        }
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }
}
