import SwiftUI

@main
struct LumaLookApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            LumaRootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}
