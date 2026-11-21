import SwiftUI
import CoreImage

// =============================================================================
// THE GRADE ROOM STAGE, and the still helpers the photo editor shares.
//
// The grade room shows the picture full bleed, edge to edge and up under the
// status bar, with a diagonal wipe: the graded picture on the left of a line
// that leans like "/", the original on the right. The line glows in the look's
// signature colour and carries a round handle; drag anywhere on the picture to
// move it. Hold still to peek at the original, double tap to see the whole
// frame instead of the full-bleed crop.
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

enum DiagonalWipe {
    /// Horizontal run of the wipe line per point of height: a lean of about
    /// 18 degrees, like the mock.
    static let lean: CGFloat = 0.32
}

/// The graded side of the grade room wipe: everything left of a line that
/// leans like "/" and crosses mid-height at `centre` (a fraction of the width).
struct DiagonalWipeShape: Shape {
    var centre: CGFloat

    var animatableData: CGFloat {
        get { centre }
        set { centre = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let half = rect.height / 2 * DiagonalWipe.lean
        let mid = rect.minX + rect.width * centre
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: mid + half, y: rect.minY))
        path.addLine(to: CGPoint(x: mid - half, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The edited side of the photo editor's split: everything right of a
/// vertical line at `fraction` of the width.
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

/// The round handle that rides a wipe line.
struct WipeKnob: View {
    var ring: Color = .white

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 32, height: 32)
            .overlay(Circle().strokeBorder(ring, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .overlay {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.72))
            }
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
    /// Where the line crosses mid-height, as a fraction of the picture's width.
    @Binding var wipe: CGFloat
    @Binding var eyedropping: Bool
    /// False while the original is peeked or the look is bypassed.
    var showsWipe: Bool = true
    /// The look's short code ("KD2"), labelling the graded side.
    let code: String
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
            // A centre far past the right edge covers the whole picture.
            LiveGradedStill(source: previewSource)
                .frame(width: box.width, height: box.height)
                .clipShape(DiagonalWipeShape(centre: wipeOn ? wipe : 4))
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

    /// The line in the look's colour, and its knob where it crosses the
    /// middle of the screen.
    private func seam(box: CGRect, size: CGSize) -> some View {
        let half = box.height / 2 * DiagonalWipe.lean
        let mid = box.minX + box.width * wipe
        let knobY = min(max(size.height / 2, box.minY), box.maxY)
        let knobX = mid + DiagonalWipe.lean * (box.midY - knobY)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: mid + half, y: box.minY))
                path.addLine(to: CGPoint(x: mid - half, y: box.maxY))
            }
            .stroke(signature, lineWidth: 2)
            .shadow(color: signature.opacity(0.8), radius: 6)
            WipeKnob(ring: signature)
                .position(x: knobX, y: knobY)
        }
        .allowsHitTesting(false)
    }

    /// Graded bottom left, Original bottom right, pinned to the part of the
    /// picture that is on screen.
    private func labels(box: CGRect, size: CGSize) -> some View {
        let visible = box.intersection(CGRect(origin: .zero, size: size))
        let frame = visible.isNull ? CGRect(origin: .zero, size: size) : visible
        return HStack(spacing: 8) {
            wipeLabel(code, colour: signature)
            Spacer(minLength: 0)
            wipeLabel("Original", colour: LumaTheme.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(width: frame.width)
        .position(x: frame.midX, y: frame.maxY - 26)
        .allowsHitTesting(false)
    }

    private func wipeLabel(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.luma(size: 12, weight: .semibold))
            .foregroundStyle(colour)
            .lineLimit(1)
            .lumaGlassPill()
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

    /// The wipe position that puts the line under the finger. It can run
    /// fully off either side, so either picture can fill the stage.
    static func wipeFraction(at point: CGPoint, box: CGRect) -> CGFloat {
        guard box.width > 1, box.height > 1 else { return 0.5 }
        let localX = point.x - box.minX
        let localY = point.y - box.minY
        let centre = localX - DiagonalWipe.lean * (box.height / 2 - localY)
        let reach = DiagonalWipe.lean * box.height / 2 / box.width
        return min(max(centre / box.width, -reach), 1 + reach)
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
