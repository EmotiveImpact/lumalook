import AVFoundation
import Foundation
import Speech

/// One caption-sized line of speech, positioned in TIMELINE time.
struct CaptionSegment: Equatable, Sendable {
    var text: String
    var start: Double      // seconds, timeline time
    var duration: Double
}

/// One recognised word — the pure-data shadow of `SFTranscriptionSegment` so the
/// grouping maths is testable without the Speech framework in the loop.
struct CaptionWord: Equatable, Sendable {
    var text: String
    var start: Double
    var duration: Double
}

enum CaptionEngineError: Error { case notAuthorized, recognizerUnavailable, failed }

/// Speech-to-text over an audio-only export of the BUILT composition, plus an
/// SRT writer. Recognising the built composition (rather than each source clip)
/// means the timestamps come back already in timeline time — trims, speed
/// changes and clip order are baked in, so no per-clip time maths can drift.
///
/// Everything here is a static, state-free entry point: transcription is a
/// one-shot async job, not a per-frame render, so there is no cache to bound.
enum CaptionEngine {
    /// Captions shorter than this flicker unreadably — floor every line at it.
    private static let minDuration: Double = 0.4

    // MARK: - Authorization

    /// Requests speech authorization (async wrapper over the callback API).
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Transcription

    /// Transcribes `url` into timed segments grouped into caption-sized chunks
    /// (<= `maxWords` words or <= `maxDuration` seconds per segment).
    /// Rethrows the underlying `SFSpeechRecognizer` error where there is one —
    /// its descriptions ("no speech detected", "cancelled") are worth surfacing.
    static func transcribe(url: URL, locale: Locale = .current,
                           maxWords: Int = 7, maxDuration: Double = 3.0) async throws -> [CaptionSegment] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw CaptionEngineError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw CaptionEngineError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // Partials would resume the continuation early with half a transcript.
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        request.addsPunctuation = true

        let words: [CaptionWord] = try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard state.claimResume() else { return }
                    continuation.resume(throwing: error)
                    return
                }
                guard let result else {
                    guard state.claimResume() else { return }
                    continuation.resume(throwing: CaptionEngineError.failed)
                    return
                }
                // Partials are off, but the handler is defensive by contract —
                // only the FINAL transcript carries stable timestamps.
                guard result.isFinal else { return }
                let words = result.bestTranscription.segments.map {
                    CaptionWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                }
                guard state.claimResume() else { return }
                continuation.resume(returning: words)
            }
            // A released task never calls back — hold it until we resume.
            state.retain(task)
        }

        return group(words, maxWords: maxWords, maxDuration: maxDuration)
    }

    /// Packs consecutive words into caption lines. Pure — no Speech, no state.
    static func group(_ words: [CaptionWord], maxWords: Int, maxDuration: Double) -> [CaptionSegment] {
        let wordLimit = max(1, maxWords)
        let spanLimit = max(minDuration, maxDuration)
        var out: [CaptionSegment] = []
        var chunk: [CaptionWord] = []

        func flush() {
            guard let first = chunk.first, let last = chunk.last else { return }
            let text = chunk.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chunk.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            let start = max(0, first.start)
            let end = last.start + max(0, last.duration)
            out.append(CaptionSegment(text: text, start: start,
                                      duration: max(minDuration, end - start)))
        }

        for word in words {
            if let first = chunk.first {
                // Break BEFORE appending, so a chunk never overshoots its budget.
                let span = (word.start + max(0, word.duration)) - first.start
                if chunk.count >= wordLimit || span > spanLimit { flush() }
            }
            chunk.append(word)
        }
        flush()
        return out
    }

    // MARK: - SRT

    /// Serialises segments to SRT text.
    static func srt(from segments: [CaptionSegment]) -> String {
        segments.enumerated().map { index, segment in
            let start = max(0, segment.start)
            let end = start + max(0, segment.duration)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(index + 1)\n\(timecode(start)) --> \(timecode(end))\n\(text)\n"
        }.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm` — SRT's comma-for-decimal-point quirk, not a typo.
    private static func timecode(_ seconds: Double) -> String {
        // `Int(_:)` TRAPS on ±inf/NaN and on anything past Int.max. `srt(from:)`
        // is public and takes caller-built segments, so clamp to the range SRT
        // can actually spell (99:59:59,999) rather than crash the export.
        let safe = seconds.isFinite ? min(max(0, seconds), 359_999.999) : 0
        let totalMs = Int((safe * 1000).rounded())
        let ms = totalMs % 1000
        let totalSeconds = totalMs / 1000
        return String(format: "%02d:%02d:%02d,%03d",
                      totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, ms)
    }
}

// MARK: - Continuation guard

/// The recognition handler is `@escaping` and may fire more than once (a late
/// error after a final result); resuming a continuation twice traps. This gates
/// the resume to exactly one caller and retains the task in the meantime.
private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var task: SFSpeechRecognitionTask?

    /// True exactly once — only the winner may resume the continuation.
    func claimResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        task = nil          // breaks task → handler → self retain cycle
        return true
    }

    func retain(_ newTask: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }   // already finished; nothing to hold
        task = newTask
    }
}
