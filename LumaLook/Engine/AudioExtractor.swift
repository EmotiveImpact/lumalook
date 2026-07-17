import AVFoundation

enum AudioExtractorError: Error { case noAudioTrack, exportFailed }

/// Bakes the trimmed, speed-scaled audio of a clip to a standalone `.m4a` in
/// the audio folder — a real file so the detached lane survives clip deletion.
enum AudioExtractor {
    static func extract(from url: URL, trimStart: Double, trimEnd: Double,
                        speed: Double, into folder: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioExtractorError.exportFailed
        }
        let timescale = CMTimeScale(600)
        let range = CMTimeRange(
            start: CMTime(seconds: max(0, trimStart), preferredTimescale: timescale),
            duration: CMTime(seconds: max(0.05, trimEnd - trimStart), preferredTimescale: timescale))
        try track.insertTimeRange(range, of: sourceAudio, at: .zero)
        if speed != 1.0 {
            let scaled = CMTime(seconds: (trimEnd - trimStart) / speed, preferredTimescale: timescale)
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: scaled)
        }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = folder.appendingPathComponent("detached_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractorError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { throw AudioExtractorError.exportFailed }
        return outputURL
    }
}
