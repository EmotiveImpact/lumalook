import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import CoreImage

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

/// Select clips: the app's own picker over the photo library. A newest-first
/// grid with Videos / Photos / All, numbered picks in signal yellow, and a
/// tray with the picks in order, the running total and Start editing.
///
/// Hand-off is unchanged from the system picker it replaces: for the grade
/// flow the first pick becomes `selectedVideoURL` or `selectedImage` (a file
/// copied into temp) and extra picks queue in `batchItems`; for editing
/// (`SelectClipIntent.edit`) the picks become the clips of a new project.
struct SelectClipView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @StateObject private var library = RollLibrary()

    @State private var intent: SelectClipIntent = .grade
    @State private var templateID: String?
    @State private var didBegin = false
    @State private var filter = RollFilter.all.rawValue
    @State private var picks: [RollTile] = []
    @State private var isPreparing = false
    @State private var prepareStep = 0
    @State private var prepareTotal = 1
    @State private var failure: SelectClipFailure?
    @State private var prepareTask: Task<Void, Never>?

    private let gridSpacing: CGFloat = 2
    private let gridInset: CGFloat = 3

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    var body: some View {
        ZStack {
            LumaTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                content
            }
        }
        .safeAreaInset(edge: .bottom) {
            if library.isBrowsable {
                tray
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: begin)
        .onDisappear { prepareTask?.cancel() }
        .onChange(of: filter) { _, newValue in
            library.setFilter(RollFilter(rawValue: newValue) ?? .all)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.recheckAccess() }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            HStack {
                closeButton
                Spacer()
                if library.isBrowsable {
                    albumsMenu
                }
            }
            if library.isBrowsable {
                titleMenu
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Close")
    }

    @ViewBuilder private var albumButtons: some View {
        ForEach(library.albums) { album in
            Button {
                library.select(album)
                LumaHaptics.shared.tap()
            } label: {
                if album.id == library.album.id {
                    Label(album.title, systemImage: "checkmark")
                } else {
                    Text(album.title)
                }
            }
        }
    }

    private var titleMenu: some View {
        Menu {
            albumButtons
        } label: {
            HStack(spacing: 4) {
                Text(library.album.title)
                    .font(.luma(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .frame(maxWidth: 200)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Album, \(library.album.title)")
    }

    private var albumsMenu: some View {
        Menu {
            albumButtons
        } label: {
            Text("Albums")
                .font(.luma(size: 15, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch library.access {
        case .asking:
            RollAskingView()
        case .denied:
            RollDeniedView(openSettings: { openSystemSettings() }, notNow: { close() })
        case .full, .limited, .samples:
            browser
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            SegmentPills(options: RollFilter.allCases.map { $0.rawValue }, selection: $filter)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            if library.showsLimitedRow {
                limitedRow
            }
            if library.count == 0 {
                emptyLibrary
            } else {
                grid
            }
        }
    }

    /// Limited access: one slim row that opens the system's limited picker.
    private var limitedRow: some View {
        Button {
            LumaHaptics.shared.tap()
            library.presentLimitedPicker()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                Text("Allow access to more photos")
                    .font(.luma(size: 14, weight: .medium))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .lumaPanel(LumaTheme.card, cornerRadius: 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var emptyLibrary: some View {
        let limited = library.access == .limited
        var action: (() -> Void)? = nil
        if limited {
            action = { library.presentLimitedPicker() }
        }
        let title: String
        switch library.filter {
        case .videos: title = "No videos here yet"
        case .photos: title = "No photos here yet"
        case .all: title = "Nothing here yet"
        }
        let message = limited
            ? "Only the photos you've shared with LumaLook show here."
            : "Clips and photos you shoot or save will show up here."
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            LumaEmptyState(icon: "photo.on.rectangle", title: title, message: message,
                           actionTitle: limited ? "Choose photos" : nil, action: action)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geo in
            ScrollView {
                gridContent(width: geo.size.width)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func gridContent(width: CGFloat) -> some View {
        let side = max(40, (width - gridInset * 2 - gridSpacing * 2) / 3)
        let pixelSide = max(240, side * displayScale)
        let order = pickOrder
        return LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(0..<library.count, id: \.self) { index in
                cell(at: index, pixelSide: pixelSide, order: order)
            }
        }
        .padding(.horizontal, gridInset)
        .padding(.bottom, 12)
    }

    private func cell(at index: Int, pixelSide: CGFloat, order: [String: Int]) -> some View {
        let tile = library.tile(at: index)
        return RollGridCell(tile: tile, number: order[tile.id], pixelSide: pixelSide,
                            manager: library.thumbnailManager) {
            toggle(tile)
        }
        // Cells are indexed; a new fetch puts a different asset at the same
        // index, so the asset id resets the cell's loaded thumbnail.
        .id(tile.id)
        .onAppear { library.prefetch(around: index, pixelSide: pixelSide) }
    }

    /// Asset id to its 1-based pick number.
    private var pickOrder: [String: Int] {
        var order: [String: Int] = [:]
        for (offset, tile) in picks.enumerated() {
            order[tile.id] = offset + 1
        }
        return order
    }

    // MARK: Tray

    private var tray: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                trayStatus
                Spacer(minLength: 8)
                clearButton
            }
            .lineLimit(1)
            trayDetail
            if !picks.isEmpty {
                pickStrip
            }
            startButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumaTheme.panel.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Hairline() }
    }

    @ViewBuilder private var trayStatus: some View {
        if isPreparing {
            Text(preparingTitle)
                .font(.luma(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.textPrimary)
        } else if let failure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumaTheme.orange)
            Text(failure.title)
                .font(.luma(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.orange)
        } else if picks.isEmpty {
            Text(emptyTrayTitle)
                .font(.luma(size: 15, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
        } else {
            Text(pickCountTitle)
                .font(.luma(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.textPrimary)
            if totalSeconds > 0 {
                Text("· \(RollClock.string(totalSeconds))")
                    .font(.luma(size: 15, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
            }
        }
    }

    @ViewBuilder private var clearButton: some View {
        if !picks.isEmpty && !isPreparing {
            Button {
                picks.removeAll()
                failure = nil
                LumaHaptics.shared.tap()
            } label: {
                Text("Clear")
                    .font(.luma(size: 14, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .buttonStyle(.lumaPress)
        }
    }

    @ViewBuilder private var trayDetail: some View {
        if isPreparing {
            ProgressView(value: overallProgress)
                .progressViewStyle(.linear)
                .tint(LumaTheme.signal)
        } else if let failure {
            Text(failure.detail)
                .font(.luma(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The picks in order. Tapping one takes it out.
    private var pickStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(picks) { tile in
                    Button { remove(tile) } label: {
                        RollPickThumb(tile: tile, pixelSide: 44 * displayScale,
                                      manager: library.thumbnailManager)
                    }
                    .buttonStyle(.lumaPress)
                    .accessibilityLabel("Remove from picks")
                }
            }
        }
        .frame(height: 44)
        .disabled(isPreparing)
    }

    private var startButton: some View {
        let lit = canStart || isPreparing
        return Button { startEditing() } label: {
            HStack(spacing: 8) {
                if isPreparing {
                    ProgressView().tint(LumaTheme.onSignal)
                }
                Text(isPreparing ? "Preparing…" : "Start editing")
                    .font(.luma(size: 16, weight: .semibold))
                    .tracking(-0.2)
            }
            // Disabled reads as a quiet grey control rather than a dimmed
            // yellow, which turns muddy brown.
            .foregroundStyle(lit ? LumaTheme.onSignal : LumaTheme.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(lit ? LumaTheme.signal : LumaTheme.control,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(!canStart)
    }

    // MARK: Tray copy

    private var canStart: Bool { !picks.isEmpty && !isPreparing }

    private var pendingTemplate: VideoTemplate? {
        guard let templateID else { return nil }
        return TemplateLibrary.all.first { $0.id == templateID }
    }

    private var emptyTrayTitle: String {
        if let template = pendingTemplate {
            return "Pick \(template.slots.count) clips for \(template.name)"
        }
        return intent == .photo ? "Tap photos to pick them" : "Tap clips to pick them"
    }

    private var pickCountTitle: String {
        let count = picks.count
        let allPhotos = picks.allSatisfy { !$0.isVideo }
        let noun: String
        if allPhotos {
            noun = count == 1 ? "photo" : "photos"
        } else {
            noun = count == 1 ? "clip" : "clips"
        }
        return "\(count) \(noun)"
    }

    /// Video time, plus a photo clip's default three seconds when the picks
    /// are going into the editor.
    private var totalSeconds: Double {
        var total = 0.0
        for tile in picks {
            if tile.isVideo {
                total += tile.duration
            } else if intent == .edit {
                total += 3
            }
        }
        return total
    }

    private var preparingTitle: String {
        var title = prepareTotal > 1 ? "Loading \(max(1, prepareStep)) of \(prepareTotal)" : "Preparing"
        let progress = library.downloadProgress
        if progress > 0, progress < 1 {
            title += " · iCloud \(Int(progress * 100))%"
        }
        return title
    }

    private var overallProgress: Double {
        let total = Double(max(1, prepareTotal))
        let current = min(max(library.downloadProgress, 0), 1)
        let done = Double(max(0, prepareStep - 1)) + current
        return min(1, max(0, done / total))
    }

    // MARK: Actions

    private func begin() {
        guard !didBegin else { return }
        didBegin = true
        intent = app.selectClipIntent
        templateID = app.pendingTemplateID
        if templateID != nil { intent = .edit }
        // One shot: the next plain push of .selectClip is the grade flow.
        app.selectClipIntent = .grade
        app.pendingTemplateID = nil
        let startFilter = intent.defaultFilter
        filter = startFilter.rawValue
        Task {
            await library.start(filter: startFilter)
            if library.usesSamples, picks.isEmpty {
                picks = library.seedPicks
            }
        }
    }

    private func toggle(_ tile: RollTile) {
        guard tile.isPickable, !isPreparing else { return }
        failure = nil
        if let index = picks.firstIndex(where: { $0.id == tile.id }) {
            // Later picks renumber themselves: the badge is the position.
            picks.remove(at: index)
            LumaHaptics.shared.tap()
            return
        }
        guard picks.count < intent.maxPicks else {
            LumaHaptics.shared.failure()
            app.importToast = "Up to \(intent.maxPicks) at a time"
            return
        }
        picks.append(tile)
        LumaHaptics.shared.tap()
    }

    private func remove(_ tile: RollTile) {
        guard !isPreparing else { return }
        picks.removeAll { $0.id == tile.id }
        failure = nil
        LumaHaptics.shared.tap()
    }

    private func close() {
        prepareTask?.cancel()
        dismiss()
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func startEditing() {
        guard canStart else { return }
        LumaHaptics.shared.tap()
        let chosen = picks
        let toEditor = intent == .edit
        failure = nil
        library.downloadProgress = 0
        prepareStep = 0
        prepareTotal = toEditor ? chosen.count : 1
        isPreparing = true
        prepareTask = Task {
            if toEditor {
                await deliverToEditor(chosen)
            } else {
                await deliverToGrade(chosen)
            }
            isPreparing = false
        }
    }

    private func fail(_ reason: SelectClipFailure) {
        failure = reason
        LumaHaptics.shared.failure()
    }

    /// A pick as a file, the same form the system picker used to hand over.
    private func resolve(_ tile: RollTile) async -> RollPick {
        if let sample = tile.sample {
            guard let url = sample.url else { return .failed(.photo) }
            return .photo(url)
        }
        guard let asset = tile.asset else { return .failed(.photo) }
        library.downloadProgress = 0
        let model = library
        return await RollResolver.resolve(asset) { value in
            Task { @MainActor in
                model.downloadProgress = value
            }
        }
    }

    /// Grade flow, exactly as before: the first pick previews in the grade
    /// room; with more than one pick, all of them queue for batch grading.
    private func deliverToGrade(_ chosen: [RollTile]) async {
        guard let first = chosen.first else { return }
        prepareStep = 1
        let resolved = await resolve(first)
        guard !Task.isCancelled else { return }
        switch resolved {
        case .video(let url):
            if app.selectedImage != nil { app.selectedImage = nil }
            app.selectedVideoURL = url
        case .photo(let url):
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                fail(.photo)
                return
            }
            app.selectedImage = image
        case .failed(let reason):
            fail(reason)
            return
        }
        let batch = chosen.compactMap { $0.asset }.map { PhotosPickerItem(itemIdentifier: $0.localIdentifier) }
        app.batchItems = batch.count > 1 ? batch : []
        app.batchPreviewItemID = batch.count > 1 ? first.asset?.localIdentifier : nil
        guard app.path.last == .selectClip else { return }
        app.path.append(.applyLook)
    }

    /// Editing: every pick becomes a clip of a new project, in pick order,
    /// then a template chosen beforehand restyles the cut.
    private func deliverToEditor(_ chosen: [RollTile]) async {
        var files: [RollPick] = []
        var failedCount = 0
        for (offset, tile) in chosen.enumerated() {
            prepareStep = offset + 1
            let resolved = await resolve(tile)
            if Task.isCancelled { return }
            if case .failed = resolved {
                failedCount += 1
            } else {
                files.append(resolved)
            }
        }
        guard !files.isEmpty else {
            fail(.nothingLoaded)
            return
        }
        let editor = app.editor
        editor.startNewProject()
        for file in files {
            switch file {
            case .video(let url):
                await editor.addClip(from: url)
            case .photo(let url):
                await editor.addPhotoClip(from: url)
            case .failed:
                break
            }
        }
        if let template = pendingTemplate {
            editor.applyTemplate(template)
        }
        if failedCount > 0 {
            app.importToast = failedCount == 1 ? "1 clip couldn't load" : "\(failedCount) clips couldn't load"
        }
        guard app.path.last == .selectClip else { return }
        // The editor takes the picker's place, so back from the editor goes
        // where the picker came from and a second Start editing can't make a
        // duplicate project.
        var path = app.path
        path.removeLast()
        path.append(.editor)
        app.path = path
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
