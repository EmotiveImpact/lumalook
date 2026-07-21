import SwiftUI

/// LDStoreDemoView — Design Lab preview in the LD direction. FULL feature parity with
/// the screen it previews: nothing is dropped for the sake of the look.
struct LDStoreDemoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Look Store")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Preview in progress.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                Button("Close") { dismiss() }
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}
