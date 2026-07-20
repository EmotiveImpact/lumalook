import SwiftUI

/// T2.4 — 2-up/4-up LUT compare: your frame, your grade, different LUTs side
/// by side. Tap a cell to commit that LUT and return to the grade room.
struct LUTCompareView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var renderer = CompareRenderer()

    /// Original + favourites first, then the rest; grid stays digestible.
    private var candidates: [(file: LUTFile, url: URL)?] {
        let luts = app.lutRepository.luts
            .sorted { ($0.isFavourite ? 0 : 1, $0.displayName) < ($1.isFavourite ? 0 : 1, $1.displayName) }
            .prefix(11)
            .map { (file: $0, url: app.lutRepository.fileURL(for: $0)) }
        return [nil] + luts.map { Optional($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare LUTs")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(LumaTheme.accentBright)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            TechReadout("SAME GRADE • DIFFERENT LUT — TAP TO APPLY", size: 9,
                        color: LumaTheme.textMuted)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                        let key = candidate.map { "lut-\($0.file.id)" } ?? "original"
                        let isCurrent = candidate?.file.id == app.selectedLUT?.id
                            || (candidate == nil && app.selectedLUT == nil)
                        Button {
                            app.selectedLUT = candidate?.file
                            LumaHaptics.shared.tap()
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let cg = renderer.images[key] {
                                        Image(decorative: cg, scale: 1)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } else {
                                        Rectangle().fill(LumaTheme.surface)
                                            .overlay(ProgressView().tint(LumaTheme.textMuted))
                                    }
                                }
                                .frame(height: 148)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(isCurrent ? LumaTheme.accentBright : .white.opacity(0.08),
                                            lineWidth: isCurrent ? 2 : 1))
                                Text(candidate?.file.displayName ?? "Original")
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? .white : LumaTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(LumaTheme.background)
        .preferredColorScheme(.dark)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "")-\(app.lutRepository.luts.count)") {
            // No media yet → compare on the hero frame, same as the strip thumbs.
            renderer.render(frame: app.previewFrame ?? HeroPhoto.golden.ciImage,
                            baseSettings: app.settings,
                            candidates: candidates)
        }
    }
}
