import AVFoundation

/// Voice-changer presets (C3): parameter bundles over the bake chain.
enum VoiceEffect: String, Codable, CaseIterable {
    case none, chipmunk, deep, robot, radio, megaphone
    var label: String {
        switch self {
        case .none: return "None"
        case .chipmunk: return "Chipmunk"
        case .deep: return "Deep"
        case .robot: return "Robot"
        case .radio: return "Radio"
        case .megaphone: return "Megaphone"
        }
    }
}

/// Reverb space presets (C4).
enum ReverbPreset: String, Codable, CaseIterable {
    case none, room, hall, cathedral, plate
    var label: String {
        switch self {
        case .none: return "Dry"
        case .room: return "Room"
        case .hall: return "Hall"
        case .cathedral: return "Cathedral"
        case .plate: return "Plate"
        }
    }
    var avPreset: AVAudioUnitReverbPreset {
        switch self {
        case .none, .room: return .mediumRoom
        case .hall: return .largeHall
        case .cathedral: return .cathedral
        case .plate: return .plate
        }
    }
}

/// The full audio effect stack for one lane, baked offline into a cached file.
struct AudioEffectSettings: Codable, Equatable {
    var eqBandGains: [Double]? = nil      // 5 bands @ 80/250/1k/3.5k/10k Hz, ±12 dB
    var eqPresetName: String? = nil
    var pitchSemitones: Double = 0
    var voiceEffect: String? = nil
    var reverbPreset: String? = nil
    var reverbMix: Double = 30            // 0…100 wet %
    var gainDB: Double = 0                // loudness normalization lands here

    var isNeutral: Bool {
        (eqBandGains?.allSatisfy { abs($0) < 0.01 } ?? true) &&
        pitchSemitones == 0 &&
        (voiceEffect == nil || voiceEffect == VoiceEffect.none.rawValue) &&
        (reverbPreset == nil || reverbPreset == ReverbPreset.none.rawValue) &&
        abs(gainDB) < 0.01
    }

    /// Stable key for the render cache.
    var cacheKey: String {
        let eq = eqBandGains?.map { String(format: "%.1f", $0) }.joined(separator: "_") ?? "-"
        return "\(eq)|\(String(format: "%.2f", pitchSemitones))|\(voiceEffect ?? "-")|\(reverbPreset ?? "-")|\(Int(reverbMix))|\(String(format: "%.1f", gainDB))"
            .replacingOccurrences(of: "/", with: "_")
    }
}

/// Offline AVAudioEngine bake: source → TimePitch → EQ(5) → Reverb →
/// Distortion → mainMixer(gain) → cached m4a. Manual-rendering so it's
/// deterministic and identical in preview and export.
final class AudioEffectsRenderer {
    static let shared = AudioEffectsRenderer()

    private var rendersFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Audio/Renders", isDirectory: true)
    }

    /// Returns a processed copy of `source`, or `source` itself if neutral.
    func renderedURL(source: URL, settings: AudioEffectSettings) async throws -> URL {
        guard !settings.isNeutral else { return source }
        try? FileManager.default.createDirectory(at: rendersFolder, withIntermediateDirectories: true)
        let output = rendersFolder.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)-\(settings.cacheKey).m4a")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let sourceFile = try AVAudioFile(forReading: source)
        let format = sourceFile.processingFormat
        let length = sourceFile.length
        guard length > 0 else { return source }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 5)
        let reverb = AVAudioUnitReverb()
        let distortion = AVAudioUnitDistortion()
        for node in [player, timePitch, eq, reverb, distortion] as [AVAudioNode] { engine.attach(node) }

        configure(timePitch: timePitch, eq: eq, reverb: reverb, distortion: distortion, settings: settings)

        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: distortion, format: format)
        engine.connect(distortion, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(pow(10.0, settings.gainDB / 20.0))

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(sourceFile, at: nil, completionHandler: nil)
        player.play()

        // AAC output file.
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000,
        ]
        try? FileManager.default.removeItem(at: output)
        let outFile = try AVAudioFile(forWriting: output, settings: outSettings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            engine.stop()
            throw NSError(domain: "AudioEffectsRenderer", code: 1)
        }

        // Reverb tail: render a little past the source so the wet decays.
        let hasReverb = (settings.reverbPreset.flatMap(ReverbPreset.init) ?? .none) != .none
        let tail = AVAudioFramePosition(hasReverb ? format.sampleRate : 0)
        let total = length + tail
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                try outFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                engine.stop(); player.stop()
                throw NSError(domain: "AudioEffectsRenderer", code: 2)
            @unknown default:
                engine.stop(); player.stop()
                throw NSError(domain: "AudioEffectsRenderer", code: 3)
            }
        }
        player.stop()
        engine.stop()
        return output
    }

    /// Removes cached renders whose cache keys are no longer referenced.
    func pruneCache(keeping keys: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rendersFolder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "m4a" {
            let name = file.deletingPathExtension().lastPathComponent
            if !keys.contains(where: { name.hasSuffix($0) }) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Node configuration

    private func configure(timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ,
                           reverb: AVAudioUnitReverb, distortion: AVAudioUnitDistortion,
                           settings: AudioEffectSettings) {
        // 5-band parametric EQ.
        let freqs: [Float] = [80, 250, 1000, 3500, 10000]
        for (i, band) in eq.bands.enumerated() where i < freqs.count {
            band.filterType = .parametric
            band.frequency = freqs[i]
            band.bandwidth = 1.0
            band.gain = Float(settings.eqBandGains?[safe: i] ?? 0)
            band.bypass = false
        }

        // Voice effect overrides pitch/EQ/distortion; else use explicit pitch.
        let voice = settings.voiceEffect.flatMap(VoiceEffect.init) ?? .none
        timePitch.pitch = Float(settings.pitchSemitones * 100)   // cents
        distortion.wetDryMix = 0

        switch voice {
        case .none: break
        case .chipmunk:
            timePitch.pitch = 700
        case .deep:
            timePitch.pitch = -600
        case .robot:
            distortion.loadFactoryPreset(.multiEcho1)
            distortion.wetDryMix = 45
        case .radio:
            eq.bands[0].gain = -18; eq.bands[1].gain = -6
            eq.bands[4].gain = -18
            distortion.loadFactoryPreset(.speechRadioTower)
            distortion.wetDryMix = 25
        case .megaphone:
            eq.bands[0].gain = -12; eq.bands[4].gain = -10
            eq.bands[2].gain = 6
            distortion.loadFactoryPreset(.speechCosmicInterference)
            distortion.wetDryMix = 30
        }

        // Reverb.
        let space = settings.reverbPreset.flatMap(ReverbPreset.init) ?? .none
        if space != .none {
            reverb.loadFactoryPreset(space.avPreset)
            reverb.wetDryMix = Float(min(max(0, settings.reverbMix), 100))
        } else {
            reverb.wetDryMix = 0
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
