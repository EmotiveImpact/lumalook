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
    @State private var selectedMockIndex: Int? = nil
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var isLoading = false
    @State private var loadError: String?

    private var hasSelection: Bool {
        app.selectedVideoURL != nil || app.selectedImage != nil || selectedMockIndex != nil
    }

    private var pickingPhotos: Bool { mode == "Photos" }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                LumaScreenHeaderBar(title: "Select Clip", trailingIcon: "info.circle")

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        SegmentPills(options: ["Video", "Photos"], selection: $mode)

                        // Source selector opens the real Photos picker
                        // (videos or still images depending on the segment).
                        Button { showPicker = true } label: {
                            HStack {
                                if isLoading {
                                    ProgressView().tint(.white)
                                } else if app.selectedVideoURL != nil {
                                    Text("Photo Library — video selected")
                                        .foregroundStyle(LumaTheme.teal)
                                } else if app.selectedImage != nil {
                                    Text("Photo Library — photo selected")
                                        .foregroundStyle(LumaTheme.teal)
                                } else {
                                    Text(pickingPhotos ? "All Photos" : "All Videos")
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LumaTheme.textSecondary)
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 54)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)

                        if let loadError {
                            Text(loadError)
                                .font(.system(size: 13))
                                .foregroundStyle(LumaTheme.orange)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(Array(MockData.clips.enumerated()), id: \.element.id) { index, clip in
                                Button {
                                    selectedMockIndex = index
                                    app.selectedVideoURL = nil
                                } label: {
                                    SceneThumb(scene: clip.scene, radius: 14,
                                               duration: clip.duration,
                                               selected: index == selectedMockIndex,
                                               showCheck: true)
                                        .frame(height: 108)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 120)
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
        .photosPicker(isPresented: $showPicker, selection: $pickerItem,
                      matching: pickingPhotos ? .images : .videos)
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
                            selectedMockIndex = nil
                        } else {
                            loadError = "Could not load that photo. Try another one."
                        }
                    } else if let video = try await newItem.loadTransferable(type: PickedVideo.self) {
                        app.selectedVideoURL = video.url
                        selectedMockIndex = nil
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
