import SwiftUI
import AVKit
import Pow

struct ExportCompleteView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var appeared = false
    @State private var celebrate = 0

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.lumaPress)
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)

                    ZStack {
                        Circle()
                            .fill(LumaTheme.teal.opacity(0.13))
                            .frame(width: 128, height: 128)
                        Circle()
                            .strokeBorder(LumaTheme.teal.opacity(0.35), lineWidth: 1)
                            .frame(width: 128, height: 128)
                        Image(systemName: "checkmark")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(LumaTheme.teal)
                    }
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                    .changeEffect(.spray(origin: .center) {
                        Image(systemName: "sparkle")
                            .foregroundStyle(LumaTheme.teal)
                    }, value: celebrate)
                    .padding(.top, 18)

                    Text("Export Complete!")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 22)
                    Text("Saved to your photos")
                        .font(.system(size: 17))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .padding(.top, 6)

                    // Centered media card — video or graded photo.
                    Group {
                        if let image = app.lastExportImage {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if let player {
                            VideoPlayer(player: player)
                        } else {
                            SceneArt(scene: .desert, grade: app.selectedLook.gradeTint, gradeOpacity: 0.2)
                                .overlay(
                                    Circle()
                                        .fill(.black.opacity(0.45))
                                        .frame(width: 64, height: 64)
                                        .overlay(Image(systemName: "play.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(.white))
                                )
                        }
                    }
                    .frame(width: 250, height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .padding(.top, 26)

                    Group {
                        if let url = app.lastExportURL {
                            ShareLink(item: url) {
                                shareLabel
                            }
                        } else {
                            Button { } label: { shareLabel }
                        }
                    }
                    .buttonStyle(.lumaPress)
                    .conditionalEffect(.repeat(.shine, every: .seconds(3)), condition: true)
                    .padding(.top, 30)

                    HStack(spacing: 22) {
                        BrandShareIcon(kind: .instagram)
                        BrandShareIcon(kind: .tiktok)
                        BrandShareIcon(kind: .youtube)
                        BrandShareIcon(kind: .more)
                    }
                    .padding(.top, 22)

                    GhostCTA(title: "New Project") {
                        app.resetToHome()
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .sensoryFeedback(.success, trigger: celebrate)
        .onAppear {
            if app.lastExportImage == nil, let url = app.lastExportURL {
                player = AVPlayer(url: url)
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.1)) {
                appeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                celebrate += 1
            }
        }
        .onDisappear { player?.pause() }
    }

    private var shareLabel: some View {
        Text(app.lastExportImage != nil ? "Share Photo" : "Share Video")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                LinearGradient(colors: [LumaTheme.accent, LumaTheme.accent.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: LumaTheme.accent.opacity(0.35), radius: 16, y: 6)
    }
}

// MARK: - Brand share icons

struct BrandShareIcon: View {
    enum Kind: String {
        case instagram = "Instagram", tiktok = "TikTok", youtube = "YouTube", more = "More"
    }
    let kind: Kind

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .frame(width: 68, height: 68)
                .overlay(glyph)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
            Text(kind.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .instagram:
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    LinearGradient(colors: [Color(red: 0.99, green: 0.75, blue: 0.29),
                                            Color(red: 0.91, green: 0.26, blue: 0.43),
                                            Color(red: 0.51, green: 0.23, blue: 0.71)],
                                   startPoint: .bottomLeading, endPoint: .topTrailing),
                    lineWidth: 2.5
                )
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(
                    LinearGradient(colors: [Color(red: 0.91, green: 0.26, blue: 0.43),
                                            Color(red: 0.51, green: 0.23, blue: 0.71)],
                                   startPoint: .bottom, endPoint: .top),
                    lineWidth: 2.5).frame(width: 13, height: 13))
        case .tiktok:
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.0, green: 0.95, blue: 0.92), radius: 0, x: -1.5, y: 0)
                .shadow(color: Color(red: 1.0, green: 0.0, blue: 0.31), radius: 0, x: 1.5, y: 0)
        case .youtube:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                .frame(width: 34, height: 24)
                .overlay(Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white))
        case .more:
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
