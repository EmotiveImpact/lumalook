import SwiftUI

// Painterly stand-ins for the photography used in the reference designs:
// layered sky gradient, sun glow, mountain silhouettes, water band and
// vignette. Each MockScene is a different location; a `grade` tint lets
// look thumbnails show the same scene under different colour grades.

enum MockScene: CaseIterable, Hashable {
    case sunsetRoad, cityNight, coast, duskPurple, forest, goldenField, neonStreet, rainyCity, desert

    var sky: [Color] {
        switch self {
        case .sunsetRoad:  return [Color(red: 0.09, green: 0.10, blue: 0.25), Color(red: 0.55, green: 0.23, blue: 0.30), Color(red: 0.95, green: 0.55, blue: 0.20)]
        case .cityNight:   return [Color(red: 0.02, green: 0.04, blue: 0.12), Color(red: 0.06, green: 0.10, blue: 0.25), Color(red: 0.16, green: 0.20, blue: 0.42)]
        case .coast:       return [Color(red: 0.30, green: 0.42, blue: 0.60), Color(red: 0.62, green: 0.60, blue: 0.62), Color(red: 0.90, green: 0.66, blue: 0.42)]
        case .duskPurple:  return [Color(red: 0.12, green: 0.06, blue: 0.28), Color(red: 0.35, green: 0.16, blue: 0.45), Color(red: 0.80, green: 0.36, blue: 0.42)]
        case .forest:      return [Color(red: 0.05, green: 0.12, blue: 0.10), Color(red: 0.10, green: 0.25, blue: 0.18), Color(red: 0.55, green: 0.60, blue: 0.35)]
        case .goldenField: return [Color(red: 0.25, green: 0.15, blue: 0.08), Color(red: 0.75, green: 0.45, blue: 0.15), Color(red: 1.00, green: 0.78, blue: 0.35)]
        case .neonStreet:  return [Color(red: 0.05, green: 0.02, blue: 0.15), Color(red: 0.25, green: 0.06, blue: 0.35), Color(red: 0.85, green: 0.25, blue: 0.55)]
        case .rainyCity:   return [Color(red: 0.08, green: 0.10, blue: 0.16), Color(red: 0.16, green: 0.22, blue: 0.32), Color(red: 0.35, green: 0.45, blue: 0.55)]
        case .desert:      return [Color(red: 0.20, green: 0.08, blue: 0.15), Color(red: 0.65, green: 0.25, blue: 0.20), Color(red: 0.95, green: 0.60, blue: 0.30)]
        }
    }

    var sun: Color {
        switch self {
        case .cityNight: return Color(red: 0.85, green: 0.85, blue: 1.0)
        case .rainyCity: return Color(red: 0.80, green: 0.85, blue: 0.95)
        case .neonStreet: return Color(red: 1.0, green: 0.45, blue: 0.75)
        case .forest: return Color(red: 0.95, green: 0.95, blue: 0.70)
        default: return Color(red: 1.0, green: 0.80, blue: 0.45)
        }
    }

    var silhouette: Color {
        switch self {
        case .forest: return Color(red: 0.01, green: 0.05, blue: 0.03)
        case .cityNight, .rainyCity: return Color(red: 0.01, green: 0.02, blue: 0.06)
        default: return Color(red: 0.04, green: 0.02, blue: 0.06)
        }
    }

    var isCity: Bool {
        switch self {
        case .cityNight, .neonStreet, .rainyCity: return true
        default: return false
        }
    }
}

private struct MountainShape: Shape {
    var peaks: [(x: CGFloat, h: CGFloat)]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY - rect.height * (peaks.first?.h ?? 0.3) * 0.6))
        for peak in peaks {
            p.addLine(to: CGPoint(x: rect.width * peak.x, y: rect.maxY - rect.height * peak.h))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.18))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct SkylineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let towers: [(x: CGFloat, w: CGFloat, h: CGFloat)] = [
            (0.02, 0.10, 0.32), (0.14, 0.07, 0.48), (0.24, 0.11, 0.38),
            (0.38, 0.08, 0.62), (0.48, 0.12, 0.42), (0.62, 0.07, 0.55),
            (0.72, 0.10, 0.35), (0.84, 0.09, 0.50), (0.94, 0.06, 0.30)
        ]
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        for t in towers {
            let x0 = rect.width * t.x
            let x1 = x0 + rect.width * t.w
            let top = rect.maxY - rect.height * t.h
            p.addLine(to: CGPoint(x: x0, y: rect.maxY))
            p.addLine(to: CGPoint(x: x0, y: top))
            p.addLine(to: CGPoint(x: x1, y: top))
            p.addLine(to: CGPoint(x: x1, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The core scene painting, used at every thumbnail and preview size.
struct SceneArt: View {
    var scene: MockScene = .sunsetRoad
    var grade: Color? = nil            // look-specific colour cast
    var gradeOpacity: Double = 0.30

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                LinearGradient(colors: scene.sky, startPoint: .top, endPoint: .bottom)

                // Sun / moon glow just above the horizon — kept tight so the
                // scene stays rich instead of washing out.
                Circle()
                    .fill(RadialGradient(colors: [scene.sun.opacity(0.55), scene.sun.opacity(0)],
                                         center: .center, startRadius: 1, endRadius: h * 0.22))
                    .frame(width: h * 0.44, height: h * 0.44)
                    .offset(x: geo.size.width * 0.12, y: h * 0.14)
                    .blendMode(.screen)

                Circle()
                    .fill(scene.sun.opacity(scene.isCity ? 0.6 : 0.95))
                    .frame(width: h * 0.10, height: h * 0.10)
                    .offset(x: geo.size.width * 0.12, y: h * 0.13)
                    .blur(radius: 1.5)

                if scene.isCity {
                    SkylineShape()
                        .fill(scene.silhouette.opacity(0.92))
                        .frame(height: h * 0.55)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    // Window lights
                    HStack(spacing: h * 0.09) {
                        ForEach(0..<6, id: \.self) { i in
                            Circle()
                                .fill(scene.sun.opacity(i % 2 == 0 ? 0.8 : 0.5))
                                .frame(width: h * 0.03, height: h * 0.03)
                                .offset(y: h * CGFloat([0.06, -0.04, 0.10, 0.0, -0.08, 0.05][i]))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, h * 0.22)
                    .blur(radius: 0.5)
                } else {
                    MountainShape(peaks: [(0.22, 0.52), (0.45, 0.30), (0.72, 0.58), (0.95, 0.34)])
                        .fill(scene.silhouette.opacity(0.55))
                        .frame(height: h * 0.62)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    MountainShape(peaks: [(0.15, 0.34), (0.38, 0.52), (0.60, 0.26), (0.85, 0.44)])
                        .fill(scene.silhouette.opacity(0.88))
                        .frame(height: h * 0.45)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                // Water / road reflection band.
                LinearGradient(colors: [scene.silhouette.opacity(0.95), scene.sky[2].opacity(0.35), scene.silhouette.opacity(0.9)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: h * 0.14)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(0.85)

                // Colour grade cast for look previews.
                if let grade {
                    grade.opacity(gradeOpacity).blendMode(.overlay)
                    grade.opacity(gradeOpacity * 0.4).blendMode(.plusLighter)
                }

                // Cinematic vignette.
                RadialGradient(colors: [.clear, .black.opacity(0.38)],
                               center: .center, startRadius: h * 0.35, endRadius: h * 0.95)
            }
        }
        .clipped()
    }
}

/// Rounded scene thumbnail with optional selection ring, duration badge,
/// check mark and label-below layout used across the app.
struct SceneThumb: View {
    var scene: MockScene
    var grade: Color? = nil
    var radius: CGFloat = 14
    var duration: String? = nil
    var selected: Bool = false
    var showCheck: Bool = false

    var body: some View {
        SceneArt(scene: scene, grade: grade)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(duration)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showCheck && selected {
                    Circle()
                        .fill(LumaTheme.accent)
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white))
                        .padding(7)
                }
            }
            // MEANINGFUL: the selected-look ring. Unselected tiles carry none.
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(LumaTheme.accentBright, lineWidth: 2.5)
                }
            }
    }
}
