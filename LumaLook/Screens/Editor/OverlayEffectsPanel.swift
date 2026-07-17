import SwiftUI

/// Non-placement effect controls for a media overlay: blend mode (F3), plus
/// chroma / mask / adjust / border sub-panels (F4–F7). Lives in its own file
/// so effect features land without re-touching EditorScreen. Text overlays
/// don't show it (they can't be keyed/masked/graded).
struct OverlayEffectsPanel: View {
    @ObservedObject var editor: EditorState
    let overlayID: UUID

    private var overlay: EditorState.OverlayItem? {
        editor.overlays.first { $0.id == overlayID }
    }
    private var fx: OverlayEffects { overlay?.effects ?? OverlayEffects() }

    @State private var section: Section = .blend
    enum Section: String, CaseIterable { case blend, chroma, mask, adjust, border
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .blend: return "square.stack.3d.forward.dottedline"
            case .chroma: return "wand.and.stars"
            case .mask: return "circle.dashed"
            case .adjust: return "slider.horizontal.3"
            case .border: return "square.dashed"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section chips.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Section.allCases, id: \.self) { s in
                        Button {
                            section = s
                            LumaHaptics.shared.tap()
                        } label: {
                            Label(s.label, systemImage: s.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(section == s ? .black : .white)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(section == s ? AnyShapeStyle(LumaTheme.accentBright)
                                                         : AnyShapeStyle(LumaTheme.surface),
                                            in: Capsule())
                                .overlay(alignment: .topTrailing) {
                                    if isActive(s) {
                                        Circle().fill(LumaTheme.teal).frame(width: 7, height: 7)
                                            .offset(x: 2, y: -2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            switch section {
            case .blend: blendControls
            case .chroma: chromaControls
            case .mask: maskControls
            case .adjust: adjustControls
            case .border: borderControls
            }
        }
    }

    private func isActive(_ s: Section) -> Bool {
        switch s {
        case .blend: return fx.blendMode != .normal
        case .chroma: return fx.chroma != nil
        case .mask: return fx.mask != nil
        case .adjust: return !(fx.adjust?.isIdentity ?? true)
        case .border: return fx.border != nil
        }
    }

    // MARK: - Blend (F3)

    private var blendControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OverlayBlendMode.allCases, id: \.self) { mode in
                    Button {
                        editor.setOverlayBlendMode(id: overlayID, mode)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(mode.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(fx.blendMode == mode ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(fx.blendMode == mode ? LumaTheme.accent : LumaTheme.surface,
                                        in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
        }
    }

    // MARK: - Chroma / Mask / Adjust / Border (F4–F7 fill these in)

    @ViewBuilder private var chromaControls: some View {
        let chroma = fx.chroma
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Green screen", isOn: Binding(
                get: { chroma != nil },
                set: { on in
                    editor.setOverlayChroma(id: overlayID, on ? ChromaKeySettings() : nil)
                    LumaHaptics.shared.tap()
                }))
                .font(.system(size: 14, weight: .semibold))
                .tint(LumaTheme.accentBright)

            if let chroma {
                HStack(spacing: 10) {
                    Text("Key").font(.footnote).foregroundStyle(LumaTheme.textSecondary)
                    ForEach(["#00FF00", "#0000FF", "#00FFFF", "#FF00FF"], id: \.self) { hex in
                        Button {
                            var c = chroma; c.colorHex = hex
                            editor.setOverlayChroma(id: overlayID, c)
                            LumaHaptics.shared.tap()
                        } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(chroma.colorHex.uppercased() == hex
                                    ? LumaTheme.accentBright : .white.opacity(0.2),
                                    lineWidth: chroma.colorHex.uppercased() == hex ? 2.5 : 1))
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                InlineSlider(title: "Tolerance", value: Binding(
                    get: { chroma.tolerance * 100 },
                    set: { var c = chroma; c.tolerance = $0 / 100
                           editor.setOverlayChroma(id: overlayID, c, snapshot: false) }
                ), range: 5...80) { "\(Int($0))" }
                InlineSlider(title: "Softness", value: Binding(
                    get: { chroma.softness * 100 },
                    set: { var c = chroma; c.softness = $0 / 100
                           editor.setOverlayChroma(id: overlayID, c, snapshot: false) }
                ), range: 0...40) { "\(Int($0))" }
            }
        }
    }
    @ViewBuilder private var maskControls: some View {
        let mask = fx.mask
        let shapes: [(String, String, String)] = [
            ("none", "None", "circle.slash"), ("rect", "Rect", "square"),
            ("roundedRect", "Rounded", "square.dashed"), ("ellipse", "Circle", "circle"),
            ("linear", "Fade", "square.righthalf.filled"),
        ]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(shapes, id: \.0) { key, label, icon in
                    let on = (mask?.shape ?? "none") == key || (mask == nil && key == "none")
                    Button {
                        editor.setOverlayMask(id: overlayID,
                                              key == "none" ? nil : OverlayMaskSettings(shape: key))
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon).font(.system(size: 16))
                            Text(label).font(.system(size: 10))
                        }
                        .foregroundStyle(on ? .black : .white)
                        .frame(width: 56, height: 48)
                        .background(on ? AnyShapeStyle(LumaTheme.accentBright)
                                       : AnyShapeStyle(LumaTheme.surface),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let mask {
                InlineSlider(title: "Feather", value: Binding(
                    get: { mask.feather * 100 },
                    set: { var m = mask; m.feather = $0 / 100
                           editor.setOverlayMask(id: overlayID, m, snapshot: false) }
                ), range: 0...40) { "\(Int($0))" }
                Toggle("Invert", isOn: Binding(
                    get: { mask.invert },
                    set: { var m = mask; m.invert = $0; editor.setOverlayMask(id: overlayID, m) }))
                    .font(.system(size: 14, weight: .semibold)).tint(LumaTheme.accentBright)
            }
        }
    }
    @ViewBuilder private var adjustControls: some View {
        Text("Adjust — coming soon").font(.footnote).foregroundStyle(LumaTheme.textMuted)
    }
    @ViewBuilder private var borderControls: some View {
        let border = fx.border
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Border", isOn: Binding(
                get: { border != nil },
                set: { on in
                    editor.setOverlayBorder(id: overlayID, on ? OverlayBorderSettings() : nil)
                    LumaHaptics.shared.tap()
                }))
                .font(.system(size: 14, weight: .semibold)).tint(LumaTheme.accentBright)
            if let border {
                HStack(spacing: 10) {
                    Text("Colour").font(.footnote).foregroundStyle(LumaTheme.textSecondary)
                    ForEach(["#FFFFFF", "#000000", "#FFD60A", "#FF375F", "#0A84FF"], id: \.self) { hex in
                        Button {
                            var b = border; b.colorHex = hex
                            editor.setOverlayBorder(id: overlayID, b)
                        } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 20, height: 20)
                                .overlay(Circle().stroke(border.colorHex.uppercased() == hex
                                    ? LumaTheme.accentBright : .white.opacity(0.25),
                                    lineWidth: border.colorHex.uppercased() == hex ? 2.5 : 1))
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                InlineSlider(title: "Width", value: Binding(
                    get: { border.widthFraction * 100 },
                    set: { var b = border; b.widthFraction = $0 / 100
                           editor.setOverlayBorder(id: overlayID, b, snapshot: false) }
                ), range: 1...12) { "\(Int($0))" }
                InlineSlider(title: "Corner", value: Binding(
                    get: { border.cornerRadiusFraction * 100 },
                    set: { var b = border; b.cornerRadiusFraction = $0 / 100
                           editor.setOverlayBorder(id: overlayID, b, snapshot: false) }
                ), range: 0...50) { "\(Int($0))" }
            }
        }
    }
}
