import SwiftUI
import AVKit
import Pow

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

struct ExportCompleteView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var appeared = false
    @State private var celebrate = 0
    @State private var info = ExportOutputInfo()
    @State private var isSavingToPhotos = false
    /// Real first frame of the exported file, used while the player warms up.
    @State private var poster: CGImage?

    /// There is no success to celebrate without a file (or an in-memory still)
    /// to show for it — every share affordance keys off this.
    ///
    /// A non-nil URL is NOT proof of a file: exports land in the temporary
    /// directory, which iOS purges freely. Checking only the URL rendered a
    /// teal "Export Complete!", a black media card and a ShareLink to nothing.
    private var hasArtefact: Bool {
        app.lastExportImage != nil || shareableURL != nil
    }

    /// The exported file, only if it is still on disk. Every share affordance
    /// (hero ShareLink, brand tiles, Save to Photos) reads this, never the
    /// raw `app.lastExportURL`.
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

    private var statusTint: Color { hasArtefact ? LumaTheme.teal : LumaTheme.orange }

    private var subtitle: String {
        guard hasArtefact else {
            // Distinguish "the render failed" from "the file was purged" —
            // the generic line was shown for both.
            return app.exportError == nil
                ? "The exported file is no longer available on this device. Export again to save or share it."
                : "The export didn't finish."
        }
        return app.lastExportSavedToPhotos ? "Saved to your photos" : "Ready to share below"
    }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                // Lifted out of the ScrollView so the failure stack below can
                // be vertically centred without dragging the Back chevron with
                // it into the middle of the screen.
                HStack {
                    Button { goBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)

                GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(statusTint.opacity(0.13))
                            .frame(width: 128, height: 128)
                        Circle()
                            .strokeBorder(statusTint.opacity(0.35), lineWidth: 1)
                            .frame(width: 128, height: 128)
                        Image(systemName: hasArtefact ? "checkmark" : "exclamationmark.triangle")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(statusTint)
                    }
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                    .changeEffect(.spray(origin: .center) {
                        Image(systemName: "sparkle")
                            .foregroundStyle(LumaTheme.teal)
                    }, value: celebrate)
                    .padding(.top, 18)

                    Text(hasArtefact ? "Export Complete!" : "Export Unavailable")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)

                    // The actual reason the export failed. It was collected in
                    // `app.exportError` and then never shown anywhere, so the
                    // user got a generic line for every distinct failure.
                    if !hasArtefact, let reason = app.exportError {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(LumaTheme.orange.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(LumaTheme.orange.opacity(0.45), lineWidth: 1))
                            .padding(.top, 18)
                    }

                    // Photos access denied/limited: the export still
                    // succeeded — explain and offer the one-tap fix.
                    if hasArtefact, !app.lastExportSavedToPhotos {
                        VStack(spacing: 10) {
                            Text("LumaLook couldn't add this to your photo library. In Settings, choose \"Add Photos Only\" — that's the only access LumaLook ever asks for (it never reads your library, so iOS won't show a Full Access option).")
                                .font(.footnote)
                                .foregroundStyle(LumaTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Turn On \"Add Photos Only\"", systemImage: "gear")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(LumaTheme.accent, in: Capsule())
                            }
                            .buttonStyle(.lumaPress)
                        }
                        .padding(14)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                    }

                    // Centered media card — the frame that was actually
                    // written. Never bundled art: with no artefact there is
                    // no success state to illustrate.
                    if hasArtefact {
                        Group {
                            if let image = app.lastExportImage {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else if let player {
                                VideoPlayer(player: player)
                            } else if let poster {
                                // Player not ready yet — the real first frame,
                                // pulled off the exported file.
                                Image(decorative: poster, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                LumaTheme.surface
                                    .overlay(ProgressView().tint(LumaTheme.textMuted))
                            }
                        }
                        .frame(width: 250, height: 250)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        // The shadow already lifts the preview off the canvas —
                        // a rim on top of it just re-draws the edge.
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                        .padding(.top, 26)
                    }

                    // Delivery spec of the file that was actually written.
                    if !info.readout.isEmpty {
                        TechReadout(info.readout, size: 9, color: LumaTheme.textMuted)
                            .padding(.top, 14)
                    }

                    // The hero CTA exists only when there is a file to hand to
                    // the share sheet. A violet full-width button that opens
                    // nothing is worse than no button at all.
                    if let url = shareableURL {
                        ShareLink(item: url) { shareLabel }
                            .buttonStyle(.lumaPress)
                            .conditionalEffect(.repeat(.shine, every: .seconds(3)), condition: true)
                            .padding(.top, 30)
                    } else if hasArtefact {
                        // Graded still held in memory but never written to
                        // disk — say so instead of shipping a dead button.
                        VStack(spacing: 8) {
                            shareLabel
                                .grayscale(1)
                                .opacity(0.45)
                            Text("This export isn't on disk, so it can't be shared. Export again to get a shareable file.")
                                .font(.footnote)
                                .foregroundStyle(LumaTheme.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Sharing unavailable — this export isn't on disk")
                        .padding(.top, 30)
                    }

                    // Brand tiles are real ShareLinks — the destination apps
                    // live in the system sheet. They were decorations before,
                    // which read as four tappable buttons that did nothing.
                    if let url = shareableURL {
                        HStack(spacing: 22) {
                            ForEach([BrandShareIcon.Kind.instagram, .tiktok, .youtube, .more],
                                    id: \.rawValue) { kind in
                                ShareLink(item: url) { BrandShareIcon(kind: kind) }
                                    .buttonStyle(.lumaPress)
                                    .accessibilityLabel("Share to \(kind.rawValue)")
                            }
                        }
                        .padding(.top, 22)
                    }

                    // The GIF is a separate artefact Photos won't take —
                    // it only ever leaves via the share sheet.
                    if let gif = shareableGIFURL {
                        ShareLink(item: gif) {
                            Label("Share GIF", systemImage: "square.stack.3d.down.forward")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(LumaTheme.cardRaised, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.lumaPress)
                        .padding(.top, 22)
                    }

                    // Retry Photos without leaving the screen — the export is
                    // already on disk, only the library hand-off failed.
                    // Videos only: the still path saves its own UIImage, and
                    // Photos rejects the audio-only M4A outright.
                    if !app.lastExportSavedToPhotos, app.lastExportImage == nil,
                       let url = shareableURL, url.pathExtension.lowercased() == "mov" {
                        GhostCTA(title: isSavingToPhotos ? "Saving…" : "Save to Photos") {
                            guard !isSavingToPhotos else { return }
                            isSavingToPhotos = true
                            Task {
                                let saved = await app.exporter.saveToPhotos(url: url)
                                app.lastExportSavedToPhotos = saved
                                isSavingToPhotos = false
                                if saved { LumaHaptics.shared.exportSuccess() }
                                else { LumaHaptics.shared.failure() }
                            }
                        }
                        .padding(.top, 24)
                    }

                    // Same source, new spec — straight back to the sheet the
                    // user came from rather than out to Home. With no artefact
                    // this is the ONLY thing worth doing, so it carries the
                    // primary weight the (absent) share CTA would have had —
                    // two identical grey ghosts named no recommended step.
                    if hasArtefact {
                        GhostCTA(title: "Export another") { goBack() }
                            .padding(.top, 24)
                    } else {
                        SolidCTA(title: "Try Export Again", icon: "arrow.clockwise") { goBack() }
                            .padding(.top, 26)
                    }

                    // Grade → Edit bridge: carry the just-graded clip into the
                    // editor (with its look baked into the clip's grade) so the
                    // grade room isn't a dead end before the timeline.
                    if app.lastExportImage == nil,
                       app.selectedVideoURL != nil || !app.editor.clips.isEmpty {
                        GhostCTA(title: "Continue in Editor") {
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
                        .padding(.top, 24)
                    }

                    GhostCTA(title: "New Project") {
                        app.resetToHome()
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
                // The failure stack is short; top-aligned it left ~900 pt of
                // empty canvas below and read as a half-loaded page. Give it a
                // minimum of the container height and centre it. A *minimum*
                // (not an exact frame) so it still scrolls at large text sizes.
                // The success stack is tall already, so it stays top-aligned.
                .frame(minHeight: hasArtefact ? nil : proxy.size.height,
                       alignment: .center)
                .frame(maxWidth: .infinity)
                }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .sensoryFeedback(.success, trigger: celebrate)
        .onAppear {
            if app.lastExportImage == nil, let url = shareableURL {
                player = AVPlayer(url: url)
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.1)) {
                appeared = true
            }
            // Nothing to celebrate when nothing was produced.
            guard hasArtefact else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                celebrate += 1
            }
        }
        .task {
            guard let url = shareableURL, app.lastExportImage == nil else { return }
            async let readout = ExportOutputInfo.load(url: url)
            async let frame = Self.posterFrame(url: url)
            info = await readout
            poster = await frame
        }
        .onDisappear { player?.pause() }
    }

    /// Pops to whatever pushed this screen (the editor or the compare screen),
    /// which is where "export another" belongs. `dismiss()` alone strands the
    /// user when the route was pushed onto `app.path` programmatically.
    private func goBack() {
        if !app.path.isEmpty { app.path.removeLast() } else { dismiss() }
    }

    /// First frame of the file that was actually written — a real poster, so
    /// the card never has to fall back to bundled art.
    private static func posterFrame(url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 750, height: 750)
        return try? await generator.image(at: .zero).image
    }

    private var shareLabel: some View {
        Text(app.lastExportImage != nil ? "Share Photo" : "Share Video")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                LinearGradient(colors: [LumaTheme.accent, LumaTheme.accent.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .shadow(color: LumaTheme.accent.opacity(0.35), radius: 16, y: 6)
    }
}

// MARK: - Brand share icons

struct BrandShareIcon: View {
    enum Kind: String {
        case instagram = "Instagram", tiktok = "TikTok", youtube = "YouTube", more = "More"
    }
    let kind: Kind

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LumaTheme.cardRaised)
                .frame(width: 68, height: 68)
                .overlay(glyph)
            Text(kind.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .instagram:
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    LinearGradient(colors: [Color(red: 0.99, green: 0.75, blue: 0.29),
                                            Color(red: 0.91, green: 0.26, blue: 0.43),
                                            Color(red: 0.51, green: 0.23, blue: 0.71)],
                                   startPoint: .bottomLeading, endPoint: .topTrailing),
                    lineWidth: 2.5
                )
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(
                    LinearGradient(colors: [Color(red: 0.91, green: 0.26, blue: 0.43),
                                            Color(red: 0.51, green: 0.23, blue: 0.71)],
                                   startPoint: .bottom, endPoint: .top),
                    lineWidth: 2.5).frame(width: 13, height: 13))
        case .tiktok:
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.0, green: 0.95, blue: 0.92), radius: 0, x: -1.5, y: 0)
                .shadow(color: Color(red: 1.0, green: 0.0, blue: 0.31), radius: 0, x: 1.5, y: 0)
        case .youtube:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                .frame(width: 34, height: 24)
                .overlay(Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white))
        case .more:
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
