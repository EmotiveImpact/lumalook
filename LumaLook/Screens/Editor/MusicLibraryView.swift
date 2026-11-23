import SwiftUI

// MARK: - Music library (Night Lab)

/// The music library: tracks LumaLook makes itself (MusicCatalogue), filtered
/// by mood or search, each row with a beat preview, its BPM and length. Tap a
/// row to audition it (it starts where the drums come in), Use lays it on a
/// music lane with its exact beat grid. Sounds holds the bundled effects and
/// the two pads. Shared by the editor's Audio panel and AudioLibrarySheet, so
/// it has no scroll view of its own.
struct MusicLibraryList: View {
    @ObservedObject var editor: EditorState
    /// Called after a track lands on the timeline.
    var onUsed: (() -> Void)? = nil

    @ObservedObject private var store = MusicLibraryStore.shared
    @StateObject private var preview = AudioPreviewPlayer()
    @State private var showSounds = false
    @State private var moodFilter: String = "all"
    @State private var query = ""
    @State private var auditioning: String?
    @State private var added: String?
    @State private var usingID: String?
    @State private var notice: String?

    private var tracks: [GeneratedTrack] {
        MusicCatalogue.tracks.filter { track in
            switch moodFilter {
            case "all": break
            case "favourites": if !store.isFavourite(track) { return false }
            default: if track.mood.rawValue != moodFilter { return false }
            }
            return track.matches(query)
        }
    }

    private var pads: [BundledAudioEntry] {
        BundledAudioLibrary.entries(category: "music").filter { entry in
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            return q.isEmpty || entry.title.lowercased().contains(q) || "pad".contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switcher
            if showSounds {
                soundsList
            } else {
                musicList
            }
        }
        .onDisappear {
            preview.stop()
            auditioning = nil
        }
    }

    // MARK: Music | Sounds

    /// Text tabs, as in the calm mock: the picked word white, the other grey.
    private var switcher: some View {
        LPanelTabs(labels: ["Music", "Sounds"], selected: showSounds ? 1 : 0, size: 14.5, spacing: 22) { index in
            let sounds = index == 1
            guard sounds != showSounds else { return }
            preview.stop()
            auditioning = nil
            showSounds = sounds
            LumaHaptics.shared.tap()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Music

    @ViewBuilder
    private var musicList: some View {
        LibrarySearchField(text: $query)
        moodChips
        VStack(spacing: 8) {
            ForEach(tracks) { track in
                trackRow(track)
            }
        }
        if tracks.isEmpty {
            Text(moodFilter == "favourites" && query.isEmpty
                 ? "Tap the heart on a track to keep it here."
                 : "Nothing matches. Try a mood, a genre or a BPM like 120.")
                .font(.luma(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
                .padding(.vertical, 6)
        }
        if let notice {
            Text(notice)
                .font(.luma(size: 12.5))
                .foregroundStyle(LumaTheme.textSecondary)
        }
        if !pads.isEmpty, moodFilter == "all" || moodFilter == MusicMood.chill.rawValue {
            LPanelLabel("Pads")
                .padding(.top, 6)
            VStack(spacing: 8) {
                ForEach(pads) { entry in
                    soundRow(entry)
                }
            }
        }
        Text("Every track is made by Lumalook, free to use in anything you post.")
            .font(.luma(size: 12))
            .foregroundStyle(LumaTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                LibraryChip(title: "All", selected: moodFilter == "all") { moodFilter = "all" }
                LibraryChip(title: "Favourites", icon: "heart.fill",
                            selected: moodFilter == "favourites") { moodFilter = "favourites" }
                ForEach(MusicMood.allCases, id: \.self) { mood in
                    LibraryChip(title: mood.label, selected: moodFilter == mood.rawValue) {
                        moodFilter = mood.rawValue
                    }
                }
            }
            .padding(.trailing, 20)
        }
        .lumaEdgeFade(leading: 0, trailing: 16)
    }

    private func trackRow(_ track: GeneratedTrack) -> some View {
        let isCurrent = auditioning == track.id
        let rendering = store.isRendering(track)
        return MusicTrackRow(track: track,
                             isPlaying: isCurrent && preview.isPlaying,
                             isLoading: isCurrent && rendering,
                             isRendering: rendering || usingID == track.id,
                             isFavourite: store.isFavourite(track),
                             isAdded: added == track.id,
                             preview: preview,
                             onAudition: { audition(track) },
                             onUse: { use(track) },
                             onFavourite: {
                                 store.toggleFavourite(track)
                                 LumaHaptics.shared.tap()
                             })
    }

    private func audition(_ track: GeneratedTrack) {
        if auditioning == track.id, preview.isPlaying || store.isRendering(track) {
            preview.stop()
            auditioning = nil
            return
        }
        // Two players over one pair of ears is noise.
        if editor.isPlaying { editor.togglePlayback() }
        preview.stop()
        auditioning = track.id
        notice = nil
        LumaHaptics.shared.tap()
        Task {
            guard let url = await store.prepare(track) else {
                if auditioning == track.id { auditioning = nil }
                notice = "Couldn't make \(track.name) just now. Try again."
                return
            }
            // The listener may have moved on while the track was rendering.
            guard auditioning == track.id else { return }
            preview.play(url, from: track.previewStart)
        }
    }

    private func use(_ track: GeneratedTrack) {
        guard usingID != track.id,
              !store.isRendering(track) || auditioning == track.id else { return }
        LumaHaptics.shared.tap()
        notice = nil
        usingID = track.id
        Task {
            let ok = await store.use(track, in: editor)
            if usingID == track.id { usingID = nil }
            if ok {
                preview.stop()
                auditioning = nil
                added = track.id
                LumaHaptics.shared.exportSuccess()
                onUsed?()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if added == track.id { added = nil }
            } else {
                notice = "Couldn't add \(track.name). Try again."
            }
        }
    }

    // MARK: Sounds

    @ViewBuilder
    private var soundsList: some View {
        VStack(spacing: 8) {
            ForEach(BundledAudioLibrary.entries(category: "sfx")) { entry in
                soundRow(entry)
            }
        }
        if BundledAudioLibrary.entries(category: "sfx").isEmpty {
            Text("No sounds found in this build.")
                .font(.luma(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
        }
    }

    private func soundRow(_ entry: BundledAudioEntry) -> some View {
        let playing = auditioning == entry.id && preview.isPlaying
        return HStack(spacing: 12) {
            Button {
                if playing {
                    preview.stop()
                    auditioning = nil
                } else if let url = BundledAudioLibrary.url(for: entry) {
                    if editor.isPlaying { editor.togglePlayback() }
                    preview.play(url)
                    auditioning = entry.id
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(MusicTrackRow.artFill)
                    if playing {
                        PlayingBars(colour: .white)
                    } else {
                        Image(systemName: entry.category == "sfx" ? "sparkles" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LumaTheme.textPrimary)
                    }
                }
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel(playing ? "Stop \(entry.title)" : "Play \(entry.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
                Text(entry.category == "sfx" ? "Sound effect" : "Pad · loop")
                    .font(.luma(size: 12))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            Spacer(minLength: 6)
            Text(String(format: "%.1fs", entry.duration))
                .font(.luma(size: 12.5, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
            Button {
                guard let url = BundledAudioLibrary.url(for: entry),
                      let imported = editor.importMusicFile(from: url) else { return }
                LumaHaptics.shared.tap()
                Task {
                    await editor.addAudioTrack(importedURL: imported, title: entry.title,
                                               kind: entry.category == "sfx" ? .sfx : .music)
                }
            } label: {
                Text("Add")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel("Add \(entry.title)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(minHeight: 56)
        .background(MusicTrackRow.rowFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Row

/// One generated track, calm (mock v2): a quiet art tile (play, loading or the
/// playing bars), name, genre · BPM · length, and a two-bar beat preview that
/// lights up as the audition plays. The track's colour stays as a small
/// accent: a dot on the tile, the beat preview and the playing bars. Then a
/// favourite heart and Use, which becomes the main action while you listen.
struct MusicTrackRow: View {
    let track: GeneratedTrack
    let isPlaying: Bool
    let isLoading: Bool
    let isRendering: Bool
    let isFavourite: Bool
    let isAdded: Bool
    @ObservedObject var preview: AudioPreviewPlayer
    let onAudition: () -> Void
    let onUse: () -> Void
    let onFavourite: () -> Void

    private var isActive: Bool { isPlaying || isLoading }

    /// The art tile and the row, as in the mock (#232429 on white at 5%).
    static let artFill = Color(hex: 0x232429)
    static let rowFill = Color.white.opacity(0.05)

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAudition) {
                HStack(spacing: 12) {
                    artwork
                    details
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Stop \(track.name)" : "Play \(track.name)")

            Spacer(minLength: 2)
            favouriteButton
            useButton
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(isActive ? Color.white.opacity(0.09) : Self.rowFill,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Self.artFill)
            if isLoading {
                ProgressView().controlSize(.small).tint(.white)
            } else if isPlaying {
                PlayingBars(colour: track.colour)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .frame(width: 46, height: 46)
        // The track's colour, kept small.
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(track.colour)
                .frame(width: 7, height: 7)
                .padding(5)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.name)
                .font(.luma(size: 14.5, weight: .semibold))
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
            Text("\(track.genre.label) · \(track.bpmLabel) · \(track.lengthLabel)")
                .font(.luma(size: 12))
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            beatPreview
                .frame(height: 12)
        }
    }

    private var beatPreview: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { _ in
            BeatPreviewBars(values: track.beatPreview, colour: track.colour,
                            progress: isPlaying ? cycleProgress : nil)
        }
    }

    /// Where the audition is inside the two bars the preview draws.
    private var cycleProgress: Double {
        let cycle = track.barSeconds * 2
        guard cycle > 0 else { return 0 }
        return preview.currentTime.truncatingRemainder(dividingBy: cycle) / cycle
    }

    private var favouriteButton: some View {
        Button(action: onFavourite) {
            Image(systemName: isFavourite ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFavourite ? LumaTheme.textPrimary : LumaTheme.textMuted)
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(isFavourite ? "Remove from favourites" : "Add to favourites")
    }

    /// The track you are listening to is the one you are about to use, so
    /// its Use steps up to the white confirm pill. It is not the signal: the
    /// library also sits inline under the editor, where Export is the one
    /// main action. Every other Use stays quiet glass.
    @ViewBuilder
    private var useButton: some View {
        if isActive && !isAdded && !(isRendering && !isLoading) {
            LPanelConfirmButton(title: "Use", action: onUse)
                .frame(minWidth: 58)
                .accessibilityLabel("Use \(track.name)")
        } else {
            quietUseButton
        }
    }

    private var quietUseButton: some View {
        Button(action: onUse) {
            HStack(spacing: 5) {
                if isAdded {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Added")
                } else if isRendering && !isLoading {
                    ProgressView().controlSize(.mini).tint(LumaTheme.textPrimary)
                } else {
                    Text("Use")
                }
            }
            .font(.luma(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 14)
            .frame(minWidth: 58)
            .frame(height: 30)
            .background(Color.white.opacity(0.09), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Use \(track.name)")
    }
}

// MARK: - Parts

/// Two bars of the groove as rounded bars; the played part lights up.
struct BeatPreviewBars: View {
    let values: [Float]
    let colour: Color
    var progress: Double? = nil

    var body: some View {
        Canvas { context, size in
            let n = values.count
            guard n > 0 else { return }
            let gap: CGFloat = 1.5
            let width = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for i in 0..<n {
                let height = max(2, size.height * CGFloat(values[i]))
                let rect = CGRect(x: CGFloat(i) * (width + gap),
                                  y: (size.height - height) / 2,
                                  width: width, height: height)
                var lit = false
                if let progress { lit = Double(i) / Double(n) <= progress }
                let shade: Color = progress == nil ? colour.opacity(0.45) : (lit ? colour : colour.opacity(0.22))
                context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                             with: .color(shade))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Four bouncing bars: the "now playing" mark.
struct PlayingBars: View {
    let colour: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(colour)
                        .frame(width: 3, height: Self.height(i, t))
                }
            }
            .frame(height: 18)
        }
        .accessibilityHidden(true)
    }

    private static func height(_ i: Int, _ t: Double) -> CGFloat {
        let speeds: [Double] = [7.1, 9.3, 6.2, 8.4]
        let phase = Double(i) * 1.3
        let v = (sin(t * speeds[i % 4] + phase) + 1) / 2
        return CGFloat(5 + v * 13)
    }
}

/// Mood filter: a word, white on a little glass when chosen, grey otherwise.
/// No rings and no outlines (calm mock v2).
struct LibraryChip: View {
    let title: String
    var icon: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        LPanelFilterTab(title: title, icon: icon, isOn: selected) {
            action()
            LumaHaptics.shared.tap()
        }
    }
}

/// Search box for the library.
struct LibrarySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
            TextField("", text: $text,
                      prompt: Text("Search moods, genres or BPM").foregroundColor(LumaTheme.textMuted))
                .font(.luma(size: 14))
                .foregroundStyle(LumaTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LPanelStyle.glass, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
