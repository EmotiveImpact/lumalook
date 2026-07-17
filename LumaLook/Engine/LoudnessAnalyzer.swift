import AVFoundation
import Accelerate

/// ITU-R BS.1770-4 integrated loudness (LUFS) measurement. Reads decoded
/// 48 kHz Float32 PCM through an AVAssetReader, applies the two-stage
/// K-weighting filter, splits into overlapping 400 ms blocks, then performs
/// the two-pass (absolute + relative) gating defined by the standard.
enum LoudnessAnalyzer {

    /// Integrated loudness (LUFS) of `url` per BS.1770, or nil on failure.
    static func integratedLUFS(url: URL) async -> Double? {
        await Task.detached(priority: .utility) { await analyze(url: url) }.value
    }

    private static let sampleRate = 48_000.0
    private static let blockSize = 19_200        // 400 ms @ 48 kHz
    private static let hopSize = 4_800           // 100 ms (75% overlap)
    private static let absoluteGate = -70.0
    private static let offset = -0.691
    private static let silenceFloor = -70.0

    private static func analyze(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return nil }
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { reader.cancelReading(); return nil }

            var left = [Float]()
            var right = [Float]()
            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                appendSamples(from: sampleBuffer, into: &left, and: &right)
                CMSampleBufferInvalidate(sampleBuffer)
            }
            let status = reader.status
            reader.cancelReading()
            guard status == .completed else { return nil }
            return integrated(left: left, right: right)
        } catch {
            return nil
        }
    }

    private static func appendSamples(from sampleBuffer: CMSampleBuffer,
                                      into left: inout [Float], and right: inout [Float]) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }
        let floatCount = length / MemoryLayout<Float>.stride
        let frames = floatCount / 2
        guard frames > 0 else { return }
        left.reserveCapacity(left.count + frames)
        right.reserveCapacity(right.count + frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for i in 0..<frames {
                left.append(samples[2 * i])
                right.append(samples[2 * i + 1])
            }
        }
    }

    private static func integrated(left: [Float], right: [Float]) -> Double? {
        var l = left, r = right
        // Stage 1: high-shelf pre-filter.
        applyBiquad(&l, b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                    a1: -1.69065929318241, a2: 0.73248077421585)
        applyBiquad(&r, b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                    a1: -1.69065929318241, a2: 0.73248077421585)
        // Stage 2: RLB high-pass.
        applyBiquad(&l, b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621)
        applyBiquad(&r, b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621)

        let n = min(l.count, r.count)
        guard n >= blockSize else { return nil }
        var blockPowers = [Double]()
        blockPowers.reserveCapacity((n - blockSize) / hopSize + 1)
        l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                var start = 0
                while start + blockSize <= n {
                    var sumL = 0.0, sumR = 0.0
                    let end = start + blockSize
                    var i = start
                    while i < end {
                        let lv = Double(lp[i]), rv = Double(rp[i])
                        sumL += lv * lv; sumR += rv * rv
                        i += 1
                    }
                    blockPowers.append(sumL / Double(blockSize) + sumR / Double(blockSize))
                    start += hopSize
                }
            }
        }
        guard !blockPowers.isEmpty else { return nil }

        var absoluteSum = 0.0, absoluteCount = 0
        for power in blockPowers where power > 0 {
            if offset + 10.0 * log10(power) >= absoluteGate { absoluteSum += power; absoluteCount += 1 }
        }
        guard absoluteCount > 0 else { return silenceFloor }
        let relativeThreshold = offset + 10.0 * log10(absoluteSum / Double(absoluteCount)) - 10.0

        var gatedSum = 0.0, gatedCount = 0
        for power in blockPowers where power > 0 {
            let loudness = offset + 10.0 * log10(power)
            if loudness >= absoluteGate, loudness >= relativeThreshold { gatedSum += power; gatedCount += 1 }
        }
        guard gatedCount > 0 else { return silenceFloor }
        let gatedMeanPower = gatedSum / Double(gatedCount)
        guard gatedMeanPower > 0 else { return silenceFloor }
        return offset + 10.0 * log10(gatedMeanPower)
    }

    /// In-place direct-form-II transposed biquad (a0 == 1), Double state.
    private static func applyBiquad(_ signal: inout [Float],
                                    b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        var z1 = 0.0, z2 = 0.0
        let count = signal.count
        signal.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < count {
                let x = Double(buf[i])
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                buf[i] = Float(y)
                i += 1
            }
        }
    }
}
