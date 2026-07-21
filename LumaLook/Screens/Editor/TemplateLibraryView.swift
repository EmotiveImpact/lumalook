import SwiftUI

/// F11 — trending templates.
///
/// A template is a whole edit in one tap: aspect, slot pacing, transitions,
/// motion and canvas. It shapes the clips already on the timeline rather than
/// importing anything, so what you get is your footage, cut to a format.
struct TemplateLibraryView: View {
    @ObservedObject var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    private var templates: [VideoTemplate] { TemplateLibrary.all }

    var body: some View {
        LumaScreen(title: "Templates") {
            if editor.clips.isEmpty {
                Text("Add a clip first — a template shapes the footage you already have.")
                    .font(.system(size: 13))
                    .foregroundStyle(LumaTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 10) {
                ForEach(templates) { t in
                    Button {
                        editor.applyTemplate(t)
                        LumaHaptics.shared.tap()
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(LumaTheme.surfaceStrong)
                                    .frame(width: 54, height: 54)
                                Image(systemName: t.icon)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(LumaTheme.accentBright)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.name)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(t.blurb)
                                    .font(.system(size: 12))
                                    .foregroundStyle(LumaTheme.textSecondary)
                                    .lineLimit(2)
                                TechReadout("\(t.aspect) · \(t.slots.count) SHOTS · \(String(format: "%.1f", t.totalDuration))S",
                                            size: 9, color: LumaTheme.textMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LumaTheme.textMuted)
                        }
                        .padding(12)
                        .background(LumaTheme.card, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.lumaPress)
                    .disabled(editor.clips.isEmpty)
                    .opacity(editor.clips.isEmpty ? 0.4 : 1)
                }
            }

            Text("Templates re-cut the clips you already have — slots cycle if you have more clips than shots. Undo restores your edit in one step.")
                .font(.system(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.top, 4)
        }
    }
}
