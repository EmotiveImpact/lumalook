import SwiftUI

/// Per-clip free crop + straighten. A draggable crop rectangle over the clip
/// thumbnail (corner handles resize, body drags) plus a fine straighten
/// slider. Commits a unit crop rect + degrees back to the engine.
struct CropStraightenView: View {
    let thumbnail: CGImage?
    let aspect: CGFloat            // canvas aspect (w/h) for the preview frame
    let initialCrop: CGRect
    let initialStraighten: Double
    let onApply: (CGRect, Double) -> Void
    let onCancel: () -> Void

    @State private var crop: CGRect
    @State private var straighten: Double

    init(thumbnail: CGImage?, aspect: CGFloat, initialCrop: CGRect,
         initialStraighten: Double,
         onApply: @escaping (CGRect, Double) -> Void, onCancel: @escaping () -> Void) {
        self.thumbnail = thumbnail
        self.aspect = aspect
        self.initialCrop = initialCrop
        self.initialStraighten = initialStraighten
        self.onApply = onApply
        self.onCancel = onCancel
        _crop = State(initialValue: initialCrop)
        _straighten = State(initialValue: initialStraighten)
    }

    private let minSize: CGFloat = 0.15

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("Cancel", action: onCancel)
                    .foregroundStyle(LumaTheme.textSecondary)
                Spacer()
                Text("Crop & Straighten").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Apply") { onApply(crop, straighten) }
                    .foregroundStyle(LumaTheme.accentBright).fontWeight(.semibold)
            }

            GeometryReader { geo in
                let frame = fittedRect(in: geo.size)
                ZStack {
                    imageLayer
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.degrees(straighten))
                        .scaleEffect(straightenFill)
                        .clipShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    cropOverlay(frame: frame, origin: CGPoint(
                        x: (geo.size.width - frame.width) / 2,
                        y: (geo.size.height - frame.height) / 2))
                }
            }
            .frame(height: 300)

            // Straighten slider with a live degree readout.
            VStack(spacing: 6) {
                HStack {
                    Text("Straighten").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                    Spacer()
                    Text("\(Int(straighten))°").font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Slider(value: $straighten, in: -15...15, step: 1)
                    .tint(LumaTheme.accentBright)
            }

            HStack(spacing: 10) {
                cropPreset("Reset", .init(x: 0, y: 0, width: 1, height: 1))
                cropPreset("Center", .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
                Button {
                    straighten = 0
                    crop = .init(x: 0, y: 0, width: 1, height: 1)
                } label: {
                    Text("Clear").frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).foregroundStyle(LumaTheme.textSecondary)
                    .padding(.vertical, 10)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .background(LumaTheme.background)
    }

    @ViewBuilder private var imageLayer: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(LumaTheme.surface)
        }
    }

    /// Over-scale factor mirroring the compositor's straighten auto-fill.
    private var straightenFill: CGFloat {
        let a = abs(straighten) * .pi / 180
        let r = aspect
        return CGFloat(cos(a) + sin(a) * max(r, 1 / r))
    }

    private func cropPreset(_ title: String, _ rect: CGRect) -> some View {
        Button { crop = rect } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .padding(.vertical, 10)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func fittedRect(in size: CGSize) -> CGSize {
        var w = size.width
        var h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGSize(width: w, height: h)
    }

    /// Crop rectangle + dimmed surround + corner handles. All maths in unit
    /// space; converts to pixels via the fitted preview frame.
    private func cropOverlay(frame: CGSize, origin: CGPoint) -> some View {
        let px = CGRect(x: origin.x + crop.minX * frame.width,
                        y: origin.y + crop.minY * frame.height,
                        width: crop.width * frame.width,
                        height: crop.height * frame.height)
        return ZStack {
            Rectangle()
                .path(in: px)
                .stroke(.white, lineWidth: 2)
            ForEach(0..<4, id: \.self) { corner in
                handle(corner: corner, px: px, frame: frame, origin: origin)
            }
        }
        // Drag the body to move the crop.
        .contentShape(Rectangle().path(in: px))
        .gesture(
            DragGesture()
                .onChanged { g in
                    let dx = g.translation.width / frame.width
                    let dy = g.translation.height / frame.height
                    var r = dragStart ?? crop
                    r.origin.x = min(max(0, r.minX + dx), 1 - r.width)
                    r.origin.y = min(max(0, r.minY + dy), 1 - r.height)
                    if dragStart == nil { dragStart = crop }
                    crop = r
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    @State private var dragStart: CGRect?
    @State private var handleStart: CGRect?

    private func handle(corner: Int, px: CGRect, frame: CGSize, origin: CGPoint) -> some View {
        let point: CGPoint
        switch corner {
        case 0: point = CGPoint(x: px.minX, y: px.minY)
        case 1: point = CGPoint(x: px.maxX, y: px.minY)
        case 2: point = CGPoint(x: px.minX, y: px.maxY)
        default: point = CGPoint(x: px.maxX, y: px.maxY)
        }
        return Circle().fill(.white).frame(width: 18, height: 18)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { g in
                        if handleStart == nil { handleStart = crop }
                        var r = handleStart!
                        let dx = g.translation.width / frame.width
                        let dy = g.translation.height / frame.height
                        switch corner {
                        case 0: resize(&r, minX: r.minX + dx, minY: r.minY + dy)
                        case 1: resize(&r, minY: r.minY + dy, maxX: r.maxX + dx)
                        case 2: resize(&r, minX: r.minX + dx, maxY: r.maxY + dy)
                        default: resize(&r, maxX: r.maxX + dx, maxY: r.maxY + dy)
                        }
                        crop = r
                    }
                    .onEnded { _ in handleStart = nil }
            )
    }

    private func resize(_ r: inout CGRect, minX: CGFloat? = nil, minY: CGFloat? = nil,
                        maxX: CGFloat? = nil, maxY: CGFloat? = nil) {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        if let minX { x0 = min(max(0, minX), x1 - minSize) }
        if let minY { y0 = min(max(0, minY), y1 - minSize) }
        if let maxX { x1 = max(min(1, maxX), x0 + minSize) }
        if let maxY { y1 = max(min(1, maxY), y0 + minSize) }
        r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
