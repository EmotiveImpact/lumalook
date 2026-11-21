import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One caption-sized line of speech, positioned in TIMELINE time.
struct CaptionSegment: Equatable, Sendable {
    var text: String
    var start: Double      // seconds, timeline time
    var duration: Double
    /// The recognised words inside this line, in TIMELINE time. Empty when the
    /// line was typed or injected rather than heard; the renderer then spreads
    /// the highlight evenly across the line.
    var words: [CaptionWord] = []
}

/// One recognised word — the pure-data shadow of `SFTranscriptionSegment` so the
/// grouping maths is testable without the Speech framework in the loop.
///
/// Codable because caption layers persist their words (relative to the layer's
/// own start) so the karaoke highlight survives a relaunch.
struct CaptionWord: Equatable, Sendable, Codable {
    var text: String
    var start: Double
    var duration: Double
}

enum CaptionEngineError: Error {
    case notAuthorized, recognizerUnavailable, failed
    /// The recogniser ran but heard no words.
    case noSpeech
    /// The edit has no audio track at all, so there is nothing to listen to.
    case noAudio
}

/// What one transcription run produced, and how.
struct CaptionTranscript: Sendable {
    var segments: [CaptionSegment]
    /// True when no audio left the device (SpeechAnalyzer, or SFSpeech with
    /// `requiresOnDeviceRecognition`). False = Apple's speech servers.
    var onDevice: Bool
}

/// Coarse progress for the Captions panel. Speech recognition reports almost
/// nothing while it works, so this is phases plus a fraction where one exists.
enum CaptionProgress: Equatable, Sendable {
    case preparingAudio
    case downloadingModel
    /// 0...1 when known (SpeechAnalyzer reports finished phrases); nil = unknown.
    case listening(Double?)
}

typealias CaptionProgressHandler = @Sendable (CaptionProgress) -> Void

/// Where a language's recognition would run, for the panel's honest privacy line.
enum CaptionPrivacy: Equatable, Sendable {
    case onDevice
    case server
    case unavailable
}

/// Speech-to-text over an audio-only export of the BUILT composition, plus an
/// SRT writer. Recognising the built composition (rather than each source clip)
/// means the timestamps come back already in timeline time — trims, speed
/// changes and clip order are baked in, so no per-clip time maths can drift.
///
/// Recognition prefers the device: on iOS 26 SpeechAnalyzer (always on-device),
/// otherwise SFSpeechRecognizer with `requiresOnDeviceRecognition` whenever the
/// language supports it. Only a language with no on-device model falls back to
/// Apple's servers, and `CaptionTranscript.onDevice` says which happened.
///
/// Everything here is a static, state-free entry point: transcription is a
/// one-shot async job, not a per-frame render, so there is no cache to bound.
enum CaptionEngine {
    /// Captions shorter than this flicker unreadably — floor every line at it.
    private static let minDuration: Double = 0.4
    /// A pause this long between words starts a new line.
    private static let pauseBreak: Double = 0.9
    /// How long a line lingers after its last word, unless the next one starts.
    private static let tailHold: Double = 0.3

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

    /// True when the person has already said no (or a profile forbids it), so
    /// the panel can explain instead of asking again.
    static var isAuthorizationDenied: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .denied || status == .restricted
    }

    // MARK: - Languages

    /// Where recognition for `locale` would run. Cheap enough for a panel to
    /// call when the language changes.
    static func privacy(for locale: Locale) async -> CaptionPrivacy {
        if #available(iOS 26.0, *) {
            if await analyzerLocale(for: locale) != nil { return .onDevice }
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return .unavailable }
        return recognizer.supportsOnDeviceRecognition ? .onDevice : .server
    }

    /// Normalised BCP-47-ish key ("en-gb") for comparing locale identifiers
    /// that arrive as either "en_GB" or "en-GB".
    static func localeKey(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Identifiers SFSpeechRecognizer can do at all, normalised by `localeKey`.
    static func recognizerLocaleKeys() -> Set<String> {
        Set(SFSpeechRecognizer.supportedLocales().map { localeKey($0.identifier) })
    }

    // MARK: - Transcription

    /// Transcribes `url` into timed segments grouped into caption-sized chunks
    /// (<= `maxWords` words or <= `maxDuration` seconds per segment).
    /// Rethrows the underlying `SFSpeechRecognizer` error where there is one —
    /// its descriptions ("no speech detected", "cancelled") are worth surfacing.
    static func transcribe(url: URL, locale: Locale = .current,
                           maxWords: Int = 7, maxDuration: Double = 3.0) async throws -> [CaptionSegment] {
        let transcript = try await transcribeDetailed(url: url, locale: locale,
                                                      maxWords: maxWords, maxDuration: maxDuration)
        return transcript.segments
    }

    /// The full entry point: on-device first, server only when the language
    /// has no on-device model. `totalDuration` (seconds of audio) lets the
    /// SpeechAnalyzer path report a real fraction.
    static func transcribeDetailed(url: URL, locale: Locale,
                                   maxWords: Int = 6, maxDuration: Double = 3.0,
                                   maxCharacters: Int = 0, totalDuration: Double = 0,
                                   onProgress: CaptionProgressHandler? = nil) async throws -> CaptionTranscript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw CaptionEngineError.notAuthorized
        }

        if #available(iOS 26.0, *) {
            if let matched = await analyzerLocale(for: locale) {
                do {
                    let words = try await transcribeWithAnalyzer(url: url, locale: matched,
                                                                 totalDuration: totalDuration,
                                                                 onProgress: onProgress)
                    guard !words.isEmpty else { throw CaptionEngineError.noSpeech }
                    let segments = group(words, maxWords: maxWords, maxDuration: maxDuration,
                                         maxCharacters: maxCharacters)
                    return CaptionTranscript(segments: segments, onDevice: true)
                } catch CaptionEngineError.noSpeech {
                    // The on-device model heard nothing; the older recogniser
                    // would not do better, and retrying could send audio away.
                    throw CaptionEngineError.noSpeech
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Model download failed (offline), or the analyzer refused
                    // the file: fall through to SFSpeechRecognizer below.
                }
            }
        }

        onProgress?(.listening(nil))
        let result = try await transcribeWithRecognizer(url: url, locale: locale)
        guard !result.words.isEmpty else { throw CaptionEngineError.noSpeech }
        let segments = group(result.words, maxWords: maxWords, maxDuration: maxDuration,
                             maxCharacters: maxCharacters)
        return CaptionTranscript(segments: segments, onDevice: result.onDevice)
    }

    // MARK: SFSpeechRecognizer

    private static func transcribeWithRecognizer(url: URL, locale: Locale) async throws
        -> (words: [CaptionWord], onDevice: Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw CaptionEngineError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // Partials would resume the continuation early with half a transcript.
        request.shouldReportPartialResults = false
        // On-device whenever this language has a local model: nothing leaves
        // the phone, and there is no one-minute server limit on the file.
        let onDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.addsPunctuation = true

        let words: [CaptionWord] = try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard state.claimResume() else { return }
                    // 1110 = "No speech detected" (kAFAssistantErrorDomain).
                    if (error as NSError).code == 1110 {
                        continuation.resume(throwing: CaptionEngineError.noSpeech)
                    } else {
                        continuation.resume(throwing: error)
                    }
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
        return (words, onDevice)
    }

    // MARK: SpeechAnalyzer (iOS 26)

    /// The SpeechTranscriber locale matching `locale`: exact region first,
    /// then the same language in any region. nil = not supported here (the
    /// list is empty on hardware that cannot run the on-device model).
    @available(iOS 26.0, *)
    private static func analyzerLocale(for locale: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { return nil }
        let wanted = localeKey(locale.identifier)
        if let exact = supported.first(where: { localeKey($0.identifier) == wanted }) {
            return exact
        }
        let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
        return supported.first(where: {
            (localeKey($0.identifier).split(separator: "-").first.map(String.init) ?? "") == language
        })
    }

    /// Whole-file, on-device transcription with word timings. Every API here
    /// is as documented for iOS 26: SpeechTranscriber with the audioTimeRange
    /// attribute, AssetInventory for the model, SpeechAnalyzer over the file.
    @available(iOS 26.0, *)
    private static func transcribeWithAnalyzer(url: URL, locale: Locale, totalDuration: Double,
                                               onProgress: CaptionProgressHandler?) async throws -> [CaptionWord] {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress?(.downloadingModel)
            try await installation.downloadAndInstall()
        }
        onProgress?(.listening(0))

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        let total = totalDuration

        let collector = Task { () throws -> [CaptionWord] in
            var words: [CaptionWord] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = range.start.seconds
                    let duration = range.duration.seconds
                    guard start.isFinite, duration.isFinite else { continue }
                    // A lone punctuation mark rides on the word before it.
                    if CaptionEngine.isPunctuationOnly(text), let last = words.indices.last {
                        words[last].text += text
                        continue
                    }
                    words.append(CaptionWord(text: text, start: max(0, start), duration: max(0, duration)))
                }
                if total > 0 {
                    let done = result.range.end.seconds
                    if done.isFinite { onProgress?(.listening(min(1, max(0, done / total)))) }
                }
            }
            return words
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    // MARK: - Grouping

    /// Packs consecutive words into caption lines. Pure — no Speech, no state.
    ///
    /// A line breaks BEFORE a word that would push it past `maxWords`,
    /// `maxDuration` or `maxCharacters` (0 = no character limit), before a word
    /// that follows a long pause, and AFTER a word that ends a sentence. Each
    /// line keeps its words (timeline time) for the karaoke highlight, and
    /// lingers a moment after its last word unless the next line starts first.
    static func group(_ words: [CaptionWord], maxWords: Int, maxDuration: Double,
                      maxCharacters: Int = 0) -> [CaptionSegment] {
        let wordLimit = max(1, maxWords)
        let spanLimit = max(minDuration, maxDuration)
        var out: [CaptionSegment] = []
        var chunk: [CaptionWord] = []

        func flush() {
            let kept = chunk
            chunk.removeAll(keepingCapacity: true)
            guard let first = kept.first, let last = kept.last else { return }
            let text = kept.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let start = max(0, first.start)
            let end = last.start + max(0, last.duration)
            out.append(CaptionSegment(text: text, start: start,
                                      duration: max(minDuration, end - start),
                                      words: kept))
        }

        for raw in words {
            var word = raw
            word.text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.text.isEmpty else { continue }
            if let first = chunk.first, let previous = chunk.last {
                // Break BEFORE appending, so a chunk never overshoots its budget.
                let span = (word.start + max(0, word.duration)) - first.start
                let gap = word.start - (previous.start + max(0, previous.duration))
                let characters = chunk.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                if chunk.count >= wordLimit || span > spanLimit || gap > pauseBreak
                    || (maxCharacters > 0 && characters > maxCharacters) {
                    flush()
                }
            }
            chunk.append(word)
            if let mark = word.text.last, ".?!".contains(mark), chunk.count >= 2 { flush() }
        }
        flush()

        // Let each line breathe after its last word, never into the next line.
        for i in out.indices {
            let end = out[i].start + out[i].duration
            let limit = i + 1 < out.count ? out[i + 1].start : end + tailHold
            out[i].duration = max(out[i].duration, min(end + tailHold, limit) - out[i].start)
        }
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

// MARK: - Word timing (pure)

/// Word-timing helpers shared by the timeline (storing a line's words) and the
/// renderer (finding the word being spoken). Pure functions, no state.
enum CaptionTiming {
    /// Converts timeline-time words to times relative to a line starting at
    /// `lineStart` and lasting `duration`, clamped inside the line.
    static func relative(_ words: [CaptionWord], lineStart: Double, duration: Double) -> [CaptionWord] {
        guard duration > 0, duration.isFinite, lineStart.isFinite else { return [] }
        return words.compactMap { word in
            guard word.start.isFinite, word.duration.isFinite else { return nil }
            let start = min(max(0, word.start - lineStart), duration)
            let length = min(max(0, word.duration), max(0, duration - start))
            return CaptionWord(text: word.text, start: start, duration: length)
        }
    }

    /// Word timings for a line of `tokenCount` visible words. Stored timings
    /// are used when they still match the words on screen; after an edit that
    /// changed the word count (or for a typed line) the line is shared out
    /// evenly, so the highlight still walks across it in time.
    static func resolve(_ words: [CaptionWord], tokenCount: Int, duration: Double) -> [CaptionWord] {
        guard tokenCount > 0, duration > 0, duration.isFinite else { return [] }
        if words.count == tokenCount,
           words.allSatisfy({ $0.start.isFinite && $0.duration.isFinite }) {
            return words
        }
        let step = duration / Double(tokenCount)
        return (0..<tokenCount).map { i in
            CaptionWord(text: "", start: Double(i) * step, duration: step)
        }
    }

    /// Scales relative word timings when a line's duration changes.
    static func rescale(_ words: [CaptionWord], from oldDuration: Double, to newDuration: Double) -> [CaptionWord] {
        guard oldDuration > 0.001, newDuration > 0.001,
              oldDuration.isFinite, newDuration.isFinite else { return words }
        let k = newDuration / oldDuration
        return words.map { CaptionWord(text: $0.text, start: $0.start * k, duration: $0.duration * k) }
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
