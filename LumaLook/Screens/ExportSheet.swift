import SwiftUI
import CoreImage

// MARK: - Grade → .cube baking (queue #11)

enum GradeCubeBaker {
    /// Bakes the CURRENT full grade (look recipe + LUT + user color sliders,
    /// intensity included) into a 33-point .cube for Resolve/Premiere/FCP.
    /// Spatial passes (grain, halation, bloom, vignette) can't live in a
    /// lattice and are stripped — the cube carries the color, the app
    /// carries the physics.
    /// Cube sizes offered to the user. 33 is the interchange default; 65 is
    /// broadcast-grade; 17 is small/fast.
    static let sizes = [17, 33, 65]

    /// Off the main actor (a 65³ bake is 274,625 lines) — snapshot the state's
    /// values first so the detached work touches no reference.
    static func bakeCurrentGrade(from state: LookState, title: String,
                                 size: Int = PackInstaller.cubeSize) async -> URL? {
        // Snapshot everything from the live LookState up front.
        let clean = LookState()
        clean.recipe = state.recipe
        clean.lut = state.lut
        // The conversion slot + BOTH opacities drive the real preview — they
        // were dropped here, so an exported cube didn't match what the user
        // saw. Carry them so cube == preview.
        clean.conversionLUT = state.conversionLUT
        clean.conversionOpacity = state.conversionOpacity
        clean.lutOpacity = state.lutOpacity
        clean.lutBlend = state.lutBlend
        var settings = state.settings
        settings.grain = 0
        settings.halation = 0
        settings.bloom = 0
        settings.vignette = 0
        settings.lensKind = LensKind.none.rawValue   // spatial: corrupts lattices
        clean.settings = settings
        clean.splitFraction = nil

        return await Task.detached { bakeCube(clean: clean, title: title, n: size) }.value
    }

    private static func bakeCube(clean: LookState, title: String, n: Int) -> URL? {
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

        // Buffered lines joined once — a 65³ += loop is O(n²) on the string.
        var lines = [String]()
        lines.reserveCapacity(n * n * n + 6)
        lines.append("TITLE \"\(title)\"")
        lines.append("# Exported from LumaLook — the app's exact grade, colour only.")
        lines.append("LUT_3D_SIZE \(n)")
        lines.append("DOMAIN_MIN 0.0 0.0 0.0")
        lines.append("DOMAIN_MAX 1.0 1.0 1.0")
        lines.append("")
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = (g * width + (b * n + r)) * 4
                    lines.append(String(format: "%.6f %.6f %.6f",
                                        max(0, min(1, out[i])),
                                        max(0, min(1, out[i + 1])),
                                        max(0, min(1, out[i + 2]))))
                }
            }
        }
        let text = lines.joined(separator: "\n")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "_")).cube")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Export spec sheet (frame G1)

/// Delivery spec before the render: resolution as three tap-cards, frame rate
/// and bitrate as sliders with mono readouts, an HDR toggle that is only
/// offered when the pipeline can honour it, a live size estimate, and the
/// .cube round-trip. Reads and writes the same `lumalook.exportSpec` store
/// the Settings "Export Quality" default writes, so the two never disagree.
struct ExportSpecSheet: View {
    let durationSeconds: Double
    let gradeCubeTitle: String?        // nil = editor flow (no cube row)
    let lookState: LookState?
    let onExport: (ExportSpec) -> Void

    @EnvironmentObject private var app: AppModel
    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue
    @AppStorage("lumalook.cubeSize") private var cubeSize = 33
    @State private var spec = ExportSpec()
    @State private var cubeURL: URL?
    @State private var isBaking = false
    /// Resolved once per open from the source's format description.
    @State private var sourceIsHLG = false

    /// Discrete frame rates the slider snaps between — a continuous fps
    /// slider produces rates no camera or platform actually uses.
    private static let frameRates = [24, 25, 30, 48, 60]

    var body: some View {
        // Scrollable so the Export CTA is always reachable — cards + sliders +
        // HDR + readouts + cube row exceed the panel's default detent.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let error = app.exportError {
                    preflightBanner(error, tone: LumaTheme.orange)
                } else if let warning = preflightWarning {
                    preflightBanner(warning, tone: LumaTheme.gold)
                }

                if !spec.audioOnly {
                    resolutionCards
                    sliderRow(label: "Frame rate", value: fpsIndexBinding,
                              range: 0...Double(Self.frameRates.count - 1),
                              readout: "\(spec.fps)")
                    sliderRow(label: "Bitrate", value: bitrateIndexBinding,
                              range: 0...Double(ExportSpec.Bitrate.allCases.count - 1),
                              readout: spec.bitrate.rawValue.uppercased())
                    hdrRow
                    codecRow
                }

                deliveryReadout

                Hairline()

                Toggle(isOn: $spec.audioOnly) {
                    Text("Audio only (M4A)")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                .tint(LumaTheme.accentBright)

                if gradeCubeTitle != nil, !spec.audioOnly {
                    cubeRow
                }

                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            spec = ExportSpec.from(rawValue: storedSpec)
            if let url = app.selectedVideoURL, gradeCubeTitle != nil {
                sourceIsHLG = await HDRDelivery.sourceIsHLG(url: url)
            }
            // A spec restored from storage can carry an HDR flag this source
            // cannot honour; drop it rather than lying in the readout.
            if !hdrAvailability.isAvailable { spec.hdr = false }
        }
        .onChange(of: hdrAvailability) { _, availability in
            if !availability.isAvailable { spec.hdr = false }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Export")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            TechReadout(sourceLine, size: 9, color: LumaTheme.textMuted)
        }
    }

    /// "TRAVEL VLOG · 00:18" — confirms what is being exported, matching the
    /// dimmed preview still visible behind the sheet.
    private var sourceLine: String {
        let title = gradeCubeTitle == nil ? app.editor.projectTitle : app.selectedLook.name
        guard durationSeconds > 0 else { return title }
        return "\(title) · \(clock(durationSeconds))"
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    // MARK: Resolution cards

    private var resolutionCards: some View {
        HStack(spacing: 8) {
            resolutionCard(.uhd4K, title: "4K", sub: "2160p")
            resolutionCard(.hd1080, title: "HD", sub: "1080p")
            resolutionCard(.hd720, title: "720", sub: "Fast")
        }
        .sensoryFeedback(.selection, trigger: spec.resolution)
    }

    private func resolutionCard(_ resolution: ExportSpec.Resolution,
                                title: String, sub: String) -> some View {
        let selected = spec.resolution == resolution
        return Button {
            spec.resolution = resolution
            // 720 is the fast tier and has no HEVC preset — keep the codec
            // readout truthful about what will actually be written.
            if resolution == .hd720 { spec.codec = .h264 }
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: selected ? .heavy : .bold))
                    .foregroundStyle(selected ? LumaTheme.accentBright : .white)
                TechReadout(sub, size: 9, color: selected ? LumaTheme.accentBright.opacity(0.8)
                                                          : LumaTheme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(selected ? LumaTheme.accentSoft : LumaTheme.surface,
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(selected ? LumaTheme.accent.opacity(0.55) : LumaTheme.hairline,
                              lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Sliders

    private var fpsIndexBinding: Binding<Double> {
        Binding(
            get: { Double(Self.frameRates.firstIndex(of: spec.fps) ?? 2) },
            set: { spec.fps = Self.frameRates[Int($0.rounded())] }
        )
    }

    private var bitrateIndexBinding: Binding<Double> {
        Binding(
            get: { Double(ExportSpec.Bitrate.allCases.firstIndex(of: spec.bitrate) ?? 2) },
            set: { spec.bitrate = ExportSpec.Bitrate.allCases[Int($0.rounded())] }
        )
    }

    private func sliderRow(label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, readout: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .tint(LumaTheme.accent)
            TechReadout(readout, size: 10, color: .white)
                .frame(width: 62, alignment: .trailing)
        }
        .sensoryFeedback(.selection, trigger: readout)
    }

    // MARK: HDR

    private var hdrAvailability: HDRDelivery.Availability {
        HDRDelivery.availability(
            sourceIsHLG: sourceIsHLG,
            logConversionActive: app.conversionProfile != nil || app.conversionLUT != nil,
            spec: spec,
            isTimeline: gradeCubeTitle == nil)
    }

    private var hdrRow: some View {
        let availability = hdrAvailability
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $spec.hdr) {
                Text("HDR (HLG)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(availability.isAvailable ? .white : LumaTheme.textMuted)
            }
            .tint(LumaTheme.accentBright)
            .disabled(!availability.isAvailable)

            if let reason = availability.reason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(LumaTheme.hairline, lineWidth: 1))
    }

    // MARK: Codec

    private var codecRow: some View {
        HStack(spacing: 12) {
            Text("Codec")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 78, alignment: .leading)
            Spacer()
            HStack(spacing: 2) {
                ForEach(ExportSpec.Codec.allCases, id: \.rawValue) { codec in
                    Button { spec.codec = codec } label: {
                        Text(codecLabel(codec))
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(spec.codec == codec ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(spec.codec == codec
                                        ? AnyShapeStyle(LumaTheme.accent)
                                        : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.lumaPress)
                    // 720 ships H.264 only — offering HEVC here would lie.
                    .disabled(spec.resolution == .hd720 && codec == .hevc)
                    .opacity(spec.resolution == .hd720 && codec == .hevc ? 0.35 : 1)
                }
            }
            .padding(2)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .sensoryFeedback(.selection, trigger: spec.codec)
    }

    private func codecLabel(_ codec: ExportSpec.Codec) -> String {
        codec == .hevc ? "H.265" : "H.264"
    }

    // MARK: Estimate + delivery spec

    /// Live: recomputes on every resolution / bitrate / codec / fps change.
    private var estimateLine: String {
        if spec.audioOnly {
            guard durationSeconds > 0 else { return "EST. —" }
            // AAC stereo at the M4A preset's 128 kbps.
            return String(format: "EST. %.0f MB", durationSeconds * 0.128 / 8)
        }
        guard durationSeconds > 0 else { return "STILL IMAGE" }
        let mb = Double(spec.estimatedMegabytes(durationSeconds: durationSeconds))
        return mb >= 1000
            ? String(format: "EST. SIZE %.1f GB", mb / 1000)
            : String(format: "EST. SIZE %.0f MB", mb)
    }

    private var deliverySpecLine: String {
        if spec.audioOnly { return "AAC · M4A" }
        let colour = spec.hdr ? "HLG" : "REC.709"
        return "\(codecLabel(spec.codec)) · \(colour) · AAC"
    }

    private var deliveryReadout: some View {
        HStack {
            TechReadout(estimateLine, size: 9, color: LumaTheme.textSecondary)
            Spacer()
            TechReadout(deliverySpecLine, size: 9, color: LumaTheme.textMuted)
        }
    }

    // MARK: Preflight

    /// The exporter's own preflight throws on thermal/disk; surfacing the same
    /// two conditions here means the user is warned before the long render,
    /// not after it dies.
    private var preflightWarning: String? {
        if ProcessInfo.processInfo.thermalState == .critical {
            return "Your iPhone is too hot to export safely. Let it cool down for a minute."
        }
        guard durationSeconds > 0, !spec.audioOnly else { return nil }
        let needed = spec.estimatedMegabytes(durationSeconds: durationSeconds) + 200
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        if free < Int64(needed) * 1_000_000 {
            return "Not enough free space — this export needs about \(needed) MB. Try a lower resolution or bitrate."
        }
        return nil
    }

    private func preflightBanner(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tone.opacity(0.5), lineWidth: 1))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // GIF transcode is wired in the editor export path only; the grade
            // flow would draw a control nothing reads, so it isn't drawn.
            if !spec.audioOnly, gradeCubeTitle == nil {
                Button {
                    spec.alsoGIF.toggle()
                    LumaHaptics.shared.tap()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "square.stack.3d.down.forward")
                            .font(.system(size: 15, weight: .semibold))
                        TechReadout("GIF", size: 9, color: spec.alsoGIF ? .white : LumaTheme.textSecondary)
                    }
                    .foregroundStyle(spec.alsoGIF ? .white : LumaTheme.textSecondary)
                    .frame(width: 62, height: 52)
                    .background(spec.alsoGIF ? LumaTheme.accentSoft : LumaTheme.surface,
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(spec.alsoGIF ? LumaTheme.accent.opacity(0.55) : LumaTheme.hairline,
                                      lineWidth: 1))
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Also save a looping GIF")
            }
            SolidCTA(title: spec.audioOnly ? "Export audio" : "Export video", height: 52) {
                storedSpec = spec.rawValue
                app.exportError = nil
                onExport(spec)
            }
        }
    }

    @ViewBuilder
    private var cubeRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 18))
                    .foregroundStyle(LumaTheme.accentBright)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save this grade as .cube")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("The full grade — LUT, curves, wheels, HSL, split")
                        .font(.system(size: 11))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                Spacer()
                if let cubeURL {
                    ShareLink(item: cubeURL) {
                        TechReadout("SHARE \(cubeSize)³", size: 9, color: LumaTheme.accentBright)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(LumaTheme.accent.opacity(0.2), in: Capsule())
                    }
                } else {
                    Button {
                        Task {
                            guard let state = lookState, let title = gradeCubeTitle else { return }
                            isBaking = true
                            cubeURL = await GradeCubeBaker.bakeCurrentGrade(
                                from: state, title: title, size: cubeSize)
                            isBaking = false
                            LumaHaptics.shared.tap()
                        }
                    } label: {
                        TechReadout(isBaking ? "…" : "BAKE", size: 9, color: .white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                    .disabled(isBaking)
                }
            }
            // Cube size — re-bake on change.
            HStack(spacing: 6) {
                ForEach(GradeCubeBaker.sizes, id: \.self) { size in
                    Button {
                        cubeSize = size
                        cubeURL = nil   // stale for the new size
                    } label: {
                        Text("\(size)³")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(cubeSize == size ? .white : LumaTheme.textSecondary)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(cubeSize == size ? LumaTheme.accent : LumaTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(.white.opacity(0.18)))
    }
}
