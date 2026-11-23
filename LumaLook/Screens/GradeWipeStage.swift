import SwiftUI
import CoreImage

// =============================================================================
// THE GRADE ROOM STAGE, and the still helpers the photo editor shares.
//
// The grade room shows the picture full bleed, edge to edge and up under the
// status bar, with a straight vertical wipe: the original on the left of a
// thin white line, the graded picture on the right. The line carries a round
// glass handle, so the colour you see is the grade, never the interface; drag
// anywhere on the picture to move it. Hold still to peek at the original,
// double tap to see the whole frame instead of the full-bleed crop.
//
// Stills are drawn as two layers (one ungraded render, one live grade, same
// pixel size), so the wipe is pure SwiftUI and never touches the engine. A
// playing video has no ungraded twin to wipe against, so it fills the stage
// graded and keeps hold to peek.
// =============================================================================

// MARK: - Look codes

/// The short code a look wears on tiles and wipe labels: "KD2" from
/// "KD2 · Golden Hour", else the first word of the name ("Neon").
enum LookCode {
    static func short(_ name: String) -> String {
        let parts = name.components(separatedBy: " · ")
        if parts.count == 2, let code = parts.first,
           !code.isEmpty, code.count <= 6, !code.contains(" ") {
            return code
        }
        let title = parts.last ?? name
        let first = title.split(separator: " ").first.map(String.init) ?? title
        return first.isEmpty ? name : first
    }

    static func short(_ look: LibraryLook) -> String {
        if let code = look.nameSplit.code { return code }
        return short(look.nameSplit.title)
    }
}

// MARK: - Still sources

/// One ladder for the still compare surfaces: the original and the live grade
/// are rendered from the same downscaled image, so the two layers line up
/// pixel for pixel.
enum StillCompare {
    /// The bundled hero, decoded once (`HeroPhoto.ciImage` reads the file on
    /// every access).
    static let hero: CIImage? = HeroPhoto.golden.ciImage

    /// Longest edge the compare surfaces render at.
    static let previewMax: CGFloat = 1400

    /// `image` scaled so its longest edge is at most `previewMax`, moved so
    /// its extent starts at zero.
    static func downscaled(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return image }
        var out = image
        let longest = max(extent.width, extent.height)
        if longest > previewMax {
            let scale = previewMax / longest
            out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let moved = out.extent
        return out.transformed(by: CGAffineTransform(translationX: -moved.minX, y: -moved.minY))
    }

    /// The ungraded twin of `LiveGradedStill`: same size, same colour space.
    static func renderOriginal(_ image: CIImage) -> CGImage? {
        let small = downscaled(image)
        let extent = small.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return nil }
        return LookPipeline.shared.context.createCGImage(
            small, from: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// The live grade of a still. Re-renders whenever the grade changes, like
/// `GradedStillView`, but fills whatever frame it is given so a wipe can lay
/// it exactly over its original.
struct LiveGradedStill: View {
    @EnvironmentObject private var app: AppModel
    /// Already sized for preview with `StillCompare.downscaled`.
    let source: CIImage
    /// A spot mask being placed, drawn before the grade like the export.
    var mask: ClipMaskSpec? = nil
    /// Preview pixels per full-size pixel, so a blur reads the same as it
    /// will at full size.
    var maskScale: CGFloat = 1

    var body: some View {
        // Reading the grade here re-renders the still when it changes.
        let _ = app.settings
        let _ = app.selectedLook
        let _ = app.selectedLUT
        if let cg = render() {
            Image(decorative: cg, scale: 1)
                .resizable()
        } else {
            Color.black
        }
    }

    private func render() -> CGImage? {
        var input = source
        if let mask {
            let spec = PhotoEditMath.previewSpec(mask, scale: maskScale)
            input = MaskRenderer.apply(spec, to: input, rect: input.extent)
        }
        return LookPipeline.shared.gradedStill(input, state: app.lookState)
    }
}

// MARK: - Wipe shapes

/// The graded side of a straight wipe (the grade room and the photo
/// editor): everything right of a vertical line at `fraction` of the width.
struct SplitRevealShape: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let x = rect.minX + rect.width * min(max(fraction, 0), 1)
        return Path(CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height))
    }
}

/// The round glass handle that rides a wipe line: dark translucent glass with
/// a white left-right mark, so it reads on any frame without adding colour.
struct WipeKnob: View {
    var size: CGFloat = 38

    var body: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .background(Color(hex: 0x101114).opacity(0.58), in: Circle())
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .overlay {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
            }
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Hold or drag

/// One finger on a stage does two jobs: drag a few points to move a divider
/// (or a mask), or hold still to peek at the original until you let go. Two
/// quick taps call `onDoubleTap`. One drag gesture runs both, so they never
/// fight, and a cancelled touch still ends the peek.
struct HoldOrDragGesture: ViewModifier {
    var dragEnabled: Bool
    let onDrag: (CGPoint) -> Void
    let onHold: (Bool) -> Void
    var onDoubleTap: (() -> Void)?

    @GestureState private var pressed = false
    @State private var touching = false
    @State private var dragging = false
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    @State private var lastTap: Date?

    init(dragEnabled: Bool,
         onDrag: @escaping (CGPoint) -> Void,
         onHold: @escaping (Bool) -> Void,
         onDoubleTap: (() -> Void)?) {
        self.dragEnabled = dragEnabled
        self.onDrag = onDrag
        self.onHold = onHold
        self.onDoubleTap = onDoubleTap
    }

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
                    .onChanged { value in changed(value) }
                    .onEnded { _ in ended() }
            )
            .onChange(of: pressed) { _, isPressed in
                if !isPressed { ended() }
            }
    }

    private func changed(_ value: DragGesture.Value) {
        if !touching {
            touching = true
            dragging = false
            startHoldTimer()
        }
        let moved = hypot(value.translation.width, value.translation.height)
        if !dragging, !holding, dragEnabled, moved > 8 {
            dragging = true
            holdTask?.cancel()
            holdTask = nil
        }
        if dragging { onDrag(value.location) }
    }

    private func ended() {
        guard touching else { return }
        holdTask?.cancel()
        holdTask = nil
        if holding {
            holding = false
            onHold(false)
        } else if !dragging {
            let now = Date()
            if let last = lastTap, now.timeIntervalSince(last) < 0.3 {
                lastTap = nil
                onDoubleTap?()
            } else {
                lastTap = now
            }
        }
        touching = false
        dragging = false
    }

    private func startHoldTimer() {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled, touching, !dragging else { return }
            holding = true
            onHold(true)
        }
    }
}

extension View {
    /// See `HoldOrDragGesture`.
    func holdOrDrag(dragEnabled: Bool,
                    onDrag: @escaping (CGPoint) -> Void,
                    onHold: @escaping (Bool) -> Void,
                    onDoubleTap: (() -> Void)? = nil) -> some View {
        modifier(HoldOrDragGesture(dragEnabled: dragEnabled, onDrag: onDrag,
                                   onHold: onHold, onDoubleTap: onDoubleTap))
    }
}

// MARK: - The grade room stage

struct GradeWipeStage: View {
    @EnvironmentObject private var app: AppModel

    /// Width / height of what is on stage.
    let aspect: CGFloat
    /// The still on stage at full size. nil while a video plays.
    let still: CIImage?
    /// Where the subject sits, so the full-bleed crop keeps it in view.
    var focus: UnitPoint = .center
    /// Where the vertical line sits, as a fraction of the picture's width.
    /// Original on the left of it, graded on the right.
    @Binding var wipe: CGFloat
    @Binding var eyedropping: Bool
    /// False while the original is peeked or the look is bypassed.
    var showsWipe: Bool = true
    /// The look's name ("KD2 · Golden Hour"), labelling the graded side.
    let label: String
    let signature: Color
    let onHold: (Bool) -> Void

    @State private var previewSource: CIImage?
    @State private var original: CGImage?
    /// Double tap swaps the full-bleed crop for the whole frame.
    @State private var fitted = false

    private var stillKey: String {
        guard let still else { return "video" }
        return "still-\(ObjectIdentifier(still))"
    }

    private var isStill: Bool { app.player == nil && previewSource != nil }
    private var wipeOn: Bool { showsWipe && isStill && !eyedropping }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let box = mediaRect(in: size)
            ZStack(alignment: .topLeading) {
                Color.black
                mediaLayers(box: box)
                if wipeOn {
                    seam(box: box, size: size)
                    labels(box: box, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .holdOrDrag(dragEnabled: wipeOn,
                        onDrag: { point in wipe = Self.wipeFraction(at: point, box: box) },
                        onHold: onHold,
                        onDoubleTap: {
                            withAnimation(.easeInOut(duration: 0.25)) { fitted.toggle() }
                        })
            .overlay { eyedropperLayer(box: box) }
        }
        .onAppear { syncStill() }
        .onChange(of: stillKey) { _, _ in syncStill() }
        .task(id: stillKey) { await renderOriginal() }
    }

    // MARK: Layers

    @ViewBuilder
    private func mediaLayers(box: CGRect) -> some View {
        if app.player == nil, let previewSource {
            originalLayer
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
            // A line at 0 leaves the whole picture graded.
            LiveGradedStill(source: previewSource)
                .frame(width: box.width, height: box.height)
                .clipShape(SplitRevealShape(fraction: wipeOn ? wipe : 0))
                .position(x: box.midX, y: box.midY)
        } else {
            ZStack {
                LookPreviewSurface(radius: 0, showsEmptyHint: false)
                // ≥1.4 video keeps its matte path; the box is cut to the
                // source, so there is normally nothing left to matte.
                if app.player != nil, aspect >= 1.4 {
                    LetterboxMattes(contentAspect: aspect)
                }
            }
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
        }
    }

    @ViewBuilder
    private var originalLayer: some View {
        if let original {
            Image(decorative: original, scale: 1)
                .resizable()
        } else {
            Color.black
        }
    }

    /// A straight white line down the picture and its glass handle where it
    /// crosses the middle of the screen. White, so the only colour on the
    /// picture is the grade itself.
    private func seam(box: CGRect, size: CGSize) -> some View {
        let x = box.minX + box.width * min(max(wipe, 0), 1)
        let knobY = min(max(size.height / 2, box.minY), box.maxY)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 2, height: box.height)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .position(x: x, y: box.midY)
            WipeKnob()
                .position(x: x, y: knobY)
        }
        .allowsHitTesting(false)
    }

    /// Original bottom left, the look bottom right with a dot in its colour,
    /// pinned to the part of the picture that is on screen.
    private func labels(box: CGRect, size: CGSize) -> some View {
        let visible = box.intersection(CGRect(origin: .zero, size: size))
        let frame = visible.isNull ? CGRect(origin: .zero, size: size) : visible
        return HStack(spacing: 8) {
            Text("Original")
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .modifier(StageGlassLabel())
            Spacer(minLength: 0)
            LookNameText(label, colour: signature, size: 12, alwaysDot: true,
                         quietColour: Color.white.opacity(0.92))
                .modifier(StageGlassLabel())
        }
        .padding(.horizontal, 16)
        .frame(width: frame.width)
        .position(x: frame.midX, y: frame.maxY - 29)
        .allowsHitTesting(false)
    }

    /// WB eyedropper: tap a neutral in the frame to balance to it. It has to
    /// be on the picture, because the gesture IS a pixel choice.
    @ViewBuilder
    private func eyedropperLayer(box: CGRect) -> some View {
        if eyedropping {
            ZStack(alignment: .bottom) {
                Color.white.opacity(0.001)
                Text("Tap something that should be neutral grey or white")
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let n = CGPoint(x: min(max(0, (location.x - box.minX) / max(box.width, 1)), 1),
                                y: min(max(0, (location.y - box.minY) / max(box.height, 1)), 1))
                Task { await app.whiteBalance(atNormalized: n) }
                eyedropping = false
            }
            .transition(.opacity)
        }
    }

    // MARK: Geometry

    /// Where the picture sits on the stage. Full bleed fills the stage and
    /// keeps `focus` in view; fitted shows the whole frame, centred.
    private func mediaRect(in size: CGSize) -> CGRect {
        guard size.width > 1, size.height > 1, aspect.isFinite, aspect > 0.01 else {
            return CGRect(origin: .zero, size: size)
        }
        let fill = !fitted
        let matchHeights = (aspect > size.width / size.height) == fill
        let w = matchHeights ? size.height * aspect : size.width
        let h = matchHeights ? size.height : size.width / aspect
        var x = (size.width - w) / 2
        var y = (size.height - h) / 2
        if fill {
            x = min(0, max(size.width - w, size.width / 2 - focus.x * w))
            y = min(0, max(size.height - h, size.height / 2 - focus.y * h))
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The wipe position that puts the line under the finger. It can run to
    /// either edge, so either picture can fill the stage.
    static func wipeFraction(at point: CGPoint, box: CGRect) -> CGFloat {
        guard box.width > 1, box.height > 1 else { return 0.5 }
        return min(max((point.x - box.minX) / box.width, 0), 1)
    }

    // MARK: Sources

    private func syncStill() {
        previewSource = still.map { StillCompare.downscaled($0) }
    }

    private func renderOriginal() async {
        guard let still else {
            original = nil
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            StillCompare.renderOriginal(still)
        }.value
        guard !Task.isCancelled else { return }
        original = image
    }
}

// MARK: - Labels on the picture

/// A small glass label over footage, 26 pt high: dark translucent glass, no
/// outline, so it reads on any frame without adding colour of its own.
struct StageGlassLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color(hex: 0x101114).opacity(0.58), in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}
