import SwiftUI

struct LumaRootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack(path: $app.path) {
            rootScreen
                .navigationDestination(for: LumaRoute.self) { route in
                    destination(for: route)
                }
        }
        // One fixed tab bar for the whole app: content scrolls under its glass,
        // and it slides away with a spring when a flow is pushed.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if app.path.isEmpty {
                LumaTabBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: app.path.isEmpty)
        .tint(LumaTheme.purple)
        // Import confirmation banner (open-in-place .cube / ZIP packs).
        .overlay(alignment: .top) {
            if let toast = app.importToast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        withAnimation(.easeOut(duration: 0.25)) { app.importToast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.importToast != nil)
    }

    @ViewBuilder
    private var rootScreen: some View {
        // Quick cross-fade between tabs: instant swaps read as a web page,
        // a 160 ms fade reads as an app.
        ZStack {
            switch app.tab {
            case .home: HomeView()
            case .store: FilterStoreView(isRoot: true)
            case .projects: ProjectLibraryView(isRoot: true)
            case .looks: SavedLooksView(isRoot: true)
            case .profile: SettingsSubscriptionView(isRoot: true)
            }
        }
        .id(app.tab)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.16), value: app.tab)
    }

    @ViewBuilder
    private func destination(for route: LumaRoute) -> some View {
        switch route {
        case .selectClip: SelectClipView()
        case .applyLook: ApplyLookView()
        case .beforeAfter: BeforeAfterView()
        case .lutManager: LUTManagerView()
        case .camera: CameraLiveLookView()
        case .editor: EditorTimelineView()
        case .exportComplete: ExportCompleteView()
        case .filterStore: FilterStoreView()
        case .filterPack: FilterPackDetailView()
        case .savedLooks: SavedLooksView()
        case .customLook: CustomLookBuilderView()
        case .projectLibrary: ProjectLibraryView()
        case .cropFormat: CropFormatView()
        case .audio: AudioView()
        case .settings: SettingsSubscriptionView()
        }
    }
}
