import Foundation
import AVFoundation
import CoreImage
import Photos
import UIKit

enum VideoExportError: Error, LocalizedError {
    case exportSessionCreationFailed
    case exportFailed
    case noVideoSelected
    case notEnoughDiskSpace(neededMB: Int)
    case deviceTooHot

    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed: return "Could not create the export session."
        case .exportFailed: return "The export failed. Please try again."
        case .noVideoSelected: return "Select a video from Photos first."
        case .notEnoughDiskSpace(let neededMB):
            return "Not enough free space — this export needs about \(neededMB) MB. Free up some storage and try again."
        case .deviceTooHot:
            return "Your iPhone is too hot to export safely. Let it cool down for a minute and try again."
        }
    }
}

/// User-facing export options (queue #6). Remembered across sessions.
struct ExportSpec: Equatable {
    enum Resolution: String, CaseIterable { case hd1080 = "1080p", uhd4K = "4K" }
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }

    var resolution: Resolution = .hd1080
    var codec: Codec = .hevc
    var fps: Int = 30

    var presetName: String {
        switch (resolution, codec) {
        case (.hd1080, .h264): return AVAssetExportPreset1920x1080
        case (.uhd4K, .h264): return AVAssetExportPreset3840x2160
        case (.hd1080, .hevc): return AVAssetExportPresetHEVC1920x1080
        case (.uhd4K, .hevc): return AVAssetExportPresetHEVC3840x2160
        }
    }

    /// Rough output size for the disk preflight (same bitrate model the
    /// spec sheet's estimate row shows the user).
    func estimatedMegabytes(durationSeconds: Double) -> Int {
        let mbps: Double
        switch (resolution, codec) {
        case (.hd1080, .h264): mbps = 12
        case (.hd1080, .hevc): mbps = 8
        case (.uhd4K, .h264): mbps = 50
        case (.uhd4K, .hevc): mbps = 28
        }
        return max(1, Int(durationSeconds * mbps / 8))
    }

    /// AppStorage-friendly encoding.
    var rawValue: String { "\(resolution.rawValue)|\(codec.rawValue)|\(fps)" }
    static func from(rawValue: String) -> ExportSpec {
        let parts = rawValue.split(separator: "|").map(String.init)
        var spec = ExportSpec()
        if parts.count == 3 {
            spec.resolution = Resolution(rawValue: parts[0]) ?? .hd1080
            spec.codec = Codec(rawValue: parts[1]) ?? .hevc
            spec.fps = Int(parts[2]) ?? 30
        }
        return spec
    }
}

@MainActor
final class VideoExporter: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExporting = false

    private var session: AVAssetExportSession?
    private var progressTask: Task<Void, Never>?

    init() {
        Self.cleanUpStaleExports()
    }

    /// Exports land in tmp before the user saves/shares them; failed or
    /// abandoned ones would pile up forever. Sweep anything older than a day.
    nonisolated static func cleanUpStaleExports() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for file in files where file.lastPathComponent.hasPrefix("LumaLook_Export_") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// #92 preflight: fail fast with a friendly message instead of dying
    /// mid-render — the category's #1 trust killer (dying renders, thermal
    /// kills, full disks).
    private func preflight(estimatedMB: Int) throws {
        if ProcessInfo.processInfo.thermalState == .critical {
            throw VideoExportError.deviceTooHot
        }
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage {
            // Headroom: the estimate + 200 MB so we never run the disk dry.
            let needed = Int64(estimatedMB + 200) * 1_000_000
            if free < needed {
                throw VideoExportError.notEnoughDiskSpace(neededMB: estimatedMB + 200)
            }
        }
    }

    /// Single-clip Apply-a-Look export.
    func export(videoURL: URL, lookState: LookState,
                spec: ExportSpec = ExportSpec()) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let pipeline = LookPipeline.shared

        let composition = AVMutableVideoComposition(asset: asset) { request in
            // Finite extent: spatial ops (lens et al.) need real frame bounds.
            let source = request.sourceImage
            // includeSplit: false — the Before/After wipe never bakes into exports.
            let filtered = pipeline.apply(state: lookState, to: source, includeSplit: false)
            request.finish(with: filtered.cropped(to: request.sourceImage.extent), context: pipeline.context)
        }
        composition.applySDRColorPolicy()

        return try await export(asset: asset, videoComposition: composition, audioMix: nil, spec: spec)
    }

    /// Shared export path — also used for full editor timelines.
    func export(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?,
                spec: ExportSpec = ExportSpec()) async throws -> URL {
        // Frame-rate choice resamples the CI handler cadence.
        if let mutable = videoComposition as? AVMutableVideoComposition, spec.fps > 0 {
            mutable.frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        }
        // #92 preflight: disk space + thermal, before any work starts.
        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
        try preflight(estimatedMB: spec.estimatedMegabytes(durationSeconds: durationSeconds))

        isExporting = true
        progress = 0
        // Keep the render alive across a lock screen or app switch — the
        // "renders die when you lock the phone" complaint that sinks
        // competitor ratings. Best-effort: iOS still caps background time.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LumaLook Export") { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        defer {
            isExporting = false
            progressTask?.cancel()
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Export_\(UUID().uuidString).mov")

        guard let session = AVAssetExportSession(asset: asset, presetName: spec.presetName)
                ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw VideoExportError.exportSessionCreationFailed
        }
        self.session = session

        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.shouldOptimizeForNetworkUse = true

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                self.progress = Double(session.progress)
                if session.status == .completed || session.status == .failed { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await session.export()

        if session.status == .completed {
            progress = 1
            return outputURL
        }
        // Never leave a partial file behind on failure or cancel.
        try? FileManager.default.removeItem(at: outputURL)
        if session.status == .cancelled {
            throw CancellationError()
        }
        throw session.error ?? VideoExportError.exportFailed
    }

    func cancel() {
        session?.cancelExport()
    }

    /// Saves to the photo library. Returns false (NEVER throws a scary
    /// error) when the user has Photos access denied or add-only blocked —
    /// the export itself succeeded and must still reach the success screen,
    /// where a banner offers the Settings deep link.
    @discardableResult
    func saveToPhotos(url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return true
        } catch {
            return false
        }
    }
}
