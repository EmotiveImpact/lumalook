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
        .tint(LumaTheme.purple)
    }

    @ViewBuilder
    private var rootScreen: some View {
        switch app.tab {
        case .home: HomeView()
        case .store: FilterStoreView(isRoot: true)
        case .projects: ProjectLibraryView(isRoot: true)
        case .looks: SavedLooksView(isRoot: true)
        case .profile: SettingsSubscriptionView(isRoot: true)
        }
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
