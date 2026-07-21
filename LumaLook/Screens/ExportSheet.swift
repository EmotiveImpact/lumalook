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

/// Delivery spec before the render, in the shipping design language proved by
/// `LDExportDemoView`: resolution as three tap-cards that LEAD WITH THE VALUE,
/// frame rate / bitrate / codec as labelled option rows (a slider for five
/// discrete values is a dial pretending to be continuous), the HDR, GIF, audio
/// and .cube capabilities as an unboxed tool row, a live size estimate and a
/// calm instruction bar. Reads and writes the same `lumalook.exportSpec` store
/// the Settings "Export Quality" default writes, so the two never disagree.
///
/// Chrome is monochrome — black, near-black, white, grey. Mono type is for
/// NUMBERS ONLY (resolutions, frame rates, sizes, cube grids); every label is
/// the system face in sentence case. Selection is one thin white ring and
/// nothing else is ringed; unselected options separate by surface value.
struct ExportSpecSheet: View {
    let durationSeconds: Double
    let gradeCubeTitle: String?        // nil = editor flow (no cube row)
    let lookState: LookState?
    let onExport: (ExportSpec) -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue
    @AppStorage("lumalook.cubeSize") private var cubeSize = 33
    @State private var spec = ExportSpec()
    @State private var cubeURL: URL?
    @State private var isBaking = false
    @State private var showCubePanel = false
    /// Resolved once per open from the source's format description.
    @State private var sourceIsHLG = false

    /// Discrete frame rates. A continuous fps slider produces rates no camera
    /// or platform actually uses, and five values do not need 300 pt of travel.
    private static let frameRates = [24, 25, 30, 48, 60]

    /// The .cube bake needs a live grade to sample; the editor flow has none,
    /// so the tool is not drawn there rather than drawn dead.
    private var offersCube: Bool { gradeCubeTitle != nil && lookState != nil }
    /// GIF transcode is wired in the editor export path only — the grade flow
    /// would draw a control nothing reads.
    private var offersGIF: Bool { gradeCubeTitle == nil }

    var body: some View {
        // The spec controls scroll; the estimate and the instruction bar are
        // PINNED below them. The stack measures well past the sheet's default
        // detent, so a footer inside the ScrollView put the only primary action
        // below the fold with nothing on screen to signal it was there.
        VStack(spacing: 0) {
            ScrollView {
                specStack
            }
            .scrollBounceBehavior(.basedOnSize)

            // The estimate is G1's trust signal: it must stay on screen while
            // the user taps resolution or bitrate, at every detent the sheet
            // offers. Same fill as the sheet, so the controls read as passing
            // under it rather than being cut off by a drawn line.
            VStack(spacing: 0) {
                deliveryReadout
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                instructionBar
                    .padding(.top, 10)
            }
            .background(LumaTheme.bar)
        }
        .animation(.easeOut(duration: 0.18), value: showCubePanel)
        .animation(.easeOut(duration: 0.18), value: spec.audioOnly)
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

    private var specStack: some View {
        VStack(spacing: 0) {
            sourceLine
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if let banner = app.exportError ?? preflightWarning {
                noticeBar(banner)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            if !spec.audioOnly {
                resolutionCards
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                VStack(spacing: 9) {
                    optionRow("Frame rate", options: Self.frameRates,
                              label: { "\($0)" }, isOn: { spec.fps == $0 },
                              enabled: { _ in true }) { spec.fps = $0 }
                    // Low / Medium / High are words, not values — so they are
                    // set as words. The tier is a real file-length ceiling.
                    optionRow("Bitrate", options: ExportSpec.Bitrate.allCases,
                              numeric: false, label: { $0.rawValue },
                              isOn: { spec.bitrate == $0 },
                              enabled: { _ in true }) { spec.bitrate = $0 }
                    optionRow("Codec", options: ExportSpec.Codec.allCases,
                              label: codecLabel, isOn: { spec.codec == $0 },
                              // 720 ships H.264 only — offering HEVC would lie.
                              enabled: { !(spec.resolution == .hd720 && $0 == .hevc) }) {
                        spec.codec = $0
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            toolRow
                .padding(.bottom, showCubePanel ? 10 : 12)

            if showCubePanel, offersCube, !spec.audioOnly {
                cubePanel
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            if let reason = hdrAvailability.reason, !spec.audioOnly {
                // The HDR toggle is only honest when the pipeline can honour
                // it, so the reason it cannot is stated rather than hidden.
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: Source

    /// "Travel Vlog  00:18 … Batch 4" — what is being delivered. The title is a
    /// NAME, so it is set as one; the duration and the batch count are numbers.
    private var sourceLine: some View {
        HStack(spacing: 8) {
            Text(sourceTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if durationSeconds > 0 {
                Text(clock(durationSeconds))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            if !app.batchItems.isEmpty, gradeCubeTitle != nil {
                HStack(spacing: 5) {
                    Text("Batch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("\(app.batchItems.count)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var sourceTitle: String {
        gradeCubeTitle == nil ? app.editor.projectTitle : app.selectedLook.name
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    // MARK: Resolution — the only cards on the sheet

    /// The value leads. "2160p" tells you what you are about to write; "4K"
    /// only tells you what to call it, so it goes underneath in plain type.
    /// 720 says what it costs you — that card forces the codec.
    private var resolutionCards: some View {
        HStack(spacing: 8) {
            resolutionCard(.uhd4K, value: "2160p", name: "4K")
            resolutionCard(.hd1080, value: "1080p", name: "HD")
            resolutionCard(.hd720, value: "720p", name: "H.264 only")
        }
        .sensoryFeedback(.selection, trigger: spec.resolution)
    }

    private func resolutionCard(_ resolution: ExportSpec.Resolution,
                                value: String, name: String) -> some View {
        let selected = spec.resolution == resolution
        return Button {
            spec.resolution = resolution
            // 720 is the fast tier and has no HEVC preset — keep the codec
            // readout truthful about what will actually be written.
            if resolution == .hd720 { spec.codec = .h264 }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 18, weight: selected ? .heavy : .semibold,
                                  design: .monospaced))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.7 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            // Unselected cards separate by SURFACE VALUE. Only the chosen one
            // wears a stroke — that is what a stroke is for here.
            .background(selected ? LumaTheme.cardRaised : LumaTheme.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Option rows — five discrete values, five taps

    /// `numeric` decides the voice of the OPTIONS, never of the row's name: the
    /// name is a label and is always plain, while a frame rate or a codec
    /// designation is a value and stays mono.
    private func optionRow<T: Hashable>(_ title: String, options: [T],
                                        numeric: Bool = true,
                                        label: @escaping (T) -> String,
                                        isOn: @escaping (T) -> Bool,
                                        enabled: @escaping (T) -> Bool,
                                        pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            ForEach(options, id: \.self) { option in
                let on = isOn(option)
                let usable = enabled(option)
                Button {
                    pick(option)
                    LumaHaptics.shared.tap()
                } label: {
                    Text(label(option))
                        .font(.system(size: numeric ? 14 : 13,
                                      weight: on ? .semibold : .medium,
                                      design: numeric ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(on ? 1 : 0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .overlay {
                            if on {
                                Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
                .disabled(!usable)
                .opacity(usable ? 1 : 0.25)
            }
        }
        .sensoryFeedback(.selection, trigger: options.first { isOn($0) })
    }

    private func codecLabel(_ codec: ExportSpec.Codec) -> String {
        codec == .hevc ? "H.265" : "H.264"
    }

    // MARK: Tool row — icon over label, unboxed, the last item clipped

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tool("waveform", "Audio only", on: spec.audioOnly) {
                    spec.audioOnly.toggle()
                    LumaHaptics.shared.tap()
                }
                if offersGIF {
                    tool("square.stack.3d.down.forward", "GIF", on: spec.alsoGIF,
                         enabled: !spec.audioOnly) {
                        spec.alsoGIF.toggle()
                        LumaHaptics.shared.tap()
                    }
                }
                tool("sun.max", "HDR (HLG)", on: spec.hdr,
                     enabled: hdrAvailability.isAvailable && !spec.audioOnly) {
                    spec.hdr.toggle()
                    LumaHaptics.shared.tap()
                }
                if offersCube {
                    // The cube tool HAS a value — the grid it will bake — so it
                    // shows the value instead of a grid glyph that shows nothing.
                    valueTool("\(cubeSize)³", "Cube LUT", on: showCubePanel,
                              enabled: !spec.audioOnly) {
                        showCubePanel.toggle()
                        LumaHaptics.shared.tap()
                    }
                }
                tool("arrow.uturn.backward", "Reset", on: false) {
                    spec = ExportSpec()
                    if !hdrAvailability.isAvailable { spec.hdr = false }
                    LumaHaptics.shared.tap()
                }
            }
            .padding(.horizontal, 16)
        }
        .lumaEdgeFade(leading: 16, trailing: 16)
    }

    private func tool(_ symbol: String, _ label: String, on: Bool,
                      enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.7 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // No box, no chip, no pill — separation is by value alone. An
            // engaged tool is simply brighter than a resting one.
            .foregroundStyle(on ? .white : .white.opacity(0.5))
            .frame(width: 74, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.28)
    }

    /// The instrument-cluster twin of `tool`: a live value in mono where the
    /// glyph would have been, its name beneath in plain sentence case.
    private func valueTool(_ value: String, _ label: String, on: Bool,
                           enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(on ? .white : .white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.7 : 0.45))
                    .lineLimit(1)
            }
            .frame(width: 74, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.28)
    }

    // MARK: Cube

    private var cubePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bake this grade as a .cube — LUT, curves, wheels, HSL, split.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
            HStack(spacing: 8) {
                ForEach(GradeCubeBaker.sizes, id: \.self) { size in
                    Button {
                        cubeSize = size
                        cubeURL = nil            // stale for the new size
                        LumaHaptics.shared.tap()
                    } label: {
                        // A grid size is a number: mono stays.
                        Text("\(size)³")
                            .font(.system(size: 14,
                                          weight: cubeSize == size ? .semibold : .medium,
                                          design: .monospaced))
                            .foregroundStyle(.white.opacity(cubeSize == size ? 1 : 0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .overlay {
                                if cubeSize == size {
                                    Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
                if let cubeURL {
                    ShareLink(item: cubeURL) {
                        Text("Share")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                            .contentShape(Capsule())
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
                        Text(isBaking ? "Baking…" : "Bake")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(LumaTheme.cardRaised, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.lumaPress)
                    .disabled(isBaking)
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: HDR

    private var hdrAvailability: HDRDelivery.Availability {
        HDRDelivery.availability(
            sourceIsHLG: sourceIsHLG,
            logConversionActive: app.conversionProfile != nil || app.conversionLUT != nil,
            spec: spec,
            isTimeline: gradeCubeTitle == nil)
    }

    // MARK: Estimate + delivery spec — the trust signal, always on screen

    private var deliveryReadout: some View {
        HStack(spacing: 8) {
            if let value = estimateValue {
                Text("Est. size")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Text("Still image")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            // Format designations, not prose — this line stays in the
            // instrument voice, just brighter and a size you can read.
            Text(deliverySpecLine)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
    }

    /// Live: recomputes on every resolution / bitrate / codec / fps change,
    /// from the same bitrate model the encoder's ceiling derives from. Nil when
    /// there is no duration to estimate against — a still has no size tier.
    private var estimateValue: String? {
        if spec.audioOnly {
            guard durationSeconds > 0 else { return "—" }
            // AAC stereo at the M4A preset's 128 kbps.
            return String(format: "%.0f MB", durationSeconds * 0.128 / 8)
        }
        guard durationSeconds > 0 else { return nil }
        let mb = Double(spec.estimatedMegabytes(durationSeconds: durationSeconds))
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000)
                          : String(format: "%.0f MB", mb)
    }

    private var deliverySpecLine: String {
        if spec.audioOnly { return "AAC · M4A" }
        let colour = spec.hdr ? "HLG" : "Rec.709"
        return "\(codecLabel(spec.codec)) · \(colour) · AAC"
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

    /// A sentence on a raised surface. No orange slab, no warning triangle —
    /// the words are the warning.
    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.85))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(LumaTheme.surfaceStrong,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: The calm instruction bar

    private var instructionBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer(minLength: 8)
            Text(spec.audioOnly ? "Set the audio delivery" : "Set the delivery")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            // The one filled button in the language: the irreversible, long,
            // expensive action at the end of a tool.
            Button {
                storedSpec = spec.rawValue
                app.exportError = nil
                LumaHaptics.shared.tap()
                onExport(spec)
            } label: {
                Text(spec.audioOnly ? "Export audio" : "Export")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Color.white, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.lumaPress)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
