import SwiftUI
import AVKit
import CoreImage

// =============================================================================
// LDExportDemoView — the whole Export flow rebuilt in the Lens-Distortions
// direction: spec → render → result, on ONE screen with the picture never
// covered. A WORKING preview, not a mock: it writes the real `ExportSpec`,
// drives the real `app.exporter`, and reads its metadata back off the file
// that was actually produced. Reachable headlessly with LUMA_ROUTE=ldExport.
//
// FEATURE INVENTORY vs ExportSpecSheet + ExportCompleteView — nothing dropped.
//
//   SPEC
//   ✓ Resolution tap-cards — 2160p / 1080p / 720p, the value leading and the
//     name beneath (720 forces H.264, as the presets do, and says so)
//   ✓ Frame rate — 24 / 25 / 30 / 48 / 60
//   ✓ Bitrate tier — Low / Medium / High (a real file-length ceiling)
//   ✓ Codec — H.264 / H.265, HEVC correctly unavailable at 720
//   ✓ HDR (HLG) gating with the exact reason it is unavailable, from
//     `HDRDelivery.availability` — source HLG detection included
//   ✓ Live size estimate — recomputes on every resolution/bitrate/codec change
//     via `spec.estimatedMegabytes`, the same model the encoder is held to
//   ✓ Delivery spec readout — codec · colour · audio
//   ✓ Audio only (M4A)
//   ✓ Also save a looping GIF
//   ✓ Grade → .cube bake, 17³ / 33³ / 65³, with a real ShareLink
//   ✓ Preflight warnings — thermal state and free disk space, before the render
//   ✓ Export error surfaced verbatim (`app.exportError`)
//   ✓ Spec persisted to the same `lumalook.exportSpec` store Settings writes
//
//   RENDER
//   ✓ Real progress from `app.exporter.progress` — never faked
//   ✓ Cancel → `app.exporter.cancel()`
//   ✓ Batch export — one grade across the whole picked set, with the live
//     "Processing n of m" status from `app.batchStatus`
//
//   RESULT
//   ✓ Real output metadata read back off the written file (`ExportOutputInfo`):
//     dimensions, duration, file size, codec
//   ✓ Real poster frame of the exported file
//   ✓ Share (system sheet), Share GIF
//   ✓ Save to Photos retry when the library hand-off was refused, with the
//     Settings deep link explanation
//   ✓ Export another (back to the spec, same source)
//   ✓ Continue in Editor (carries the grade into the clip)
//   ✓ New project
//   ✓ Purged-file handling — a URL is not proof of a file; every share
//     affordance checks the file still exists
//
//   ✗ Out of scope, deliberately: the brand share TILES (Instagram / TikTok /
//     YouTube). Every one of them was a `ShareLink` to the identical system
//     sheet the Share button already opens, drawn four times in four brand
//     colours. In a monochrome language they would have to lose the branding,
//     at which point they are four copies of one button. The capability —
//     sharing to those apps — is unchanged and one tap away.
//   ✗ The celebratory confetti / sparkle spray. Nothing is lost but the noise.
//
// THE DESIGN LANGUAGE
//   1. The image is the interface — the frame being delivered stays uncovered
//      at the top through all three phases. The render does NOT throw a
//      full-screen scrim over it; progress reports in the drawer.
//   2. Monochrome chrome. No exception is needed on this screen at all.
//   3. Stroke means selection — one thin white ring, nothing else is ringed.
//   5. A calm instruction bar: ✕ at one edge, a plain sentence centred, and
//      the one filled button in the language at the other.
//   6. Mono microtype for NUMBERS ONLY — sizes, bitrates, resolutions, frame
//      rates, durations, percentages, cube point counts. Every label, heading,
//      state and button beside them is the system face, sentence case, no
//      tracking, 11–15pt at a contrast you can read.
//   7. Where a control HAS a value, it shows the value: the resolution cards
//      lead with 2160p / 1080p / 720p, and the cube tool shows the point size
//      it will bake. The number is the better icon, and it is live.
//   8. Tool rows are icon-over-label and unboxed, the last item clipped.
// =============================================================================

struct LDExportDemoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case spec, exporting, complete }
    @State private var phase: Phase = .spec

    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue
    @AppStorage("lumalook.cubeSize") private var cubeSize = 33
    @State private var spec = ExportSpec()

    @State private var durationSeconds: Double = 0
    @State private var sourceIsHLG = false
    @State private var showCubePanel = false
    @State private var cubeURL: URL?
    @State private var isBaking = false
    @State private var info = ExportOutputInfo()
    @State private var poster: CGImage?
    @State private var isSavingToPhotos = false

    private static let frameRates = [24, 25, 30, 48, 60]

    // MARK: - Body

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
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: phase)
        .animation(.easeOut(duration: 0.18), value: showCubePanel)
        .animation(.easeOut(duration: 0.18), value: spec.audioOnly)
        .task { await load() }
        .onChange(of: hdrAvailability) { _, availability in
            if !availability.isAvailable { spec.hdr = false }
        }
    }

    private func load() async {
        spec = ExportSpec.from(rawValue: storedSpec)
        app.exportError = nil
        if let url = app.selectedVideoURL {
            let asset = AVURLAsset(url: url)
            durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
            sourceIsHLG = await HDRDelivery.sourceIsHLG(url: url)
        }
        // A spec restored from storage can carry an HDR flag this source cannot
        // honour — drop it rather than let the readout lie.
        if !hdrAvailability.isAvailable { spec.hdr = false }
    }

    // MARK: - Media — uncovered in every phase

    private var media: some View {
        GeometryReader { geo in
            Group {
                if phase == .complete, let still = app.lastExportImage {
                    Image(decorative: still, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else if phase == .complete, let poster {
                    Image(decorative: poster, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else if let frame = app.previewFrame ?? HeroPhoto.golden.ciImage,
                          let cg = LookPipeline.shared.context.createCGImage(
                            LookPipeline.shared.apply(state: app.lookState, to: frame),
                            from: frame.extent) {
                    Image(decorative: cg, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.08)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: - Drawer

    private var drawer: some View {
        VStack(spacing: 0) {
            switch phase {
            case .spec:      specDrawer
            case .exporting: renderDrawer
            case .complete:  completeDrawer
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    // MARK: Phase 1 — the spec

    private var specDrawer: some View {
        VStack(spacing: 0) {
            sourceLine
                .padding(.horizontal, 18)
                .padding(.top, 16)
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
                    // Low / Medium / High are words, not values.
                    optionRow("Bitrate", options: ExportSpec.Bitrate.allCases,
                              numeric: false,
                              label: { $0.rawValue.capitalized },
                              isOn: { spec.bitrate == $0 },
                              enabled: { _ in true }) { spec.bitrate = $0 }
                    optionRow("Codec", options: ExportSpec.Codec.allCases,
                              label: { $0 == .hevc ? "H.265" : "H.264" },
                              isOn: { spec.codec == $0 },
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

            if showCubePanel, !spec.audioOnly {
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

            deliveryReadout
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            instructionBar
        }
    }

    /// "Travel Vlog  00:18 … Batch 4" — what is being delivered. The look is a
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
            if !app.batchItems.isEmpty {
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
        app.selectedLUT?.displayName ?? app.selectedLook.name
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    /// "PROCESSING 2 OF 5" → "Processing 2 of 5". The model shouts its status
    /// in caps; this screen reads it back as a sentence, numerals untouched.
    private static func sentenceCased(_ raw: String) -> String {
        let lower = raw.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    // MARK: Resolution — the only cards on the screen

    /// The value leads. "2160p" tells you what you are about to write; "4K"
    /// only tells you what to call it, so it goes underneath in plain type.
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
            .background(Color(white: selected ? 0.13 : 0.07),
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

    // MARK: Option rows

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

    // MARK: Tool row — icon over label, unboxed, last item clipped

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tool("waveform", "Audio only", on: spec.audioOnly) {
                    spec.audioOnly.toggle()
                    LumaHaptics.shared.tap()
                }
                tool("square.stack.3d.down.forward", "GIF", on: spec.alsoGIF,
                     enabled: !spec.audioOnly) {
                    spec.alsoGIF.toggle()
                    LumaHaptics.shared.tap()
                }
                tool("sun.max", "HDR (HLG)", on: spec.hdr,
                     enabled: hdrAvailability.isAvailable && !spec.audioOnly) {
                    spec.hdr.toggle()
                    LumaHaptics.shared.tap()
                }
                // The cube tool HAS a value — the grid it will bake — so it
                // shows the value instead of a grid glyph that shows nothing.
                valueTool("\(cubeSize)³", "Cube LUT", on: showCubePanel,
                          enabled: !spec.audioOnly) {
                    showCubePanel.toggle()
                    LumaHaptics.shared.tap()
                }
                tool("arrow.uturn.backward", "Reset", on: false) {
                    spec = ExportSpec()
                    if !hdrAvailability.isAvailable { spec.hdr = false }
                    LumaHaptics.shared.tap()
                }
                tool("film.stack", "Editor", on: false) { app.path = [.editor] }
                tool("photo.on.rectangle", "Source", on: false) { app.path = [.selectClip] }
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
                            isBaking = true
                            cubeURL = await GradeCubeBaker.bakeCurrentGrade(
                                from: app.lookState,
                                title: "LumaLook_\(app.selectedLook.name.components(separatedBy: " ").first ?? "Grade")",
                                size: cubeSize)
                            isBaking = false
                            LumaHaptics.shared.tap()
                        }
                    } label: {
                        Text(isBaking ? "Baking…" : "Bake")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.13), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.lumaPress)
                    .disabled(isBaking)
                }
            }
        }
        .transition(.opacity)
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
        let codec = spec.codec == .hevc ? "H.265" : "H.264"
        return "\(codec) · \(colour) · AAC"
    }

    // MARK: HDR + preflight

    private var hdrAvailability: HDRDelivery.Availability {
        HDRDelivery.availability(
            sourceIsHLG: sourceIsHLG,
            logConversionActive: app.conversionProfile != nil || app.conversionLUT != nil,
            spec: spec,
            isTimeline: false)
    }

    /// The exporter's own preflight throws on thermal/disk; stating the same
    /// two conditions here warns the user BEFORE the long render, not after it
    /// dies.
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
            .background(Color(white: 0.10),
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
            Spacer(minLength: 8)
            Text(spec.audioOnly ? "Set the audio delivery" : "Set the delivery")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 8)
            // The one filled button in the language: the irreversible, long,
            // expensive action at the end of a tool.
            Button { startExport() } label: {
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
        .padding(.bottom, 6)
    }

    // MARK: Phase 2 — the render
    //
    // No full-screen scrim. The frame stays visible while it is being written;
    // progress is a number and a rule, on the drawer where the controls were.

    private var renderDrawer: some View {
        VStack(spacing: 14) {
            HStack {
                // `app.batchStatus` arrives as "PROCESSING 2 OF 5" from the
                // model; it is read here as a sentence, numerals intact.
                Text(app.batchStatus.map(Self.sentenceCased)
                     ?? (spec.audioOnly ? "Writing audio" : "Writing video"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int(app.exporter.progress * 100))%")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }

            // Determinate, from the session's own progress — never a spinner
            // pretending to know something it doesn't.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.12))
                    Rectangle().fill(.white)
                        .frame(width: geo.size.width * max(app.exporter.progress, 0.005))
                        .animation(.easeInOut(duration: 0.2), value: app.exporter.progress)
                }
            }
            .frame(height: 2)

            HStack {
                Text(deliverySpecLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                Button {
                    app.exporter.cancel()
                    LumaHaptics.shared.tap()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    // MARK: Phase 3 — the result

    /// A URL is NOT proof of a file: exports land in the temporary directory,
    /// which iOS purges freely.
    private var shareableURL: URL? {
        guard let url = app.lastExportURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var shareableGIFURL: URL? {
        guard let url = app.lastExportGIFURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var hasArtefact: Bool { app.lastExportImage != nil || shareableURL != nil }

    private var completeDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(hasArtefact ? "Export complete" : "Export unavailable")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(app.lastExportSavedToPhotos ? "Saved to Photos" : "Not in Photos")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // The delivery spec of the file that was ACTUALLY written — read
            // back off the asset, never the spec that was requested.
            // Dimensions · duration · file size · codec — four measurements,
            // so this one stays mono in full.
            if !info.readout.isEmpty {
                Text(info.readout)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            if !hasArtefact {
                noticeBar(app.exportError
                          ?? "The exported file is no longer on this device. Export again to save or share it.")
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            } else if !app.lastExportSavedToPhotos {
                noticeBar("LumaLook couldn't add this to your photo library. In Settings choose \"Add Photos Only\" — the only access it ever asks for.")
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            resultRow
                .padding(.bottom, 12)

            completeBar
        }
    }

    private var resultRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if !app.lastExportSavedToPhotos, app.lastExportImage == nil,
                   let url = shareableURL, url.pathExtension.lowercased() == "mov" {
                    tool("square.and.arrow.down", isSavingToPhotos ? "Saving…" : "To Photos",
                         on: false) {
                        guard !isSavingToPhotos else { return }
                        isSavingToPhotos = true
                        Task {
                            let saved = await app.exporter.saveToPhotos(url: url)
                            app.lastExportSavedToPhotos = saved
                            isSavingToPhotos = false
                            saved ? LumaHaptics.shared.exportSuccess()
                                  : LumaHaptics.shared.failure()
                        }
                    }
                }
                if let gif = shareableGIFURL {
                    ShareLink(item: gif) {
                        VStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.down.forward")
                                .font(.system(size: 17)).frame(height: 20)
                            Text("Share GIF")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 74, height: 46)
                        .contentShape(Rectangle())
                    }
                }
                tool("arrow.uturn.backward", "Export again", on: false) {
                    app.exportError = nil
                    info = ExportOutputInfo()
                    poster = nil
                    phase = .spec
                }
                tool("film.stack", "In editor", on: false) { continueInEditor() }
                tool("photo.on.rectangle", "New source", on: false) { app.path = [.selectClip] }
                tool("plus.square", "New project", on: false) { app.resetToHome() }
            }
            .padding(.horizontal, 16)
        }
        .lumaEdgeFade(leading: 16, trailing: 16)
    }

    private var completeBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(hasArtefact ? "Your file is ready" : "Nothing was produced")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = shareableURL {
                ShareLink(item: url) {
                    Text(app.lastExportImage != nil ? "Share photo" : "Share")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
            } else {
                Button {
                    app.exportError = nil
                    phase = .spec
                } label: {
                    Text("Try again")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Actions

    /// The real thing: persists the spec, runs `app.exporter`, and only moves
    /// to the result when a file (or a graded still) actually exists.
    private func startExport() {
        storedSpec = spec.rawValue
        app.exportError = nil
        app.lookState.splitFraction = nil
        phase = .exporting
        LumaHaptics.shared.tap()
        Task {
            let succeeded: Bool
            if !app.batchItems.isEmpty {
                // Batch grading runs through the SAME exporter as a single
                // clip; only the completion count differs.
                succeeded = await app.runBatchExport(spec: spec) > 0
            } else {
                succeeded = await app.exportCurrentVideo(spec: spec)
            }
            if succeeded { LumaHaptics.shared.exportSuccess() }
            await loadResult()
            phase = succeeded || app.exportError != nil ? .complete : .spec
        }
    }

    private func loadResult() async {
        guard let url = shareableURL, app.lastExportImage == nil else { return }
        async let readout = ExportOutputInfo.load(url: url)
        async let frame = Self.posterFrame(url: url)
        info = await readout
        poster = await frame
    }

    private static func posterFrame(url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        return try? await generator.image(at: .zero).image
    }

    /// Carries the just-graded clip into the timeline with its look baked into
    /// the clip's grade, so the grade room is not a dead end.
    private func continueInEditor() {
        let editor = app.editor
        if editor.clips.isEmpty, let url = app.selectedVideoURL {
            let grade = ClipGrade(
                baseLookName: app.selectedLUT == nil ? app.selectedLook.name : "",
                lutID: app.selectedLUT?.id,
                settings: app.settings)
            Task {
                await editor.addClip(from: url)
                if let id = editor.clips.last?.id {
                    editor.selectedClipID = id
                    editor.setClipGrade(id: id, grade)
                }
            }
        }
        app.path = [.editor]
    }
}
