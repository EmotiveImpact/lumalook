import SwiftUI

/// T2.4 — 2-up/4-up LUT compare: your frame, your grade, different LUTs side
/// by side. Tap a cell to commit that LUT and return to the grade room.
/// Each cell is drawn as tapping it leaves the picture (`CompareRenderer`).
struct LUTCompareView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var renderer = CompareRenderer()

    /// Original + the library's LUTs in the unified order — favourites first,
    /// then the rest of the library sort (installed → imported); grid stays
    /// digestible at 11.
    private var candidates: [(file: LUTFile, url: URL)?] {
        var seen = Set<UUID>()
        var files: [LUTFile] = []
        for look in app.library.looks(category: .favourites) + app.library.all {
            guard case .lut(let f) = look.source, seen.insert(f.id).inserted else { continue }
            files.append(f)
        }
        let luts = files.prefix(11)
            .map { (file: $0, url: app.lutRepository.fileURL(for: $0)) }
        return [nil] + luts.map { Optional($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare LUTs")
                    .font(.luma(size: 17, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.luma(.footnote, weight: .semibold)).foregroundStyle(LumaTheme.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Text("Same grade, different LUT. Tap one to apply it.")
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                        let key = candidate.map { "lut-\($0.file.id)" } ?? "original"
                        let isCurrent = candidate?.file.id == app.selectedLUT?.id
                            || (candidate == nil && app.selectedLUT == nil)
                        Button {
                            if let file = candidate?.file {
                                // Through the one selection contract, so the
                                // pick records as recently used.
                                app.select(look: LibraryLook(lut: file))
                            } else {
                                app.selectedLUT = nil
                            }
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
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                // The live candidate wears the picked ring.
                                .pickedRing(isCurrent, cornerRadius: 14)
                                // Each LUT's name in its own colour. The
                                // cell without a LUT is the built-in look
                                // tapping it goes back to, so it carries
                                // that look's name, in quiet white.
                                if let file = candidate?.file {
                                    LookNameText(file.displayName,
                                                 colour: LookSignature.colour(name: file.displayName),
                                                 size: 12, weight: isCurrent ? .semibold : .medium)
                                } else {
                                    Text(app.selectedLook.name)
                                        .font(.luma(size: 12, weight: isCurrent ? .semibold : .medium))
                                        .foregroundStyle(isCurrent ? .white : LumaTheme.textSecondary)
                                        .lineLimit(1)
                                }
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
                            live: .init(recipe: app.selectedLook.recipe,
                                        settings: app.settings,
                                        pickedSettings: app.settingsAfterPick,
                                        conversion: app.lookState.conversionSlot),
                            candidates: candidates)
        }
    }
}
