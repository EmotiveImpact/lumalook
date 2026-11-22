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
    // Launch animation (Screens/LaunchView.swift). App state, so it plays on a
    // cold launch only, never when the app comes back from the background.
    @State private var showLaunch = LaunchGate.shouldShow

    #if DEBUG
    init() {
        // The simulator preview writes stdout to a file and then terminates
        // the app, so block-buffered `[LUMA]` lines never reached the log.
        // Line buffering flushes each one as it is printed.
        setvbuf(stdout, nil, _IOLBF, 0)
    }
    #endif

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
                // Over the app, which loads underneath; it removes itself
                // after about two seconds or on a tap.
                .overlay {
                    if showLaunch {
                        LaunchView { showLaunch = false }
                            .transition(.opacity)
                    }
                }
                .preferredColorScheme(.dark)
                .task {
                    guard needsOnboarding else { return }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    // Let the launch animation hand off before onboarding covers it.
                    while showLaunch && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
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
