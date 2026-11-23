import SwiftUI

/// When an audio tool is open, a card pinned to the TOP of the preview names
/// the audio asset being edited — its waveform, name, kind and duration — so
/// the controls below clearly belong to it. It is a band, not a scrim: the
/// image stays the interface and is never covered.
///
/// Calm (mock v2, music panel): a quiet art tile, the name in white and the
/// source in grey, then the waveform as wide as the band allows, in white with
/// white trim ends. No colour on it: colour here belongs to the footage.
struct AudioFocusView: View {
    let title: String
    let subtitle: String
    let icon: String
    let samples: [Float]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Self.plate(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.luma(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
            .frame(maxWidth: 132, alignment: .leading)
            .layoutPriority(1)
            // The big waveform: it takes every point the name leaves free.
            AudioFocusWaveform(samples: samples)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.72))
    }

    /// An OPAQUE tile. `LumaTheme.surface` is a translucent white, so over a
    /// video frame these tiles picked up whatever colour happened to be behind
    /// them (colour bars showed through and read as a render glitch). Backing
    /// the surface with the solid bar colour makes the asset row read as chrome
    /// regardless of the frame underneath (the mock's art tile, #232429).
    private static func plate(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: 0x232429))
    }
}

/// The asset's real waveform. When there are genuinely no samples — silent
/// clip, or extraction still in flight — it draws a flat baseline rather than
/// a synthetic sine: a fake waveform claims the asset has content it doesn't.
/// White trim ends mark where the lane starts and stops.
private struct AudioFocusWaveform: View {
    let samples: [Float]

    var body: some View {
        bars
            .padding(.horizontal, 9)
            .overlay(alignment: .leading) { trimEnd }
            .overlay(alignment: .trailing) { trimEnd }
            .allowsHitTesting(false)
    }

    private var trimEnd: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white)
            .frame(width: 3)
            .padding(.vertical, 2)
    }

    private var bars: some View {
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
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: 2, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(.white.opacity(0.62)))
            }
        }
    }
}
