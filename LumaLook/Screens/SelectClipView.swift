import SwiftUI
import PhotosUI
import AVFoundation

/// Transferable wrapper that copies the picked video into a temp file we own.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            try ownedCopy(of: received)
        }
        // Some library items only advertise a concrete container type.
        FileRepresentation(importedContentType: .quickTimeMovie) { received in
            try ownedCopy(of: received)
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            try ownedCopy(of: received)
        }
    }

    private static func ownedCopy(of received: ReceivedTransferredFile) throws -> PickedVideo {
        let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Picked_\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: received.file, to: destination)
        return PickedVideo(url: destination)
    }
}

struct SelectClipView: View {
    @EnvironmentObject private var app: AppModel
    @State private var mode = "All"
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    /// True once a load has run for a few seconds, which almost always means
    /// Photos is downloading the original from iCloud.
    @State private var loadIsSlow = false
    @State private var loadFailure: LoadFailure?
    /// Bumped on every pick so a slow load can't land after a newer one.
    @State private var loadGeneration = 0
    @State private var showInfo = false
    /// Batch grading needs MULTI-select, which needs the picker's own confirm
    /// bar. Off by default so the common case is one tap.
    @State private var batchMode = false

    /// Next only lights up for an item that actually loaded. While a pick is
    /// loading, or after it fails, there is nothing to grade.
    private var hasSelection: Bool {
        !isLoading && (app.selectedVideoURL != nil || app.selectedImage != nil)
    }

    /// Why the last pick failed, in words the person can act on.
    enum LoadFailure: Equatable {
        case videoTransfer, videoUnreadable, photo

        var title: String {
            switch self {
            case .videoTransfer: return "Couldn't load that video"
            case .videoUnreadable: return "Can't play that video"
            case .photo: return "Couldn't load that photo"
            }
        }

        var detail: String {
            switch self {
            case .videoTransfer, .photo:
                return "If it's stored in iCloud, check you're online and try again."
            case .videoUnreadable:
                return "This file has no video iOS can decode, so it can't be graded. Pick another clip."
            }
        }

        /// A download can succeed second time round; an undecodable file can't.
        var canRetry: Bool { self != .videoUnreadable }
    }

    private enum PickOutcome {
        case video(URL)
        case photo(CIImage)
        case failed(LoadFailure)
    }

    private var pickingPhotos: Bool { mode == "Photos" }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                LumaScreenHeaderBar(title: "Select Clip", trailingIcon: "info.circle",
                                    trailingAction: { showInfo = true })

                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        SegmentPills(options: ["All", "Video", "Photos"], selection: $mode)
                        Button {
                            batchMode.toggle()
                            pickerItems = []
                            LumaHaptics.shared.tap()
                        } label: {
                            Text("Multiple")
                                .font(.luma(size: 13, weight: .semibold))
                                .foregroundStyle(batchMode ? .black : .white.opacity(0.7))
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                                .background(batchMode ? AnyShapeStyle(.white)
                                                      : AnyShapeStyle(LumaTheme.surfaceStrong),
                                            in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.lumaPress)
                        .accessibilityLabel(batchMode ? "Multiple selection on" : "Select multiple")
                    }
                    .padding(.horizontal, 22)

                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().tint(.white)
                            Text(loadIsSlow ? "Still loading…" : "Loading…").foregroundStyle(.white)
                        } else if let loadFailure {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(LumaTheme.orange)
                            Text(loadFailure.title).foregroundStyle(LumaTheme.orange)
                        } else if app.selectedVideoURL != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(LumaTheme.teal)
                            Text("Video selected").foregroundStyle(LumaTheme.teal)
                        } else if app.selectedImage != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(LumaTheme.teal)
                            Text(pickerItems.count > 1 ? "\(pickerItems.count) photos, one grade"
                                                       : "Photo selected")
                                .foregroundStyle(LumaTheme.teal)
                        } else {
                            Text(mode == "All" ? "Whole library: videos and photos"
                                 : (pickingPhotos ? "All Photos" : "All Videos"))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .font(.luma(size: 16, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .lumaCard(cornerRadius: 14)
                    .padding(.horizontal, 22)

                    // The real photo library, embedded in our chrome — every
                    // thumbnail is the user's actual footage.
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: batchMode ? 10 : 1,
                                 matching: mode == "All" ? .any(of: [.videos, .images])
                                          : (pickingPhotos ? .images : .videos),
                                 photoLibrary: .shared()) {
                        Label("Open Library", systemImage: "photo.on.rectangle")
                    }
                    .photosPickerStyle(.inline)
                    // In batch mode the picker's own bottom bar carries the
                    // confirm that commits a multi-selection — hiding it is what
                    // made selection impossible. Single-select needs no confirm,
                    // so the bar stays hidden and our Next bar is the only one.
                    .photosPickerAccessoryVisibility(batchMode ? .visible : .hidden,
                                                     edges: batchMode ? .bottom : .all)
                    .id(batchMode)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Hairline()
                HStack {
                    if isLoading {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text("Preparing…")
                                    .font(.luma(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            if loadIsSlow {
                                Text("Clips in iCloud can take a moment to download.")
                                    .font(.luma(size: 13))
                                    .foregroundStyle(LumaTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    } else if let loadFailure {
                        Text(loadFailure.detail)
                            .font(.luma(size: 14, weight: .semibold))
                            .foregroundStyle(LumaTheme.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(pickerItems.count > 1 && hasSelection ? "\(pickerItems.count) selected for batch"
                             : (hasSelection ? "1 clip selected" : "No clip selected"))
                            .font(.luma(size: 17, weight: .semibold))
                            .foregroundStyle(hasSelection ? .white : LumaTheme.textMuted)
                    }
                    Spacer(minLength: 12)
                    if let loadFailure, loadFailure.canRetry, !isLoading {
                        Button {
                            LumaHaptics.shared.tap()
                            load(pickerItems)
                        } label: {
                            Text("Try again")
                                .font(.luma(.body, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 132, height: 52)
                                .background(LumaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            app.path.append(.applyLook)
                        } label: {
                            Text("Next")
                                .font(.luma(.body, weight: .semibold))
                                .foregroundStyle(LumaTheme.onSignal)
                                .frame(width: 132, height: 52)
                                .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasSelection)
                        .opacity(hasSelection ? 1 : 0.4)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(LumaTheme.background)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 14) {
                Label("What can I pick?", systemImage: "info.circle")
                    .font(.luma(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 26)
                Text("Pick any video or photo from your library, including HEVC, ProRes and Log footage. The first item you pick becomes the live grading preview.")
                    .font(.luma(size: 15))
                    .foregroundStyle(LumaTheme.textSecondary)
                Text("Select up to 10 photos to batch-grade: one grade is dialled in on the first photo, then applied to the whole set on export. Items stored in iCloud may take a moment to download.")
                    .font(.luma(size: 15))
                    .foregroundStyle(LumaTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .presentationDetents([.height(300)])
            .presentationBackground(LumaTheme.background)
        }
        .onChange(of: pickerItems) { _, newItems in
            load(newItems)
        }
    }

    // MARK: Loading

    /// Loads the first picked item as the live preview. The previous pick is
    /// cleared straight away, so Next can never carry on with an old clip
    /// while a new one is loading or after it fails.
    private func load(_ items: [PhotosPickerItem]) {
        loadGeneration += 1
        let generation = loadGeneration
        loadFailure = nil
        loadIsSlow = false
        if app.selectedVideoURL != nil { app.selectedVideoURL = nil }
        if app.selectedImage != nil { app.selectedImage = nil }
        // First item previews; extras queue for batch grading (#10).
        app.batchItems = items.count > 1 ? items : []
        guard let first = items.first else {
            // Deselecting in the picker clears our state too, so the
            // status row and Next button never disagree with the grid.
            isLoading = false
            return
        }
        isLoading = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            if generation == loadGeneration, isLoading { loadIsSlow = true }
        }
        Task {
            let outcome = await Self.resolve(first)
            guard generation == loadGeneration else {
                // A newer pick won; tidy up the copy nobody will use.
                if case .video(let url) = outcome { try? FileManager.default.removeItem(at: url) }
                return
            }
            isLoading = false
            loadIsSlow = false
            switch outcome {
            case .video(let url):
                app.selectedVideoURL = url
            case .photo(let image):
                app.selectedImage = image
            case .failed(let failure):
                loadFailure = failure
                LumaHaptics.shared.failure()
            }
        }
    }

    private static func resolve(_ item: PhotosPickerItem) async -> PickOutcome {
        let isVideo = item.supportedContentTypes.contains {
            $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent)
        }
        guard isVideo else {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                return .photo(image)
            }
            return .failed(.photo)
        }

        var copied: URL?
        if let video = try? await item.loadTransferable(type: PickedVideo.self) {
            copied = video.url
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            // Some assets refuse the file representation; write the raw
            // data out ourselves so the pick still succeeds.
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaLook_Picked_\(UUID().uuidString).\(ext)")
            if (try? data.write(to: url)) != nil { copied = url }
        }
        guard let copied else { return .failed(.videoTransfer) }
        guard await isGradeableVideo(copied) else {
            try? FileManager.default.removeItem(at: copied)
            return .failed(.videoUnreadable)
        }
        return .video(copied)
    }

    /// A file can copy out of Photos and still be useless to us: no video
    /// track at all, or a codec this device can't decode. Catch that here
    /// rather than on a black preview two screens later.
    private static func isGradeableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0
    }
}

/// Shared plain header used by screens that manage their own scroll body.
struct LumaScreenHeaderBar: View {
    let title: String
    var trailingIcon: String? = nil
    var trailingText: String? = nil
    var trailingAction: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LumaHeader(title: title, trailingIcon: trailingIcon, trailingText: trailingText,
                   trailingAction: trailingAction) { dismiss() }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 14)
    }
}
