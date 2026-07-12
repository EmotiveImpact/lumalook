import SwiftUI

@main
struct LumaLookApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var storeService = StoreService()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    // Computed at init, not in onAppear: a fullScreenCover presented during
    // the first render pass can get silently dropped.
    @State private var showOnboarding: Bool = {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if env["LUMA_SEED_ONBOARDING"] == "1" { return true }
        #endif
        return !UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
            && env["LUMA_ROUTE"] == nil
    }()

    var body: some Scene {
        WindowGroup {
            LumaRootView()
                .environmentObject(app)
                .environmentObject(storeService)
                .preferredColorScheme(.dark)
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environmentObject(storeService)
                }
                .onChange(of: showOnboarding) { _, showing in
                    if !showing { hasSeenOnboarding = true }
                }
                // Open-in-place (#117): .cube files and ZIP packs arrive here
                // from Files, Mail, Safari and "Open in LumaLook".
                .onOpenURL { url in
                    app.handleIncomingFile(url: url)
                }
        }
    }
}
