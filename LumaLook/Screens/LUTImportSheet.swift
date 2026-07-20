import SwiftUI
import CoreImage

/// A picked file URL, wrapped so `.sheet(item:)` can drive the import sheet
/// (URL is not Identifiable, and presenting on a Bool loses the URL).
struct PickedFile: Identifiable, Equatable {
    let url: URL
    var origin: String = "Files"
    var id: String { url.absoluteString }
}

/// G2 — the import sheet every LUT passes through before it enters the
/// library. Validates the file, names the format, renders a real before/after
/// of the grade on the user's own frame, and only then offers to save.
/// A file that fails validation cannot be saved; the reason is stated here,
/// never swallowed into a generic toast.
///
/// The picked URL is security-scoped and its scope ends with the picker
/// callback, so the sheet stages a private copy up front and works entirely
/// from that copy — inspect, preview and import all read the staged file.
struct LUTImportSheet: View {
    let sourceURL: URL
    /// Where the file came from, shown in the file row ("Files", "Open in Place").
    var origin: String = "Files"
    var onSaved: ((LUTFile) -> Void)? = nil

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var staged: URL?
    @State private var stagingDir: URL?
    @State private var inspection: LUTParser.Inspection?
    @State private var name = ""
    @State private var collectionID: UUID?
    @State private var originalImage: CGImage?
    @State private var gradedImage: CGImage?
    @State private var split: CGFloat = 0.5
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var saveError: String?
    /// LUT_3D_SIZE as the file itself declares it — read even when validation
    /// fails, so a rejected file still reports the resolution it claims (G2).
    @State private var declaredSize: Int?
    /// Measured heights of the three bands, summed into a content-sized detent.
    @State private var headerHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    private var fileName: String { sourceURL.lastPathComponent }

    /// G2 draws this as a content-height card, not a full-screen sheet: Save
    /// sits just under the last field instead of across a void. Clamped so a
    /// half-measured first frame can't collapse it, with `.large` still
    /// available for long content and Dynamic Type.
    private var contentDetentHeight: CGFloat {
        let total = headerHeight + bodyHeight + footerHeight + 34  // home indicator
        return min(max(total, 360), 760)
    }

    private var sizeText: String {
        let bytes = inspection?.byteCount ?? 0
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "33-point · 214 KB · Files" — resolution first, because that is what
    /// tells a colourist whether the file is worth keeping. A rejected file
    /// still shows the resolution it declares, marked as unverified, rather
    /// than silently dropping the one fact that explains the failure.
    private var subtitleText: String {
        var parts: [String] = []
        if let points = inspection?.pointCountText {
            parts.append(points)
        } else if let declaredSize {
            parts.append("\(declaredSize)-point declared")
        }
        parts.append(sizeText)
        parts.append(origin)
        return parts.joined(separator: " · ")
    }

    private var canSave: Bool {
        inspection?.isValid == true && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A finished inspection that said no. Everything downstream of the verdict
    /// (preview, name, collection) goes inert in this state — the sheet must
    /// read as one unambiguous "rejected", not half-working.
    private var isRejected: Bool { inspection?.isValid == false }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 13) {
                    fileRow
                    failureReason
                    formatBadges
                    splitPreview
                    nameField
                        .opacity(isRejected ? 0.4 : 1)
                        .allowsHitTesting(!isRejected)
                    collectionRow
                        .opacity(isRejected ? 0.4 : 1)
                        .allowsHitTesting(!isRejected)
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(LumaTheme.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 18)
                .measureLumaImportHeight { bodyHeight = $0 }
            }
            footer
        }
        .background(LumaTheme.bar)
        .presentationDetents([.height(contentDetentHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LumaTheme.bar)
        .task { await stageAndInspect() }
        .onDisappear {
            if let stagingDir { try? FileManager.default.removeItem(at: stagingDir) }
        }
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let trimmed = newCollectionName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    collectionID = app.lutRepository.createCollection(name: trimmed).id
                }
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("This LUT joins the new collection when you save it.")
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            Text("Import LUT")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(LumaTheme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .measureLumaImportHeight { headerHeight = $0 }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            SolidCTA(title: "Save to Library", icon: "square.and.arrow.down") { save() }
                .opacity(canSave ? 1 : 0.4)
                .allowsHitTesting(canSave)
            if inspection != nil && inspection?.isValid == false {
                Text("Fix or choose a different file — invalid LUTs are not saved.")
                    .font(.caption)
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(LumaTheme.bar)
        .overlay(alignment: .top) { Hairline() }
        .measureLumaImportHeight { footerHeight = $0 }
    }

    // MARK: File row + validation badge

    private var fileRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11)
                .fill(LumaTheme.accentSoft)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(fileName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitleText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            Spacer(minLength: 8)
            validationBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LumaTheme.hairline))
    }

    @ViewBuilder
    private var validationBadge: some View {
        if let inspection {
            let ok = inspection.isValid
            HStack(spacing: 4) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text(ok ? "Valid" : "Invalid")
            }
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(ok ? LumaTheme.teal : LumaTheme.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((ok ? LumaTheme.teal : LumaTheme.orange).opacity(0.16), in: Capsule())
        } else {
            ProgressView().controlSize(.small).tint(LumaTheme.textMuted)
        }
    }

    /// The failure sits directly under the row it describes rather than in a
    /// separate alert — the user has to see it to understand the dead Save.
    @ViewBuilder
    private var failureReason: some View {
        if let reason = inspection?.failure {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(LumaTheme.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Format badges

    private var formatBadges: some View {
        HStack(spacing: 8) {
            ForEach(LUTParser.Format.allCases, id: \.self) { format in
                let detected = inspection?.format == format
                Text(format.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(detected ? LumaTheme.accentBright : LumaTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(detected ? LumaTheme.accentSoft : LumaTheme.surface, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(detected ? LumaTheme.accent.opacity(0.5)
                                                        : Color.clear)
                    )
                    .opacity(detected ? 1 : 0.55)
            }
            Text("supported formats")
                .font(.system(size: 11))
                .foregroundStyle(LumaTheme.textMuted)
            Spacer(minLength: 0)
        }
    }

    // MARK: Before/after split preview

    private var splitPreview: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(LumaTheme.surfaceStrong)
                if let originalImage {
                    Image(decorative: originalImage, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                if let gradedImage {
                    Image(decorative: gradedImage, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geo.size.width * (1 - split))
                        }
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .offset(x: geo.size.width * split - 1)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
                // Three states, one of them terminal: still inspecting (spinner),
                // rejected (static "no preview"), or previewable (the split).
                if isRejected {
                    noPreviewPlaceholder
                } else {
                    label("Original", alignment: .bottomLeading, bright: false)
                    label("Graded", alignment: .bottomTrailing, bright: true)
                    if gradedImage == nil {
                        ProgressView().controlSize(.small).tint(LumaTheme.textMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isRejected, gradedImage != nil, geo.size.width > 0 else { return }
                        split = min(1, max(0, value.location.x / geo.size.width))
                    }
            )
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LumaTheme.hairline))
    }

    /// The terminal state for a rejected file — static, so the panel stops
    /// claiming work is still in flight under a stated failure.
    private var noPreviewPlaceholder: some View {
        VStack(spacing: 7) {
            Image(systemName: "slash.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(LumaTheme.textMuted)
            Text("No preview — this file can't be graded.")
                .font(.system(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(_ text: String, alignment: Alignment, bright: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(bright ? .white : LumaTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
    }

    // MARK: Name + collection

    private var nameField: some View {
        HStack(spacing: 10) {
            TextField("Look name", text: $name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(LumaTheme.hairline))
    }

    private var collectionRow: some View {
        HStack {
            Text("Add to collection")
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
            Spacer()
            Menu {
                Button("None") { collectionID = nil }
                if !app.lutRepository.collections.isEmpty { Divider() }
                ForEach(app.lutRepository.collections) { collection in
                    Button {
                        collectionID = collection.id
                    } label: {
                        Label(collection.name,
                              systemImage: collectionID == collection.id
                                  ? "checkmark.circle.fill" : "folder")
                    }
                }
                Divider()
                Button {
                    showNewCollection = true
                } label: {
                    Label("New Collection…", systemImage: "folder.badge.plus")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedCollectionName)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(LumaTheme.accentBright)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(LumaTheme.hairline))
    }

    private var selectedCollectionName: String {
        guard let collectionID,
              let match = app.lutRepository.collections.first(where: { $0.id == collectionID })
        else { return "None" }
        return match.name
    }

    // MARK: Staging, inspection, preview

    /// Copies the picked file into a private staging folder while its
    /// security scope is still open, then validates and previews the copy.
    private func stageAndInspect() async {
        guard staged == nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Import_\(UUID().uuidString)", isDirectory: true)
        let destination = dir.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            inspection = LUTParser.Inspection(
                format: nil, lut: nil,
                failure: "Couldn't read that file — it may have moved or be unreadable.",
                byteCount: 0)
            return
        }
        stagingDir = dir
        staged = destination
        name = Self.cleanedName(from: sourceURL)

        declaredSize = Self.declaredCubeSize(at: destination)
        let result = LUTParser.inspect(url: destination)
        inspection = result
        guard result.isValid else { return }
        await renderPreview(cubeURL: destination)
    }

    /// Both halves come from the real pipeline on the user's own frame — the
    /// "after" is the grade that will actually ship, not a tint. The cube is
    /// re-loaded inside the render task (as in `LookThumbs`) so nothing but a
    /// URL crosses the actor boundary.
    private func renderPreview(cubeURL: URL) async {
        let frame = app.previewFrame ?? LookThumbs.fallbackFrame
        let rendered = await Task.detached(priority: .userInitiated) {
            () -> (CGImage?, CGImage?) in
            let pipeline = LookPipeline.shared
            let plain = LookState()
            var neutral = LookSettings()
            neutral.intensity = 0        // dissolve to 0 → the untouched frame
            plain.settings = neutral
            let before = pipeline.gradedStill(frame, state: plain, maxDimension: 640)

            guard let parsed = try? pipeline.loadLUT(at: cubeURL) else { return (before, nil) }
            let graded = LookState()
            var full = LookSettings()
            full.intensity = 100
            graded.settings = full
            graded.lut = parsed
            let after = pipeline.gradedStill(frame, state: graded, maxDimension: 640)
            return (before, after)
        }.value
        originalImage = rendered.0
        gradedImage = rendered.1
    }

    /// The grid resolution the file *claims* in its own header, independent of
    /// whether the body backs that claim up. A truncated cube still declares
    /// LUT_3D_SIZE, and that number is the most useful thing the row can say
    /// about a file the parser has just rejected.
    static func declaredCubeSize(at url: URL) -> Int? {
        // Only the header matters, so cap the read — a HALD PNG or a huge cube
        // must not be pulled into memory twice just to render a subtitle.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), !head.isEmpty,
              let text = String(data: head, encoding: .utf8)
                  ?? String(data: head, encoding: .isoLatin1)
        else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("LUT_3D_SIZE") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let size = tokens.dropFirst().compactMap({ Int($0) }).first, size > 0 {
                return size
            }
        }
        return nil
    }

    /// "bleach_bypass_v3.cube" → "Bleach Bypass V3". Same underscore rule the
    /// repository uses, plus separator/casing tidy-up so the default is one
    /// the user can accept without editing.
    static func cleanedName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let words = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return base }
        return words
            .map { $0.uppercased() == $0 ? $0 : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Save

    private func save() {
        guard canSave, let staged else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let file = try app.lutRepository.importLUT(from: staged, displayName: trimmed)
            if let collectionID,
               let collection = app.lutRepository.collections.first(where: { $0.id == collectionID }) {
                app.lutRepository.toggle(file, in: collection)
            }
            app.importToast = "\(file.displayName) imported"
            LumaHaptics.shared.exportSuccess()
            onSaved?(file)
            dismiss()
        } catch {
            // The file validated a moment ago, so this is a storage failure —
            // say that rather than blaming the LUT.
            saveError = "Couldn't save to your library: \(error.localizedDescription)"
            LumaHaptics.shared.failure()
        }
    }
}

// MARK: - Content-height measurement

private struct LumaImportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Reports this band's laid-out height so the sheet can size its detent to
    /// the content instead of stranding the CTA at the bottom of a full screen.
    func measureLumaImportHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: LumaImportHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(LumaImportHeightKey.self) { height in
            // Sub-point churn would re-key the detent every frame.
            if height > 0 { onChange(height.rounded()) }
        }
    }
}
