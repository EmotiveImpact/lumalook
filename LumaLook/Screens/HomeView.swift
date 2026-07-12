import SwiftUI
import AVFoundation
import CoreImage

struct HomeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 26) {
                    // Wordmark owns the very top; gear/crown ride its line.
                    ZStack(alignment: .top) {
                        HStack {
                            Button { app.path.append(.settings) } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            Button { app.path.append(.settings) } label: {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(LumaTheme.gold)
                            }
                        }
                        .padding(.top, 6)

                        VStack(spacing: 8) {
                            LumaWordmark(size: 34)
                            Text("Cinematic looks for your world")
                                .font(.system(size: 15))
                                .foregroundStyle(LumaTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                        HomeTile(title: "Apply a Look", subtitle: "Quickly color grade your footage",
                                 icon: "camera.filters", gradient: LumaTheme.tilePurple,
                                 iconTint: Color(red: 0.85, green: 0.78, blue: 1.0)) {
                            app.path.append(.selectClip)
                        }
                        HomeTile(title: "Edit a Video", subtitle: "Edit clips, add music and create",
                                 icon: "square.and.pencil", gradient: LumaTheme.tileTeal,
                                 iconTint: Color(red: 0.55, green: 0.95, blue: 0.85)) {
                            app.path.append(.editor)
                        }
                        HomeTile(title: "Camera", subtitle: "Shoot with live cinematic looks",
                                 icon: "camera.fill", gradient: LumaTheme.tileAmber,
                                 iconTint: .white) {
                            app.path.append(.camera)
                        }
                        HomeTile(title: "Import LUT", subtitle: "Import .cube LUTs and apply",
                                 icon: "square.and.arrow.down", gradient: LumaTheme.tileIndigo,
                                 iconTint: Color(red: 0.72, green: 0.74, blue: 1.0)) {
                            app.path.append(.lutManager)
                        }
                    }

                    SectionHeader(title: "Recent Projects", actionTitle: "See All") {
                        app.path.append(.projectLibrary)
                    }
                    .padding(.top, 6)

                    RecentProjectsRow(store: app.store)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct RecentProjectsRow: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: PersistenceStore

    /// Reference-style sample projects shown until real ones exist — the
    /// rich photography is what makes the reference Home feel finished.
    private static let samples: [(title: String, duration: String, photo: HeroPhoto)] = [
        ("Travel Vlog", "00:18", .golden),
        ("Dreamscape", "00:34", .coast),
        ("City Lights", "00:26", .night),
    ]

    var body: some View {
        if store.projects.isEmpty && store.gradeSessions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Self.samples, id: \.title) { sample in
                        Button {
                            app.editor.startNewProject()
                            app.path.append(.editor)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HeroImage(photo: sample.photo, radius: 14)
                                    .frame(width: 164, height: 118)
                                    .overlay(alignment: .topTrailing) {
                                        Text("SAMPLE")
                                            .font(.system(size: 8, weight: .heavy))
                                            .tracking(1.2)
                                            .foregroundStyle(.white.opacity(0.85))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.black.opacity(0.45), in: Capsule())
                                            .padding(6)
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                                Text(sample.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(sample.duration)
                                    .font(.system(size: 14))
                                    .monospacedDigit()
                                    .foregroundStyle(LumaTheme.textMuted)
                            }
                            .frame(width: 164)
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(store.gradeSessions.prefix(3)) { session in
                        GradeSessionCard(session: session)
                    }
                    ForEach(Array(store.projects.prefix(5).enumerated()), id: \.element.id) { index, project in
                        Button {
                            app.editor.load(project: project)
                            app.path.append(.editor)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ProjectThumb(project: project, store: store,
                                             fallback: MockScene.allCases[index % MockScene.allCases.count])
                                    .frame(width: 164, height: 118)
                                Text(project.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(project.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 14))
                                    .foregroundStyle(LumaTheme.textMuted)
                            }
                            .frame(width: 164)
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
            }
        }
    }
}

/// A saved Apply-a-Look session in Recents: real media thumb + GRADE badge;
/// tap restores the exact grade (queue #13).
private struct GradeSessionCard: View {
    @EnvironmentObject private var app: AppModel
    let session: GradeSession
    @State private var thumb: CGImage?

    var body: some View {
        Button {
            app.restoreGradeSession(session)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let thumb {
                        Color.clear.overlay {
                            Image(decorative: thumb, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                    } else {
                        LumaTheme.surfaceStrong
                    }
                }
                .frame(width: 164, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    TechReadout("GRADE", size: 8, color: .white.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LumaTheme.accent.opacity(0.85), in: Capsule())
                        .padding(6)
                }
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                Text(session.baseLookName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(session.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 14))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .frame(width: 164)
        }
        .buttonStyle(.lumaPress)
        .task {
            let url = app.store.sessionMediaURL(session)
            if session.isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 340, height: 340)
                thumb = try? await generator.image(
                    at: CMTime(seconds: 0.05, preferredTimescale: 600)).image
            } else if let ci = CIImage(contentsOf: url) {
                let scale = min(1, 340 / max(ci.extent.width, ci.extent.height))
                let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                thumb = LookPipeline.shared.renderCGImage(from: scaled)
            }
        }
    }
}

private struct HomeTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: LinearGradient
    var iconTint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(height: 44)
                    // Reference-style soft light pooled around the icon.
                    .background(
                        RadialGradient(colors: [iconTint.opacity(0.35), .clear],
                                       center: .center, startRadius: 2, endRadius: 64)
                            .frame(width: 130, height: 130)
                    )
                Spacer(minLength: 2)
                Text(title.uppercased())
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(gradient, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
        }
        .buttonStyle(.lumaPress)
    }
}
