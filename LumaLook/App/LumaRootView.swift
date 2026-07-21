import SwiftUI

struct LumaRootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack(path: stackPath) {
            rootScreen
                // One fixed tab bar for the whole app: content scrolls under
                // its glass, and it slides away with a spring when a flow is
                // pushed. The inset MUST sit on the stack's ROOT CONTENT, not
                // on the NavigationStack — a stack does not forward an outer
                // safe-area inset to what it hosts, so from out here every
                // tab's bottom control sat behind the bar (the Looks tab's
                // Create New Look was ~90% covered, Settings' last rows were
                // unreachable).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if stackPath.wrappedValue.isEmpty {
                        LumaTabBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .navigationDestination(for: LumaRoute.self) { route in
                    destination(for: route)
                }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86),
                   value: stackPath.wrappedValue.isEmpty)
        .onChange(of: app.path) { _, _ in claimTabRoutes() }
        .onAppear { claimTabRoutes() }
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

    // MARK: Tab-owned destinations

    /// Projects and Settings live in the tab bar, so they must exist in exactly
    /// ONE presentation. Anything that pushes those routes (Home's gear, Home's
    /// "See All", the empty editor's "or open a project") is re-routed to the
    /// owning tab instead of being stacked with a back chevron and no tab bar.
    private static let tabOwnedRoutes: [LumaRoute: LumaTab] = [
        .projectLibrary: .projects,
        .settings: .profile
    ]

    /// The path the NavigationStack actually renders: truncated at the first
    /// tab-owned route so that route never animates in before `claimTabRoutes`
    /// converts it into a tab switch (no push-then-pop flicker).
    private var stackPath: Binding<[LumaRoute]> {
        Binding {
            let path = app.path
            guard let cut = path.firstIndex(where: { Self.tabOwnedRoutes[$0] != nil })
            else { return path }
            return Array(path.prefix(cut))
        } set: { newValue in
            app.path = newValue
        }
    }

    private func claimTabRoutes() {
        guard let hit = app.path.first(where: { Self.tabOwnedRoutes[$0] != nil }),
              let tab = Self.tabOwnedRoutes[hit] else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            app.path.removeAll()
            app.tab = tab
        }
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
        case .collections: CollectionsView()
        // The Design Lab has done its job: these designs ARE the app now, so
        // every entry points at the real screen. Keeping separate preview
        // copies would only let them drift out of sync with what ships.
        case .ldGrade: ApplyLookView()
        case .ldLibrary: SavedLooksView()
        case .ldCamera: CameraLiveLookView()
        case .ldEditor: EditorTimelineView()
        case .ldStore: FilterStoreView()
        case .ldExport: LDExportDemoView()
        }
    }
}
