import SwiftUI

// =============================================================================
// LDGradeDemoView — a WORKING proof of the Lens-Distortions direction, not a
// mock. Real library, real graded thumbnails through LookThumbs, real
// selection through AppModel.select(look:).
//
// The five rules it demonstrates:
//   1. The image IS the interface — media on top, every control in a drawer
//      below it, nothing ever drawn over the frame.
//   2. Monochrome chrome — no accent anywhere on this screen. Every scrap of
//      colour comes from the user's footage and the looks themselves.
//   3. Stroke means selection and nothing else — one thin white ring.
//   4. The tile IS the preview — each one is the actual grade, not an icon.
//   5. A calm instruction bar — the live look name and its strength centred
//      (a plain sentence when nothing is applied), dismiss and confirm at the
//      two edges. No shouting CTA inside a tool.
//
// TYPE: mono is reserved for numbers. Names, categories and captions are the
// system font in sentence case, at a contrast you can actually read.
//
// Reachable headlessly with LUMA_ROUTE=ldDemo.
// =============================================================================

struct LDGradeDemoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()

    @State private var category: LookLibraryStore.Category = .all
    /// Drives the centred category label and its faded neighbours.
    private var categories: [LookLibraryStore.Category] { [.all, .favourites, .saved, .purchased, .imported] }

    private var looks: [LibraryLook] { app.library.looks(category: category) }

    private var categoryIndex: Int { categories.firstIndex(of: category) ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                media
                drawer
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.library.all.count) {
            thumbs.render(source: app.previewFrame, library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
    }

    // MARK: Media — clean, uncovered, generous radius

    private var media: some View {
        GeometryReader { geo in
            Group {
                if let frame = app.previewFrame ?? HeroPhoto.golden.ciImage,
                   let cg = LookPipeline.shared.context.createCGImage(
                    LookPipeline.shared.apply(state: app.lookState, to: frame),
                    from: frame.extent) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.08)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: Drawer — everything that is not the image

    private var drawer: some View {
        VStack(spacing: 0) {
            categoryBar
                .padding(.top, 18)
                .padding(.bottom, 14)
            tiles
                .padding(.bottom, 18)
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// The current category centred, its neighbours faded either side — the
    /// gesture teaches itself because you can see what you would swipe to.
    private var categoryBar: some View {
        HStack(spacing: 0) {
            label(at: categoryIndex - 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(categories[categoryIndex].title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            label(at: categoryIndex + 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let step = value.translation.width < 0 ? 1 : -1
                    let next = categoryIndex + step
                    guard categories.indices.contains(next) else { return }
                    withAnimation(.snappy(duration: 0.22)) { category = categories[next] }
                    LumaHaptics.shared.tap()
                }
        )
    }

    @ViewBuilder
    private func label(at index: Int) -> some View {
        if categories.indices.contains(index) {
            Text(categories[index].title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// Every tile is the grade itself. Selection is the only stroke on screen.
    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(looks) { look in
                    Button {
                        app.select(look: look)
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 7) {
                            Group {
                                if let cg = thumbs.images[LookThumbs.key(look)] {
                                    Image(decorative: cg, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Color(white: 0.12)
                                }
                            }
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if app.isCurrent(look) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 2)
                                }
                            }
                            // A look's name is a name, not a readout: real
                            // weight, real contrast, sentence case.
                            Text(look.nameSplit.title)
                                .font(.system(size: 12, weight: app.isCurrent(look) ? .semibold : .medium))
                                .foregroundStyle(app.isCurrent(look) ? .white : .white.opacity(0.62))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(width: 76)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.horizontal, 20)
        }
        .lumaEdgeFade(leading: 20, trailing: 20)
    }

    /// The centre of this bar is the one place the applied grade is named, so
    /// it states the live value rather than a slogan: the look, then its
    /// strength in mono. With the grade off it falls back to a plain sentence.
    private var instructionBar: some View {
        let name = app.selectedLUT?.displayName ?? app.selectedLook.name
        let strength = Int(app.settings.intensity.rounded())
        return HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            Spacer()
            if strength == 0 {
                Text("Showing the original")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            } else {
                HStack(spacing: 7) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    Text("\(strength)%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
