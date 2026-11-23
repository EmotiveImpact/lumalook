import SwiftUI

struct LumaRootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack(path: stackPath) {
            rootScreen
                // One fixed tab bar for the whole app: content scrolls under
                // it. The inset MUST sit on the stack's ROOT CONTENT, not on
                // the NavigationStack — a stack does not forward an outer
                // safe-area inset to what it hosts, so from out here every
                // tab's bottom control sat behind the bar (the Looks tab's
                // Create New Look was ~90% covered, Settings' last rows were
                // unreachable).
                //
                // UNCONDITIONAL, and that is the fix for the back-navigation
                // collapse. It used to be `if stackPath.wrappedValue.isEmpty`,
                // so a pop grew the root screen's bottom safe area by a whole
                // tab bar WHILE the pop transition was still running. The root
                // screen is Home, whose entire layout is solved from a
                // GeometryReader (HomeView.swift `HomeMetrics.viewport`), so
                // the page re-solved against a height that was mid-animation
                // and visibly squashed. Keeping the inset constant means the
                // root's geometry never changes on a push or a pop: the bar
                // simply travels with the root screen the way a UIKit tab bar
                // does under `hidesBottomBarWhenPushed`.
                //
                // Nothing is lost by leaving it mounted while a route is
                // pushed — the root is off-screen, so it cannot be seen and
                // cannot be hit-tested.
                .safeAreaInset(edge: .bottom, spacing: 0) { LumaTabBar() }
                .navigationDestination(for: LumaRoute.self) { route in
                    destination(for: route)
                }
        }
        // NOTE: there is deliberately no `.animation(_:value:)` on this stack.
        // The old `.animation(.spring, value: stackPath.wrappedValue.isEmpty)`
        // was not scoped to the tab bar — an implicit animation modifier
        // applies to EVERY animatable change in its subtree for the
        // transaction in which the observed value flips. Because the value
        // flipped on the same pop that ran the navigation transition, a spring
        // was laid over the whole stack: the detail view's removal, the root's
        // re-layout, Home's scroll content. That is the "weird animation".
        .onChange(of: app.path) { _, _ in claimTabRoutes() }
        .onAppear { claimTabRoutes() }
        .tint(LumaTheme.purple)
        // Import confirmation banner (open-in-place .cube / ZIP packs).
        .overlay(alignment: .top) {
            // The spring is scoped to the banner, NOT hung off the whole
            // NavigationStack. Same trap as the tab bar's animation above: an
            // implicit `.animation(_:value:)` at stack level springs every
            // animatable change in the app for that transaction, so a toast
            // arriving mid-navigation would have dragged the transition with
            // it. Here it can only ever move the capsule.
            ZStack(alignment: .top) {
                if let toast = app.importToast {
                    Text(toast)
                        .font(.luma(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(LumaTheme.edge, lineWidth: 1))
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 2_600_000_000)
                            app.importToast = nil
                        }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: app.importToast != nil)
        }
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

    /// Index of the first tab-owned route in `app.path`, if any.
    private static func claimCut(_ path: [LumaRoute]) -> Int? {
        path.firstIndex { tabOwnedRoutes[$0] != nil }
    }

    /// The path the NavigationStack actually renders: truncated at the first
    /// tab-owned route so that route never animates in before `claimTabRoutes`
    /// converts it into a tab switch (no push-then-pop flicker).
    ///
    /// A truncating getter makes this a LOSSY binding, and the setter has to
    /// account for that. SwiftUI writes the stack's own idea of the path back
    /// through the binding during an update; the value it writes is whatever
    /// the getter last handed it — the truncated prefix. Assigning that
    /// straight to `app.path` deleted the tab-owned suffix before
    /// `claimTabRoutes` ever observed it, so the tab switch silently did not
    /// happen and the user was left sitting on the screen they tapped from.
    /// That race is exactly why the glitch was intermittent. Re-attaching the
    /// unconsumed suffix keeps the write non-destructive.
    private var stackPath: Binding<[LumaRoute]> {
        Binding {
            let path = app.path
            guard let cut = Self.claimCut(path) else { return path }
            return Array(path.prefix(cut))
        } set: { newValue in
            guard let cut = Self.claimCut(app.path) else {
                app.path = newValue
                return
            }
            app.path = newValue + app.path[cut...]
        }
    }

    /// Converts a pushed tab-owned route into a tab switch.
    ///
    /// Only the TAB may be animated here. The earlier version wrapped the path
    /// mutation in `withAnimation` too, which meant one explicit transaction
    /// simultaneously popped the NavigationStack, flipped the tab bar's
    /// safe-area inset and cross-faded the root screen — three animations
    /// fighting each other and a live pop transition. The reproducer is real:
    /// from the pushed editor, "Open Project Library" (EditorScreen.swift:532)
    /// appends `.projectLibrary` onto `[.editor]`, so this runs while the
    /// stack is already unwinding. The path change is left un-animated because
    /// this is not a pop the user asked for — it is a redirect, and the
    /// 160 ms cross-fade in `rootScreen` is the transition that should read.
    ///
    /// No `withAnimation` at all now: `AppModel` is an `ObservableObject`, so
    /// two mutations in one run loop coalesce into a single update and a
    /// transaction opened around the second one can still colour the first.
    /// `rootScreen` already owns the tab cross-fade via a value-scoped
    /// `.animation(_:value: app.tab)`, which is the correctly scoped version
    /// of what the explicit transaction was trying to do.
    private func claimTabRoutes() {
        guard let cut = Self.claimCut(app.path),
              let tab = Self.tabOwnedRoutes[app.path[cut]] else { return }
        app.path.removeAll()
        app.tab = tab
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
        case .appearance: AppearanceSettingsView()
        }
    }
}
