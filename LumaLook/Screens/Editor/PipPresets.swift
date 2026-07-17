import CoreGraphics

/// Canned picture-in-picture layouts: placement + mask/border effects that
/// already persist, applied in one undo step by `EditorState.applyPipPreset`.
struct PipPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let sizeFraction: Double
    let center: CGPoint
    let mask: OverlayMaskSettings?
    let border: OverlayBorderSettings?

    static let all: [PipPreset] = [
        .init(id: "cornerCam", name: "Corner Cam", icon: "person.crop.square",
              sizeFraction: 0.30, center: CGPoint(x: 0.80, y: 0.16),
              mask: OverlayMaskSettings(shape: "roundedRect", feather: 0, cornerRadius: 0.18, invert: false),
              border: OverlayBorderSettings(widthFraction: 0.015, colorHex: "#FFFFFF", cornerRadiusFraction: 0.18)),
        .init(id: "circleCam", name: "Circle", icon: "person.crop.circle",
              sizeFraction: 0.28, center: CGPoint(x: 0.16, y: 0.80),
              mask: OverlayMaskSettings(shape: "ellipse", feather: 0.03, cornerRadius: 0, invert: false),
              border: OverlayBorderSettings(widthFraction: 0.02, colorHex: "#FFFFFF", cornerRadiusFraction: 0.5)),
        .init(id: "sideLeft", name: "Split Left", icon: "rectangle.lefthalf.filled",
              sizeFraction: 0.50, center: CGPoint(x: 0.25, y: 0.5),
              mask: OverlayMaskSettings(shape: "rect", feather: 0, cornerRadius: 0, invert: false),
              border: nil),
        .init(id: "sideRight", name: "Split Right", icon: "rectangle.righthalf.filled",
              sizeFraction: 0.50, center: CGPoint(x: 0.75, y: 0.5),
              mask: OverlayMaskSettings(shape: "rect", feather: 0, cornerRadius: 0, invert: false),
              border: nil),
        .init(id: "card", name: "Card", icon: "rectangle.on.rectangle",
              sizeFraction: 0.55, center: CGPoint(x: 0.5, y: 0.42),
              mask: OverlayMaskSettings(shape: "roundedRect", feather: 0.02, cornerRadius: 0.10, invert: false),
              border: OverlayBorderSettings(widthFraction: 0.01, colorHex: "#FFFFFF", cornerRadiusFraction: 0.10)),
        .init(id: "fullBleed", name: "Full B-Roll", icon: "rectangle.inset.filled",
              sizeFraction: 1.0, center: CGPoint(x: 0.5, y: 0.5),
              mask: nil, border: nil),
    ]
}
