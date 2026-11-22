import AVFoundation
import Accelerate

struct BeatAnalysis { let beats: [Double]; let bpm: Double }

/// Spectral-flux onset + tempo detection. Reads mono PCM off the audio track,
/// builds a half-wave-rectified spectral-flux onset envelope, peak-picks onsets
/// with an adaptive threshold, and estimates tempo by autocorrelation.
enum BeatDetector {

    // Fixed analysis parameters.
    private static let sampleRate: Double = 22050
    private static let windowSize = 1024          // FFT window (2^10)
    private static let hopSize = 512              // 50% overlap
    private static let log2n = vDSP_Length(10)    // log2(windowSize)

    /// Analyses `url` for beat onset times (seconds) + tempo. Runs off the
    /// main thread; returns empty beats + bpm 0 on any failure.
    static func analyze(url: URL) async -> BeatAnalysis {
        // Generated library tracks know their grid exactly: no detection,
        // no octave errors, beat 0 on the downbeat.
        if let known = knownGrid(for: url) { return known }
        guard let samples = await readMonoSamples(url: url),
              samples.count >= windowSize else {
            return BeatAnalysis(beats: [], bpm: 0)
        }
        // Heavy DSP runs on a background executor.
        return await Task.detached(priority: .userInitiated) {
            process(samples: samples)
        }.value
    }

    /// The exact grid of a generated track (see MusicBeatGrid), whether the
    /// lane plays the imported file or the rendered cache itself.
    static func knownGrid(for url: URL) -> BeatAnalysis? {
        if let entry = MusicBeatGrid.entry(for: url), !entry.beats.isEmpty {
            return BeatAnalysis(beats: entry.beats, bpm: entry.bpm)
        }
        // A file straight from the render cache: "<track id>-v<n>.m4a".
        let stem = url.deletingPathExtension().lastPathComponent
        if let dash = stem.range(of: "-v", options: .backwards),
           let track = MusicCatalogue.track(id: String(stem[..<dash.lowerBound])) {
            return BeatAnalysis(beats: track.beatTimes, bpm: track.bpm)
        }
        return nil
    }

    // MARK: - PCM reading

    private static func readMonoSamples(url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        do {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var samples: [Float] = []
            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    let floatCount = length / MemoryLayout<Float>.size
                    if floatCount > 0 {
                        var chunk = [Float](repeating: 0, count: floatCount)
                        let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                            guard let dest = raw.baseAddress else { return -1 }
                            return CMBlockBufferCopyDataBytes(blockBuffer,
                                                              atOffset: 0,
                                                              dataLength: length,
                                                              destination: dest)
                        }
                        if status == noErr {
                            samples.append(contentsOf: chunk)
                        }
                    }
                }
                CMSampleBufferInvalidate(sampleBuffer)
            }

            let failed = reader.status == .failed
            reader.cancelReading()
            if failed { return nil }
            return samples
        } catch {
            return nil
        }
    }

    // MARK: - Pipeline

    private static func process(samples: [Float]) -> BeatAnalysis {
        let envelope = spectralFluxEnvelope(samples)
        guard !envelope.isEmpty else { return BeatAnalysis(beats: [], bpm: 0) }

        // Normalise the envelope to [0, 1] so thresholds are scale-independent.
        var maxVal: Float = 0
        vDSP_maxv(envelope, 1, &maxVal, vDSP_Length(envelope.count))
        guard maxVal > 0 else { return BeatAnalysis(beats: [], bpm: 0) }

        var norm = [Float](repeating: 0, count: envelope.count)
        var divisor = maxVal
        vDSP_vsdiv(envelope, 1, &divisor, &norm, 1, vDSP_Length(envelope.count))

        let beats = pickOnsets(envelope: norm).sorted()
        var bpm = estimateTempo(envelope: norm)
        // Reconcile the autocorrelation tempo with the actual onset spacing —
        // autocorrelation is prone to octave (half/double) errors. When onsets
        // are regular, the median inter-onset interval is the ground truth.
        if beats.count >= 4 {
            let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
            let median = gaps[gaps.count / 2]
            if median > 0.05 {
                var spacingBPM = 60.0 / median
                while spacingBPM < 70 { spacingBPM *= 2 }
                while spacingBPM > 190 { spacingBPM /= 2 }
                bpm = spacingBPM
            }
        }
        return BeatAnalysis(beats: beats, bpm: bpm)
    }

    // MARK: - Spectral-flux onset envelope

    private static func spectralFluxEnvelope(_ samples: [Float]) -> [Float] {
        let n = windowSize
        let hop = hopSize
        let halfN = n / 2
        guard samples.count >= n else { return [] }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        let frameCount = (samples.count - n) / hop + 1
        var envelope = [Float](repeating: 0, count: frameCount)

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var windowed = [Float](repeating: 0, count: n)
        var magnitudes = [Float](repeating: 0, count: halfN)
        var prevMag = [Float](repeating: 0, count: halfN)
        var diff = [Float](repeating: 0, count: halfN)
        var zero: Float = 0

        samples.withUnsafeBufferPointer { sp in
            guard let sBase = sp.baseAddress else { return }

            for f in 0..<frameCount {
                let start = f * hop

                // windowed = samples[start ..< start+n] * hann
                vDSP_vmul(sBase + start, 1, hann, 1, &windowed, 1, vDSP_Length(n))

                // Pack into split-complex, run the real FFT, take magnitudes.
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                    imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                              capacity: halfN) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
                    }
                }

                // Half-wave-rectified spectral flux: sum of max(0, mag - prevMag).
                // vDSP_vsub computes C = A - B given args (B, A, C).
                vDSP_vsub(prevMag, 1, magnitudes, 1, &diff, 1, vDSP_Length(halfN))
                diff.withUnsafeMutableBufferPointer { dp in
                    vDSP_vthres(dp.baseAddress!, 1, &zero, dp.baseAddress!, 1, vDSP_Length(halfN))
                }
                var flux: Float = 0
                vDSP_sve(diff, 1, &flux, vDSP_Length(halfN))

                // Frame 0 compares against a silent history, so skip its spike.
                envelope[f] = (f == 0) ? 0 : flux

                // Current magnitudes become the history for the next hop.
                swap(&magnitudes, &prevMag)
            }
        }

        return envelope
    }

    // MARK: - Peak picking

    private static func pickOnsets(envelope: [Float]) -> [Double] {
        let count = envelope.count
        guard count > 2 else { return [] }

        let halfWindow = 43            // ~1s at 22050 Hz / hop 512
        let floor: Float = 0.1         // ignore near-silent ripples
        var onsets: [Double] = []

        envelope.withUnsafeBufferPointer { ep in
            guard let base = ep.baseAddress else { return }
            for i in 1..<(count - 1) {
                let v = base[i]
                // Local maximum above the noise floor.
                guard v >= floor, v > base[i - 1], v >= base[i + 1] else { continue }

                let lo = max(0, i - halfWindow)
                let hi = min(count - 1, i + halfWindow)
                var mean: Float = 0
                var sd: Float = 0
                vDSP_normalize(base + lo, 1, nil, 1, &mean, &sd, vDSP_Length(hi - lo + 1))

                if v > mean + 1.5 * sd {
                    onsets.append(Double(i * hopSize) / sampleRate)
                }
            }
        }
        return onsets
    }

    // MARK: - Tempo (autocorrelation)

    private static func estimateTempo(envelope: [Float]) -> Double {
        let count = envelope.count
        guard count > 2 else { return 0 }

        let hopDuration = Double(hopSize) / sampleRate      // seconds per hop
        // 60–180 BPM maps to lag = 60 / (BPM) seconds; faster tempo -> smaller lag.
        let minLag = max(1, Int((60.0 / 180.0) / hopDuration))
        let maxLag = Int((60.0 / 60.0) / hopDuration)
        guard minLag < maxLag, maxLag < count else { return 0 }

        // Mean-remove so the correlation reflects periodicity, not DC energy.
        var mean: Float = 0
        vDSP_meanv(envelope, 1, &mean, vDSP_Length(count))
        var centered = [Float](repeating: 0, count: count)
        var negMean = -mean
        vDSP_vsadd(envelope, 1, &negMean, &centered, 1, vDSP_Length(count))

        var bestLag = 0
        var bestCorr: Float = 0

        centered.withUnsafeBufferPointer { cp in
            guard let base = cp.baseAddress else { return }
            for lag in minLag...maxLag {
                var corr: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &corr, vDSP_Length(count - lag))
                // Normalise by overlap length to avoid bias toward short lags.
                let normalised = corr / Float(count - lag)
                if normalised > bestCorr {
                    bestCorr = normalised
                    bestLag = lag
                }
            }
        }

        guard bestLag > 0, bestCorr > 0 else { return 0 }
        return 60.0 / (Double(bestLag) * Double(hopSize) / sampleRate)
    }
}
