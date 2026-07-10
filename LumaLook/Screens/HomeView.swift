import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 26) {
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
                    .padding(.top, 4)

                    VStack(spacing: 10) {
                        LumaWordmark(size: 38)
                        Text("Cinematic looks for your world")
                            .font(.system(size: 16))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 8)

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

    var body: some View {
        if store.projects.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(LumaTheme.accentBright)
                Text("Your edits will appear here — start one from Edit a Video.")
                    .font(.system(size: 14))
                    .foregroundStyle(LumaTheme.textSecondary)
                Spacer()
            }
            .padding(16)
            .lumaCard()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
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
