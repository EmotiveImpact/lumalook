import SwiftUI

/// F1 — emoji / sticker picker.
///
/// Picking bakes the glyph to a transparent PNG and hands it to the overlay
/// lane, so a sticker is just an image overlay: draggable, keyframable,
/// blendable, trimmable. No compositor changes at all.
struct StickerLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var category = 0
    @State private var busy = false

    private var categories: [(name: String, emojis: [String])] { StickerBaker.emojiCategories }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        LumaScreen(title: "Stickers") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { index, cat in
                        LPanelFilterTab(title: cat.name, isOn: category == index) {
                            category = index
                        }
                    }
                }
            }

            if let cat = categories[safe: category] {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(cat.emojis, id: \.self) { emoji in
                        Button { add(emoji) } label: {
                            Text(emoji)
                                .font(.luma(size: 34))
                                .frame(maxWidth: .infinity)
                                .frame(height: 62)
                                .background(LPanelStyle.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            }

            Text("Tap a sticker to drop it at the playhead. Drag it in the preview, then keyframe or blend it like any layer.")
                .font(.luma(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.top, 4)
        }
        .opacity(busy ? 0.6 : 1)
    }

    private func add(_ emoji: String) {
        guard !busy else { return }
        busy = true
        Task {
            await app.editor.addSticker(emoji: emoji)
            busy = false
            dismiss()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
