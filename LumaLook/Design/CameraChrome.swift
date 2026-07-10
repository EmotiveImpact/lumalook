import SwiftUI

/// Shared cinematic chrome for the camera and grade screens: monospaced
/// technical readouts, SMPTE-style timecode, rule-of-thirds grid,
/// letterbox mattes and the before/after wipe handle.
///
/// Design rules (Darkroom / Kino / Blackmagic grammar):
///   - Chrome is hueless — pure whites and blacks only, so it never
///     biases grading perception. The violet accent is reserved for
///     interactive / selected elements.
///   - Technical values speak in small ALL-CAPS monospaced type,
///     tracked out, white at reduced opacity.

// MARK: - Technical readout type

/// Small ALL-CAPS monospaced technical readout — the "instrument" voice
/// of the UI, used for format badges, timecode and media metadata.
struct TechReadout: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = .white.opacity(0.72)

    init(_ text: String, size: CGFloat = 12, color: Color = .white.opacity(0.72)) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .kerning(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - Timecode

enum Timecode {
    /// SMPTE-style `HH:MM:SS:FF` string for an elapsed duration.
    static func string(seconds: Double, fps: Double = 30) -> String {
        let clamped = max(seconds, 0)
        let whole = Int(clamped)
        let frames = Int((clamped - Double(whole)) * fps)
        return String(format: "%02d:%02d:%02d:%02d",
                      whole / 3600, (whole / 60) % 60, whole % 60, frames)
    }
}

// MARK: - Rule-of-thirds grid

/// Hairline rule-of-thirds overlay for the viewfinder. Hueless, thin,
/// never intercepts touches.
struct RuleOfThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Letterbox mattes

/// Cinema-style letterbox: black mattes above and below the picture with
/// a hairline marking the frame edge. Sized from the content's aspect
/// ratio inside whatever container it overlays.
struct LetterboxMattes: View {
    /// Aspect ratio (width / height) of the content being letterboxed.
    let contentAspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            let contentHeight = geo.size.width / max(contentAspect, 0.01)
            let barHeight = max((geo.size.height - contentHeight) / 2, 0)
            if barHeight > 2 {
                VStack(spacing: 0) {
                    matte(height: barHeight, hairlineAt: .bottom)
                    Spacer(minLength: 0)
                    matte(height: barHeight, hairlineAt: .top)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func matte(height: CGFloat, hairlineAt edge: Alignment) -> some View {
        Rectangle()
            .fill(.black.opacity(0.85))
            .frame(height: height)
            .overlay(alignment: edge) {
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(height: 0.5)
            }
    }
}

// MARK: - Before/After wipe handle

/// Industry-standard comparison wipe: a vertical hairline with a circular
/// grabber carrying left/right arrows, soft-shadowed so it reads over any
/// footage.
struct WipeHandle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .shadow(color: .black.opacity(0.45), radius: 4)
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .overlay {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.72))
                }
        }
    }
}
