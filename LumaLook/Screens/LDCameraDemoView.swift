import SwiftUI

// =============================================================================
// LDCameraDemoView — PROMOTED.
//
// This design-lab preview was the proving ground for the camera's new design
// language. It has now been promoted into the shipping screen: the whole
// implementation lives in `CameraLiveLookView`, which the `.camera` route
// renders. There is nothing left here to preview — the shipping camera IS the
// design.
//
// This file survives only because the `.ldCamera` route is registered in files
// this change does not own (`App/LumaRootView.swift`, `Models/LumaModels.swift`,
// `Data/AppModel.swift`, `Screens/MoreScreens.swift`). Retiring the route means
// editing those four; until then this alias keeps the Design Lab entry and
// `LUMA_ROUTE=ldCamera` working, and — because it forwards to the real screen —
// keeps them honest: the lab and the app can no longer drift apart.
//
// To retire: drop the `.ldCamera` case from the four files above, then delete
// this file and re-run `xcodegen generate`.
// =============================================================================

struct LDCameraDemoView: View {
    var body: some View { CameraLiveLookView() }
}
