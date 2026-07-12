import SwiftUI
import CoreImage

// MARK: - Grade → .cube baking (queue #11)

enum GradeCubeBaker {
    /// Bakes the CURRENT full grade (look recipe + LUT + user color sliders,
    /// intensity included) into a 33-point .cube for Resolve/Premiere/FCP.
    /// Spatial passes (grain, halation, bloom, vignette) can't live in a
    /// lattice and are stripped — the cube carries the color, the app
    /// carries the physics.
    @MainActor
    static func bakeCurrentGrade(from state: LookState, title: String) -> URL? {
        let clean = LookState()
        clean.recipe = state.recipe
        clean.lut = state.lut
        var settings = state.settings
        settings.grain = 0
        settings.halation = 0
        settings.bloom = 0
        settings.vignette = 0
        settings.lensKind = LensKind.none.rawValue   // spatial: corrupts lattices
        clean.settings = settings
        clean.splitFraction = nil

        let n = PackInstaller.cubeSize
        let width = n * n
        let height = n
        var pixels = [Float32](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i + 0] = Float32(x % n) / Float32(n - 1)
                pixels[i + 1] = Float32(y) / Float32(n - 1)
                pixels[i + 2] = Float32(x / n) / Float32(n - 1)
                pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let identity = CIImage(bitmapData: data, bytesPerRow: width * 16,
                               size: CGSize(width: width, height: height),
                               format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let graded = LookPipeline.shared.apply(state: clean, to: identity, includeSplit: false)
            .cropped(to: identity.extent)

        var out = [Float32](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            LookPipeline.shared.context.render(
                graded, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        var text = """
        TITLE "\(title)"
        # Exported from LumaLook — the app's exact grade, colour only.
        LUT_3D_SIZE \(n)
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0

        """
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = (g * width + (b * n + r)) * 4
                    text += String(format: "%.6f %.6f %.6f\n",
                                   max(0, min(1, out[i])),
                                   max(0, min(1, out[i + 1])),
                                   max(0, min(1, out[i + 2])))
                }
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "_")).cube")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Export spec sheet (queue #6 + #2-lite + #11)

/// Spec before render: resolution / codec / fps, live size estimate, the
/// preview-parity trust line, and the .cube round-trip. Last spec sticks.
struct ExportSpecSheet: View {
    let durationSeconds: Double
    let gradeCubeTitle: String?        // nil = editor flow (no cube row)
    let lookState: LookState?
    let onExport: (ExportSpec) -> Void

    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue
    @State private var spec = ExportSpec()
    @State private var cubeURL: URL?

    var body: some View {
        VStack(spacing: 4) {
            TechReadout("EXPORT", size: 10, color: LumaTheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            specRow("Resolution", options: ExportSpec.Resolution.allCases.map(\.rawValue),
                    selection: Binding(get: { spec.resolution.rawValue },
                                       set: { spec.resolution = .init(rawValue: $0) ?? .hd1080 }))
            Hairline()
            specRow("Codec", options: ExportSpec.Codec.allCases.map(\.rawValue),
                    selection: Binding(get: { spec.codec.rawValue },
                                       set: { spec.codec = .init(rawValue: $0) ?? .hevc }))
            Hairline()
            specRow("Frame rate", options: ["24", "30", "60"],
                    selection: Binding(get: { "\(spec.fps)" },
                                       set: { spec.fps = Int($0) ?? 30 }))

            HStack {
                TechReadout(estimateLine, size: 9, color: LumaTheme.textMuted)
                Spacer()
                TechReadout("PREVIEW = EXPORT ✓", size: 9, color: LumaTheme.teal)
            }
            .padding(.top, 10)

            if gradeCubeTitle != nil {
                cubeRow
                    .padding(.top, 10)
            }

            SolidCTA(title: "Export Video", height: 52) {
                storedSpec = spec.rawValue
                onExport(spec)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { spec = ExportSpec.from(rawValue: storedSpec) }
    }

    private var estimateLine: String {
        guard durationSeconds > 0 else { return "STILL IMAGE" }
        let mbps: Double
        switch (spec.resolution, spec.codec) {
        case (.hd1080, .h264): mbps = 12
        case (.uhd4K, .h264): mbps = 45
        case (.hd1080, .hevc): mbps = 7
        case (.uhd4K, .hevc): mbps = 28
        }
        let mb = durationSeconds * mbps / 8
        let m = Int(durationSeconds) / 60, s = Int(durationSeconds) % 60
        return String(format: "EST. %.0f MB · %02d:%02d", mb, m, s)
    }

    private func specRow(_ label: String, options: [String],
                         selection: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(option)
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(selection.wrappedValue == option ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selection.wrappedValue == option
                                        ? AnyShapeStyle(LumaTheme.accent)
                                        : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(2)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.vertical, 7)
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }

    @ViewBuilder
    private var cubeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 18))
                .foregroundStyle(LumaTheme.accentBright)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save this grade as .cube")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Opens in Resolve, Premiere, FCP")
                    .font(.system(size: 11))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            Spacer()
            if let cubeURL {
                ShareLink(item: cubeURL) {
                    TechReadout("SHARE 33³", size: 9, color: LumaTheme.accentBright)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(LumaTheme.accent.opacity(0.2), in: Capsule())
                }
            } else {
                Button {
                    if let state = lookState, let title = gradeCubeTitle {
                        cubeURL = GradeCubeBaker.bakeCurrentGrade(from: state, title: title)
                        LumaHaptics.shared.tap()
                    }
                } label: {
                    TechReadout("BAKE", size: 9, color: .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(.white.opacity(0.18)))
    }
}
