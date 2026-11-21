import SwiftUI

/// C10 — aspect-ratio frame guides + social safe zones. Frame for the final
/// crop while shooting: cinema mattes (2.39 / 1.85), vertical (9:16), square
/// (1:1), portrait (4:5), plus a TikTok/Reels/Shorts safe-zone inset that
/// keeps titles clear of platform chrome.
enum FrameGuide: String, CaseIterable {
    case off, cinemascope, flat, vertical, square, portrait45

    var label: String {
        switch self {
        case .off:         return "Off"
        case .cinemascope: return "2.39:1"
        case .flat:        return "1.85:1"
        case .vertical:    return "9:16"
        case .square:      return "1:1"
        case .portrait45:  return "4:5"
        }
    }

    /// Target aspect (w/h), nil = off.
    var aspect: CGFloat? {
        switch self {
        case .off:         return nil
        case .cinemascope: return 2.39
        case .flat:        return 1.85
        case .vertical:    return 9.0 / 16.0
        case .square:      return 1
        case .portrait45:  return 4.0 / 5.0
        }
    }
}

/// Dims everything outside the guide's aspect on the viewfinder, with a thin
/// edge line; optionally shows the social safe zone inside vertical guides.
struct FrameGuidesOverlay: View {
    let guide: FrameGuide
    var showSafeZone: Bool = false

    var body: some View {
        GeometryReader { geo in
            if let aspect = guide.aspect {
                let view = geo.size
                let target: CGSize = {
                    // Fit the guide box inside the viewfinder.
                    let byWidth = CGSize(width: view.width, height: view.width / aspect)
                    if byWidth.height <= view.height { return byWidth }
                    return CGSize(width: view.height * aspect, height: view.height)
                }()
                let origin = CGPoint(x: (view.width - target.width) / 2,
                                     y: (view.height - target.height) / 2)
                let frame = CGRect(origin: origin, size: target)

                ZStack {
                    // Mattes: darken outside the frame.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: view))
                        p.addRect(frame)
                    }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))

                    Rectangle()
                        .stroke(.white.opacity(0.65), lineWidth: 1)
                        .frame(width: target.width, height: target.height)
                        .position(x: frame.midX, y: frame.midY)

                    // Social safe zone: platform chrome eats ~10% top, ~22%
                    // bottom, ~12% right (buttons rail) on 9:16 feeds.
                    if showSafeZone, guide == .vertical {
                        let safe = CGRect(
                            x: frame.minX + target.width * 0.04,
                            y: frame.minY + target.height * 0.10,
                            width: target.width * 0.84,
                            height: target.height * 0.68)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(LumaTheme.teal.opacity(0.8),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .frame(width: safe.width, height: safe.height)
                            .position(x: safe.midX, y: safe.midY)
                        Text("SAFE")
                            .font(.luma(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(LumaTheme.teal.opacity(0.9))
                            .position(x: safe.midX, y: safe.minY + 10)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}
