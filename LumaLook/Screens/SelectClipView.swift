import SwiftUI
import PhotosUI

/// Transferable wrapper that copies the picked video into a temp file we own.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaLook_Picked_\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

struct SelectClipView: View {
    @EnvironmentObject private var app: AppModel
    @State private var mode = "All"
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var hasSelection: Bool {
        app.selectedVideoURL != nil || app.selectedImage != nil || pickerItems.count > 1
    }

    private var pickingPhotos: Bool { mode == "Photos" }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                LumaScreenHeaderBar(title: "Select Clip", trailingIcon: "info.circle")

                VStack(spacing: 16) {
                    SegmentPills(options: ["All", "Video", "Photos"], selection: $mode)
                        .padding(.horizontal, 22)

                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().tint(.white)
                            Text("Loading…").foregroundStyle(.white)
                        } else if app.selectedVideoURL != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(LumaTheme.teal)
                            Text("Video selected").foregroundStyle(LumaTheme.teal)
                        } else if app.selectedImage != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(LumaTheme.teal)
                            Text(pickerItems.count > 1 ? "\(pickerItems.count) photos — one grade"
                                                       : "Photo selected")
                                .foregroundStyle(LumaTheme.teal)
                        } else {
                            Text(mode == "All" ? "Whole library — videos & photos"
                                 : (pickingPhotos ? "All Photos" : "All Videos"))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        if let loadError {
                            Text(loadError)
                                .font(.system(size: 13))
                                .foregroundStyle(LumaTheme.orange)
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .lumaCard(cornerRadius: 14)
                    .padding(.horizontal, 22)

                    // The real photo library, embedded in our chrome — every
                    // thumbnail is the user's actual footage.
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 10,
                                 matching: mode == "All" ? .any(of: [.videos, .images])
                                          : (pickingPhotos ? .images : .videos),
                                 photoLibrary: .shared()) {
                        Label("Open Library", systemImage: "photo.on.rectangle")
                    }
                    .photosPickerStyle(.inline)
                    .photosPickerDisabledCapabilities(.selectionActions)
                    .photosPickerAccessoryVisibility(.hidden, edges: .all)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
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
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Preparing…")
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    } else if let loadError, !hasSelection {
                        Text(loadError)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LumaTheme.orange)
                            .lineLimit(2)
                    } else {
                        Text(pickerItems.count > 1 ? "\(pickerItems.count) selected — batch"
                             : (hasSelection ? "1 clip selected" : "No clip selected"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(hasSelection ? .white : LumaTheme.textMuted)
                    }
                    Spacer()
                    Button {
                        app.path.append(.applyLook)
                    } label: {
                        Text("Next")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 132, height: 52)
                            .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasSelection)
                    .opacity(hasSelection ? 1 : 0.4)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(LumaTheme.background)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: pickerItems) { _, newItems in
            guard let first = newItems.first else {
                // Deselecting in the picker clears our state too, so the
                // status row and Next button never disagree with the grid.
                app.selectedVideoURL = nil
                app.selectedImage = nil
                app.batchItems = []
                return
            }
            isLoading = true
            loadError = nil
            // First item previews; extras queue for batch grading (#10).
            app.batchItems = newItems.count > 1 ? newItems : []
            Task {
                defer { isLoading = false }
                let isVideo = first.supportedContentTypes.contains {
                    $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent)
                }
                if isVideo {
                    if let video = try? await first.loadTransferable(type: PickedVideo.self) {
                        app.selectedImage = nil
                        app.selectedVideoURL = video.url
                    } else if let data = try? await first.loadTransferable(type: Data.self) {
                        // Some assets refuse the file representation; write the
                        // raw data out ourselves so the pick still succeeds.
                        let ext = first.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("LumaLook_Picked_\(UUID().uuidString).\(ext)")
                        do {
                            try data.write(to: url)
                            app.selectedImage = nil
                            app.selectedVideoURL = url
                        } catch {
                            loadError = "Could not load that video. Try another one."
                        }
                    } else {
                        loadError = "Could not load that video. Try another one."
                    }
                } else if let data = try? await first.loadTransferable(type: Data.self),
                          let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                    app.selectedVideoURL = nil
                    app.selectedImage = image
                } else {
                    loadError = "Could not load that item. Try another one."
                }
            }
        }
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
