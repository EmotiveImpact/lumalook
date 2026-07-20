import SwiftUI

@main
struct LumaLookApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var storeService = StoreService()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    // A cover presented during the first render pass can get silently dropped,
    // which also flipped the binding back and burned hasSeenOnboarding with
    // zero interaction. Present after a beat instead, and only mark seen once
    // the cover has actually been on screen.
    @State private var onboardingDidAppear = false

    private var needsOnboarding: Bool {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if env["LUMA_SEED_ONBOARDING"] == "1" { return true }
        #endif
        return !hasSeenOnboarding && env["LUMA_ROUTE"] == nil
    }

    var body: some Scene {
        WindowGroup {
            LumaRootView()
                .environmentObject(app)
                .environmentObject(storeService)
                .preferredColorScheme(.dark)
                .task {
                    guard needsOnboarding else { return }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    showOnboarding = true
                }
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environmentObject(storeService)
                        .onAppear { onboardingDidAppear = true }
                }
                .onChange(of: showOnboarding) { _, showing in
                    if !showing && onboardingDidAppear { hasSeenOnboarding = true }
                }
                // Open-in-place (#117): .cube files and ZIP packs arrive here
                // from Files, Mail, Safari and "Open in LumaLook".
                .onOpenURL { url in
                    app.handleIncomingFile(url: url)
                }
        }
    }
}
