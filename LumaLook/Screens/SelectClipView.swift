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
    @State private var mode = "Video"
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var loadError: String?

    private var hasSelection: Bool {
        app.selectedVideoURL != nil || app.selectedImage != nil
    }

    private var pickingPhotos: Bool { mode == "Photos" }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                LumaScreenHeaderBar(title: "Select Clip", trailingIcon: "info.circle")

                VStack(spacing: 16) {
                    SegmentPills(options: ["Video", "Photos"], selection: $mode)
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
                            Text("Photo selected").foregroundStyle(LumaTheme.teal)
                        } else {
                            Text(pickingPhotos ? "All Photos" : "All Videos")
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
                    PhotosPicker(selection: $pickerItem,
                                 matching: pickingPhotos ? .images : .videos,
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
                    Text(hasSelection ? "1 clip selected" : "No clip selected")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(hasSelection ? .white : LumaTheme.textMuted)
                    Spacer()
                    Button {
                        app.path.append(.applyLook)
                    } label: {
                        Text("NEXT")
                            .font(.system(size: 16, weight: .bold))
                            .tracking(1.4)
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
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            isLoading = true
            loadError = nil
            Task {
                defer { isLoading = false }
                do {
                    if pickingPhotos {
                        if let data = try await newItem.loadTransferable(type: Data.self),
                           let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                            app.selectedImage = image
                        } else {
                            loadError = "Could not load that photo. Try another one."
                        }
                    } else if let video = try await newItem.loadTransferable(type: PickedVideo.self) {
                        app.selectedVideoURL = video.url
                    }
                } catch {
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
