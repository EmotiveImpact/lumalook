import SwiftUI
import AVFoundation

/// The music library as a sheet: tracks LumaLook makes itself, the two pads
/// and the bundled sounds. Same content as the editor's Audio panel.
struct AudioLibrarySheet: View {
    @ObservedObject var editor: EditorState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                MusicLibraryList(editor: editor, onUsed: onClose)
                    .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .background(LumaTheme.ink.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("Music")
                .font(.luma(size: 20, weight: .light))
                .foregroundStyle(LumaTheme.textPrimary)
            Text("library")
                .font(.luma(size: 20, weight: .bold))
                .foregroundStyle(LumaTheme.textPrimary)
            Spacer()
            Button(action: onClose) {
                Text("Done")
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.lumaPress)
        }
    }
}

/// Small AVAudioPlayer wrapper for auditioning a track or a bundled clip.
/// Publishes whether it is playing, so rows can show a playing state, and
/// resets itself when the clip ends.
final class AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    /// Plays `url` from `start` seconds (clamped to the clip).
    func play(_ url: URL, from start: Double = 0) {
        stop()
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return }
        next.delegate = self
        next.prepareToPlay()
        if start > 0, next.duration > 0 {
            next.currentTime = min(start, max(0, next.duration - 1))
        }
        player = next
        isPlaying = next.play()
    }

    func stop() {
        player?.stop()
        player = nil
        if isPlaying { isPlaying = false }
    }

    /// Position in the playing clip, in seconds (0 when idle).
    var currentTime: Double { player?.currentTime ?? 0 }

    /// Length of the loaded clip, in seconds (0 when idle).
    var duration: Double { player?.duration ?? 0 }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === finished else { return }
            self.player = nil
            self.isPlaying = false
        }
    }
}
