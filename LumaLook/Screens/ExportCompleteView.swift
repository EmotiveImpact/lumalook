import SwiftUI
import UIKit
import AVKit

/// Real metadata read back off the file that was actually written — never the
/// spec that was requested, so a preset the encoder substituted can't be
/// reported as something it isn't.
struct ExportOutputInfo: Equatable {
    var dimensions: String?      // "3840 × 2160"
    var duration: String?        // "00:18"
    var fileSize: String?        // "142 MB"
    var codec: String?           // "H.265"

    /// Mono delivery line for the readout; nil components are simply omitted.
    var readout: String {
        [dimensions, duration, fileSize, codec].compactMap { $0 }.joined(separator: " · ")
    }

    static func load(url: URL) async -> ExportOutputInfo {
        var info = ExportOutputInfo()

        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let bytes {
            let mb = Double(bytes) / 1_000_000
            info.fileSize = mb >= 1000 ? String(format: "%.1f GB", mb / 1000)
                                       : String(format: "%.0f MB", mb)
        }

        let asset = AVURLAsset(url: url)
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            info.duration = String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return info
        }
        if let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            // Portrait exports carry the rotation in the transform, so the
            // natural size alone would report a landscape frame.
            let oriented = size.applying(transform)
            info.dimensions = "\(Int(abs(oriented.width))) × \(Int(abs(oriented.height)))"
        }
        if let descs = try? await track.load(.formatDescriptions), let desc = descs.first {
            switch CMFormatDescriptionGetMediaSubType(desc) {
            case kCMVideoCodecType_HEVC: info.codec = "H.265"
            case kCMVideoCodecType_H264: info.codec = "H.264"
            default: info.codec = nil
            }
        }
        return info
    }
}

// MARK: - Export complete

/// The result of a render, in the shipping design language proved by
/// the retired Design Lab export preview: THE IMAGE IS THE INTERFACE. The file that was actually
/// written owns the top of the screen uncovered — it plays if it is a video,
/// it is the real poster frame while the player warms up, and it is the graded
/// source frame when nothing was produced. Everything else lives in a drawer
/// beneath it: what was written (mono, read off the asset), what went wrong
/// (verbatim), the actions as an unboxed tool row, and one calm instruction bar
/// whose single filled button is Share.
///
/// Monochrome throughout — no teal tick, no orange failure slab, no branded
/// share tiles, no confetti. Mono type is reserved for the measurements.
struct ExportCompleteView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var info = ExportOutputInfo()
    @State private var isSavingToPhotos = false
    /// Real first frame of the exported file, used while the player warms up.
    @State private var poster: CGImage?
    /// The graded SOURCE frame, rendered once — shown only when the export
    /// produced nothing, so the failure screen still shows the user's picture
    /// rather than a black box. Never bundled art.
    @State private var sourceFrame: CGImage?

    /// There is no success to report without a file (or an in-memory still) to
    /// show for it — every share affordance keys off this.
    ///
    /// A non-nil URL is NOT proof of a file: exports land in the temporary
    /// directory, which iOS purges freely. Checking only the URL rendered a
    /// success headline, a black media card and a ShareLink to nothing.
    private var hasArtefact: Bool {
        app.lastExportImage != nil || shareableURL != nil
    }

    /// The exported file, only if it is still on disk. Every share affordance
    /// (the bar's Share, Save to Photos) reads this, never `app.lastExportURL`.
    private var shareableURL: URL? {
        guard let url = app.lastExportURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Same existence rule for the GIF — a separate artefact in the same
    /// purgeable directory.
    private var shareableGIFURL: URL? {
        guard let url = app.lastExportGIFURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The captions file saved beside the export when they were not burned
    /// in, under the same rule.
    private var shareableCaptionsURL: URL? {
        guard let url = app.exporter.lastCaptionsURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                media
                drawer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .animation(.easeOut(duration: 0.18), value: app.lastExportSavedToPhotos)
        .onAppear {
            if app.lastExportImage == nil, let url = shareableURL {
                player = AVPlayer(url: url)
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        guard let url = shareableURL, app.lastExportImage == nil else {
            // Nothing was written — render the graded source once so the
            // failure screen is still the user's picture, not a void.
            if !hasArtefact, sourceFrame == nil, let frame = app.previewFrame {
                let graded = LookPipeline.shared.apply(state: app.lookState, to: frame)
                sourceFrame = LookPipeline.shared.context.createCGImage(graded, from: frame.extent)
            }
            return
        }
        async let readout = ExportOutputInfo.load(url: url)
        async let frame = Self.posterFrame(url: url)
        info = await readout
        poster = await frame
    }

    // MARK: - Media — uncovered, the whole point of the screen

    private var media: some View {
        GeometryReader { geo in
            Group {
                if let image = app.lastExportImage {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else if let player {
                    // The export PLAYS. Watching what you made is the reward.
                    VideoPlayer(player: player)
                } else if let poster {
                    // Player not ready yet — the real first frame, pulled off
                    // the exported file.
                    Image(decorative: poster, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else if let sourceFrame {
                    Image(decorative: sourceFrame, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else {
                    LumaTheme.surface
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // clipShape clips PIXELS, not TOUCHES: a .fill image overflows its
            // fixed frame and would keep taking taps outside it.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: - Drawer

    private var drawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(hasArtefact ? "Export complete" : "Export unavailable")
                    .font(.luma(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let status = photosStatus {
                    Text(status)
                        .font(.luma(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // The delivery spec of the file that was ACTUALLY written — read
            // back off the asset, never the spec that was requested.
            // Dimensions · duration · file size · codec — four measurements,
            // so this line stays mono in full.
            if !info.readout.isEmpty {
                Text(info.readout)
                    .font(.luma(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            notice
            resultRow
                .padding(.bottom, 12)
            completeBar
        }
    }

    private var photosStatus: String? {
        guard hasArtefact, photosEligible else { return nil }
        return app.lastExportSavedToPhotos ? "Saved to Photos" : "Not in Photos"
    }

    /// Photos only ever takes the video or the still. It rejects the
    /// audio-only M4A outright, so reporting "not in Photos" for one — and
    /// offering a Settings trip to fix it — would be an instruction that
    /// cannot possibly help.
    private var photosEligible: Bool {
        if app.lastExportImage != nil { return true }
        guard let url = shareableURL else { return false }
        return ["mov", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }

    /// One notice at a time, most consequential first. The verbatim reason the
    /// export failed was collected in `app.exportError` and must be shown —
    /// a generic line for every distinct failure teaches the user nothing.
    @ViewBuilder
    private var notice: some View {
        if !hasArtefact {
            // Distinguish "the render failed" (with its real reason) from
            // "the file was purged" — one line was shown for both.
            noticeBar(app.exportError
                      ?? "The exported file is no longer on this device. Export again to save or share it.")
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
        } else if !app.lastExportSavedToPhotos, photosEligible {
            // The export itself succeeded; only the library hand-off was
            // refused. Explain it, and put the fix in the row below.
            noticeBar("LumaLook couldn't add this to your photo library. In Settings choose \"Add Photos Only\" — that's the only access it ever asks for, so iOS won't offer Full Access.")
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
        } else if shareableURL == nil {
            // A graded still held in memory that never reached disk.
            noticeBar("This export isn't on disk, so it can't be shared. Export again to get a shareable file.")
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
        }
    }

    /// A sentence on a raised surface. No orange slab, no warning triangle —
    /// the words are the warning.
    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 12.5))
            .foregroundStyle(.white.opacity(0.85))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(LumaTheme.surfaceStrong,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Actions — icon over label, unboxed, the last item clipped

    private var resultRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Retry Photos without leaving the screen — the export is
                // already on disk, only the library hand-off failed. Videos
                // only: the still path saves its own UIImage, and Photos
                // rejects the audio-only M4A outright.
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
                // The one-tap fix for the notice directly above.
                if hasArtefact, !app.lastExportSavedToPhotos, photosEligible {
                    tool("gearshape", "Settings", on: false) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                // The GIF is a separate artefact Photos won't take — it only
                // ever leaves via the share sheet.
                if let gif = shareableGIFURL {
                    ShareLink(item: gif) {
                        VStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.down.forward")
                                .font(.system(size: 17)).frame(height: 20)
                            Text("Share GIF")
                                .font(.luma(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 74, height: 46)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share GIF")
                }
                // Captions left out of the picture travel as an .srt.
                if let captions = shareableCaptionsURL {
                    ShareLink(item: captions) {
                        VStack(spacing: 5) {
                            Image(systemName: "captions.bubble")
                                .font(.system(size: 17)).frame(height: 20)
                            Text("Captions")
                                .font(.luma(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 74, height: 46)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share captions")
                }
                // Same source, new spec — straight back to the sheet the user
                // came from rather than out to Home.
                tool("arrow.uturn.backward", "Export another", on: false) { goBack() }
                // Grade → Edit bridge: carry the just-graded clip into the
                // timeline so the grade room isn't a dead end. Only drawn when
                // there is actually a clip to carry.
                if app.lastExportImage == nil,
                   app.selectedVideoURL != nil || !app.editor.clips.isEmpty {
                    tool("film.stack", "In editor", on: false) { continueInEditor() }
                }
                tool("photo.on.rectangle", "New source", on: false) { app.path = [.selectClip] }
                // `resetToHome()` alone only clears navigation and the grade
                // source — the previous project stayed loaded in the editor, so
                // a button labelled "New project" neither created nor cleared
                // one. Start the project first, THEN reset navigation.
                tool("plus.square", "New project", on: false) {
                    app.editor.startNewProject()
                    app.resetToHome()
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
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.7 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // No box, no chip, no pill — separation is by value alone.
            .foregroundStyle(on ? .white : .white.opacity(0.5))
            .frame(width: 74, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.28)
    }

    // MARK: - The calm instruction bar

    private var completeBar: some View {
        HStack(spacing: 0) {
            Button { goBack() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Spacer(minLength: 8)
            Text(barSentence)
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            // The one filled button in the language. It exists only when there
            // is a file to hand to the share sheet — a full-width button that
            // opens nothing is worse than no button at all.
            if let url = shareableURL {
                ShareLink(item: url) {
                    filledLabel(app.lastExportImage != nil ? "Share photo" : "Share")
                }
                .buttonStyle(.lumaPress)
            } else {
                Button { goBack() } label: { filledLabel("Try again") }
                    .buttonStyle(.lumaPress)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func filledLabel(_ title: String) -> some View {
        Text(title)
            .font(.luma(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
    }

    private var barSentence: String {
        if shareableURL != nil { return "Your file is ready" }
        if hasArtefact { return "Not on disk — export again" }
        return "Nothing was produced"
    }

    // MARK: - Navigation

    /// Pops to whatever pushed this screen (the editor or the compare screen),
    /// which is where "export another" belongs. `dismiss()` alone strands the
    /// user when the route was pushed onto `app.path` programmatically.
    private func goBack() {
        if !app.path.isEmpty { app.path.removeLast() } else { dismiss() }
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

    /// First frame of the file that was actually written — a real poster, so
    /// the hero never has to fall back to bundled art.
    private static func posterFrame(url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        return try? await generator.image(at: .zero).image
    }
}
