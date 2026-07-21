import SwiftUI

/// F8 — spot tools on a clip: blur / mosaic / solid-fill a shaped region.
///
/// The classic use is hiding a face, a number plate or a logo; inverted, it
/// isolates a subject and treats everything around it.
struct MaskPanel: View {
    @ObservedObject var editor: EditorState
    let clipID: UUID
    var onClose: () -> Void

    private var clip: EditorState.Clip? { editor.clips.first(where: { $0.id == clipID }) }
    private var isOn: Bool { clip?.maskShape != nil }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "circle.dashed.inset.filled")
                    .font(.system(size: 15, weight: .semibold))
                Text("Spot Tool")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done", action: onClose)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
            }
            .foregroundStyle(.white)

            // Shape — tapping the active one clears the mask.
            HStack(spacing: 8) {
                ForEach(ClipMaskShape.allCases, id: \.self) { shape in
                    let on = clip?.maskShape == shape.rawValue
                    Button {
                        editor.setClipMask(id: clipID, shape: on ? nil : shape)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(shape.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(on ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(on ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
                Spacer()
                if isOn {
                    Button {
                        editor.setClipMask(id: clipID, shape: nil)
                        LumaHaptics.shared.tap()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                    .buttonStyle(.lumaPress)
                }
            }

            if isOn, let clip {
                HStack(spacing: 8) {
                    ForEach(ClipMaskEffect.allCases, id: \.self) { fx in
                        let on = clip.maskEffect == fx.rawValue
                        Button {
                            editor.setClipMask(id: clipID,
                                               shape: ClipMaskShape(rawValue: clip.maskShape ?? ""),
                                               effect: fx)
                            LumaHaptics.shared.tap()
                        } label: {
                            Label(fx.label, systemImage: fx.icon)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(on ? .white : LumaTheme.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(on ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                        }
                        .buttonStyle(.lumaPress)
                    }
                    Spacer()
                    Toggle("Invert", isOn: Binding(
                        get: { clip.maskInverted },
                        set: { editor.setClipMask(id: clipID,
                                                  shape: ClipMaskShape(rawValue: clip.maskShape ?? ""),
                                                  inverted: $0) }))
                        .labelsHidden()
                        .tint(LumaTheme.accent)
                    Text("Invert")
                        .font(.system(size: 12))
                        .foregroundStyle(LumaTheme.textSecondary)
                }

                InlineSlider(title: clip.maskEffect == "fill" ? "Opacity" : "Strength",
                             value: Binding(get: { clip.maskAmount },
                                            set: { editor.setClipMask(id: clipID,
                                                                      shape: ClipMaskShape(rawValue: clip.maskShape ?? ""),
                                                                      amount: $0) }),
                             range: 0...1) { String(format: "%.0f%%", $0 * 100) }

                InlineSlider(title: "Size",
                             value: Binding(get: { clip.maskWidth },
                                            set: { editor.setClipMask(id: clipID,
                                                                      shape: ClipMaskShape(rawValue: clip.maskShape ?? ""),
                                                                      size: CGSize(width: $0, height: $0)) }),
                             range: 0.05...1.0) { String(format: "%.0f%%", $0 * 100) }

                InlineSlider(title: "Feather",
                             value: Binding(get: { clip.maskFeather },
                                            set: { editor.setClipMask(id: clipID,
                                                                      shape: ClipMaskShape(rawValue: clip.maskShape ?? ""),
                                                                      feather: $0) }),
                             range: 0...0.3) { String(format: "%.0f%%", $0 * 100) }

                PositionPad(center: CGPoint(x: clip.maskCenterX, y: clip.maskCenterY)) { pt in
                    editor.setClipMask(id: clipID,
                                       shape: ClipMaskShape(rawValue: clip.maskShape ?? ""),
                                       center: pt)
                }
            } else {
                Text("Pick a shape to blur, pixelate or block out part of this clip.")
                    .font(.system(size: 12))
                    .foregroundStyle(LumaTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(LumaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Drag-anywhere pad that reports a unit centre (y down, UI convention).
private struct PositionPad: View {
    let center: CGPoint
    var onMove: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let p = CGPoint(x: center.x * geo.size.width, y: center.y * geo.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LumaTheme.card)
                Circle()
                    .fill(LumaTheme.accentBright)
                    .frame(width: 18, height: 18)
                    .position(p)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    onMove(CGPoint(x: min(max(g.location.x / geo.size.width, 0), 1),
                                   y: min(max(g.location.y / geo.size.height, 0), 1)))
                }
            )
        }
        .frame(height: 90)
    }
}
