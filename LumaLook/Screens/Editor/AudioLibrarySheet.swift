import SwiftUI
import AVFoundation

/// Browse + preview + add bundled royalty-free SFX and music beds (B3).
struct AudioLibrarySheet: View {
    @ObservedObject var editor: EditorState
    let onClose: () -> Void

    @State private var category = "sfx"
    @State private var previewID: String?
    @StateObject private var preview = AudioPreviewPlayer()

    private var entries: [BundledAudioEntry] { BundledAudioLibrary.entries(category: category) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Sound Library").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Done", action: onClose)
                    .font(.footnote.weight(.semibold)).foregroundStyle(LumaTheme.accentBright)
            }

            Picker("", selection: $category) {
                Text("SFX").tag("sfx")
                Text("Music").tag("music")
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            }
        }
        .padding(20)
        .background(LumaTheme.background)
        .onDisappear { preview.stop() }
    }

    private func row(_ entry: BundledAudioEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                if previewID == entry.id { preview.stop(); previewID = nil }
                else if let url = BundledAudioLibrary.url(for: entry) {
                    preview.play(url); previewID = entry.id
                }
            } label: {
                Image(systemName: previewID == entry.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26)).foregroundStyle(LumaTheme.teal)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(String(format: "%.1fs", entry.duration))
                    .font(.system(size: 12)).foregroundStyle(LumaTheme.textSecondary)
            }
            Spacer()
            Button {
                guard let url = BundledAudioLibrary.url(for: entry) else { return }
                LumaHaptics.shared.tap()
                Task {
                    if let imported = editor.importMusicFile(from: url) {
                        await editor.addAudioTrack(importedURL: imported, title: entry.title,
                                                   kind: entry.category == "sfx" ? .sfx : .music)
                    }
                }
            } label: {
                Text("Add").font(.footnote.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(LumaTheme.accent, in: Capsule())
            }
            .buttonStyle(.lumaPress)
        }
        .padding(10)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Tiny AVAudioPlayer wrapper for previewing a bundled clip.
final class AudioPreviewPlayer: ObservableObject {
    private var player: AVAudioPlayer?
    func play(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
    func stop() { player?.stop(); player = nil }
}
