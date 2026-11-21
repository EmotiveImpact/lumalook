import Foundation
import AVFoundation

// MARK: - Music synth
//
// LumaLook's royalty-free music library is rendered on the phone, so there is
// nothing to license and nothing to download. Every track is built from a
// four-bar loop of stems (kick, snare, hats, percussion, bass, chords, lead and
// an FX bed) synthesised with plain oscillators, filtered noise and envelopes,
// then arranged into eight-bar sections that bring stems in and out. The bar
// grid is exact, so the beat times are known rather than detected.
//
// Deterministic: a track's seed drives every random choice (noise, velocity
// humanising, which lead line is used), so a track renders the same samples on
// every device, every time.

/// xorshift32: tiny, fast and identical everywhere.
struct SynthRandom {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed == 0 ? 0x9E37_79B9 : seed
    }

    mutating func next() -> UInt32 {
        var x = state
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        state = x
        return x
    }

    /// 0 ..< 1
    mutating func unit() -> Float {
        Float(next() >> 8) / 16_777_216
    }

    /// -1 ..< 1
    mutating func bipolar() -> Float {
        unit() * 2 - 1
    }
}

// MARK: - DSP helpers

enum SynthDSP {
    static let sampleRate: Float = 44100

    /// One cycle of sine plus a guard sample, read with linear interpolation.
    static let sineTable: UnsafeMutablePointer<Float> = {
        let table = UnsafeMutablePointer<Float>.allocate(capacity: 4097)
        for i in 0...4096 {
            table[i] = Float(sin(Double(i) / 4096.0 * 2.0 * Double.pi))
        }
        return table
    }()

    /// sin(2π · phase), phase in cycles (any value).
    @inline(__always)
    static func sine(_ phase: Float) -> Float {
        let wrapped = phase - phase.rounded(.down)
        let x = wrapped * 4096
        let index = min(4095, max(0, Int(x)))
        let frac = x - Float(index)
        let a = sineTable[index]
        let b = sineTable[index + 1]
        return a + (b - a) * frac
    }

    /// Band-limited step correction for a sawtooth (polyBLEP).
    @inline(__always)
    static func blep(_ t: Float, _ dt: Float) -> Float {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    static func hz(_ midi: Int) -> Float {
        440 * pow(2, Float(midi - 69) / 12)
    }

    /// Per-sample multiplier for an exponential decay with time constant `tau` seconds.
    static func decay(_ tau: Float) -> Float {
        exp(-1 / (max(tau, 0.0001) * sampleRate))
    }

    /// One-pole lowpass coefficient for a cutoff in Hz.
    static func onePole(_ hz: Float) -> Float {
        1 - exp(-2 * Float.pi * hz / sampleRate)
    }

    /// Chamberlin state-variable filter frequency coefficient (kept stable).
    static func svf(_ hz: Float) -> Float {
        min(1.3, 2 * sin(Float.pi * min(hz, 8000) / sampleRate))
    }

    /// Scales a one-shot so its loudest sample sits at `peak`.
    static func normalised(_ samples: [Float], peak: Float) -> [Float] {
        var top: Float = 0
        for s in samples { top = max(top, abs(s)) }
        guard top > 0.000_01 else { return samples }
        let gain = peak / top
        return samples.map { $0 * gain }
    }

    /// Short linear fade at the end so a one-shot never stops on a click.
    static func fadeTail(_ samples: inout [Float], seconds: Float = 0.01) {
        let n = min(samples.count, Int(seconds * sampleRate))
        guard n > 1 else { return }
        let start = samples.count - n
        for i in 0..<n {
            samples[start + i] *= Float(n - 1 - i) / Float(n - 1)
        }
    }
}

// MARK: - Stereo buffer

/// Stereo float buffer on manual memory, fast in debug builds too.
final class SynthBuffer {
    let count: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    init(count: Int) {
        self.count = max(1, count)
        left = UnsafeMutablePointer<Float>.allocate(capacity: self.count)
        right = UnsafeMutablePointer<Float>.allocate(capacity: self.count)
        left.initialize(repeating: 0, count: self.count)
        right.initialize(repeating: 0, count: self.count)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func clear() {
        left.initialize(repeating: 0, count: count)
        right.initialize(repeating: 0, count: count)
    }

    /// Adds a mono source at `start`, wrapping round the end (loop buffers
    /// are circular, so a tail that runs past bar four lands on bar one).
    func addWrapped(_ source: [Float], at start: Int, gainL: Float, gainR: Float) {
        guard !source.isEmpty else { return }
        var j = start % count
        if j < 0 { j += count }
        source.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            for i in 0..<src.count {
                left[j] += s[i] * gainL
                right[j] += s[i] * gainR
                j += 1
                if j == count { j = 0 }
            }
        }
    }

    /// Adds a mono source at `start`, dropping whatever falls outside.
    func addClipped(_ source: [Float], at start: Int, gainL: Float, gainR: Float) {
        guard !source.isEmpty else { return }
        source.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            for i in 0..<src.count {
                let j = start + i
                if j < 0 { continue }
                if j >= count { break }
                left[j] += s[i] * gainL
                right[j] += s[i] * gainR
            }
        }
    }

    static func pan(_ pan: Float, gain: Float) -> (Float, Float) {
        (gain * min(1, 1 - pan), gain * min(1, 1 + pan))
    }
}

// MARK: - Recipe

enum SynthKick { case punchy, soft, deep, taiko }
enum SynthSnare { case snare, clap, snap, rim, big }
enum SynthPerc { case shaker, conga, rim, tick, none }
enum SynthBass { case synth, sub, eight08, log, reese }
enum SynthChords { case pad, keys, stab, strings, piano }
enum SynthLead { case pluck, bell, guitar, keys, piano, none }

/// A genre as patterns and instrument choices. Patterns are sixteen-step bar
/// strings; a pattern with two bars alternates.
///
/// Drums: `x` hit, `o` ghost (soft), `.` rest. Hats add `O` open, `r` a
/// double (two 32nds) and `t` a triplet roll. Congas use `h` high, `l` low.
/// Bass: `R` chord root, `3` third, `5` fifth, `7` seventh, `8` octave, `-`
/// holds the note. Chords: `x` hit, `-` hold. Lead: `1`…`6` are chord tones
/// from the root up (4…6 an octave higher), `-` holds.
struct SynthRecipe {
    var kick: [String] = []
    var snare: [String] = []
    var hats: [String] = []
    var perc: [String] = []
    var bass: [String] = []
    var chords: [String] = []
    var leads: [[String]] = []
    var swing: Float = 0
    var kickKind: SynthKick = .punchy
    var snareKind: SynthSnare = .clap
    var percKind: SynthPerc = .none
    var bassKind: SynthBass = .synth
    var chordKind: SynthChords = .pad
    var leadKind: SynthLead = .none
    var sevenths = false
    var sidechain: Float = 0
    var reverb: Float = 0.3
    var lofi = false
    var crash = true
    var riser = true

    // swiftlint:disable:next function_body_length
    static func recipe(for genre: MusicGenre) -> SynthRecipe {
        var r = SynthRecipe()
        switch genre {
        case .afrobeats:
            r.kick = ["x..x..x.x.......", "x..x..x...x..x.."]
            r.snare = ["....x.......x...", "....x.......x..o"]
            r.hats = ["oxoxoxoxoxoxoxox"]
            r.perc = ["..h..l.h..h.l...", "..h..l.h.hh.l.l."]
            r.bass = ["R--R--5-R-..8-5-"]
            r.chords = ["x---------------"]
            r.leads = [["1.3.4.3.2.3.4.3."], ["4.3.1.3.4.5.4.3.", "1.3.2.3.4.3.2.1."]]
            r.swing = 0.06
            r.kickKind = .soft
            r.snareKind = .clap
            r.percKind = .conga
            r.bassKind = .sub
            r.chordKind = .pad
            r.leadKind = .guitar
            r.reverb = 0.25
        case .amapiano:
            r.kick = ["x.......x.......", "x.......x...x..."]
            r.snare = ["....x.......x..."]
            r.hats = ["oxoxoxoxoxoxoxox"]
            r.perc = ["...x..x.......x.", "...x..x....x..x."]
            r.bass = ["R..R..R...8.5...", "R..R..5...R.8..."]
            r.chords = ["x-.x-.x-..x-.x-."]
            r.leads = [["4.....3.....2...", "................"],
                       ["..3...4...5.4...", "..3...2...1....."]]
            r.swing = 0.1
            r.kickKind = .deep
            r.snareKind = .clap
            r.percKind = .rim
            r.bassKind = .log
            r.chordKind = .piano
            r.leadKind = .bell
            r.sevenths = true
            r.reverb = 0.3
        case .house:
            r.kick = ["x...x...x...x..."]
            r.snare = ["....x.......x..."]
            r.hats = ["o.O.o.O.o.O.o.Oo"]
            r.perc = ["...x.....x....x."]
            r.bass = ["..R-..R-..R-..8-"]
            r.chords = ["...x..x...x..x..", "..x...x..x..x..."]
            r.leads = [["1.2.3.4.3.2.1.2."], ["4.3.1.3.4.3.1.3."]]
            r.kickKind = .punchy
            r.snareKind = .clap
            r.percKind = .rim
            r.bassKind = .synth
            r.chordKind = .stab
            r.leadKind = .pluck
            r.sevenths = true
            r.sidechain = 0.55
            r.reverb = 0.3
        case .garage:
            r.kick = ["x.........x.....", "x......x..x....."]
            r.snare = ["....x.......x...", "....x.......x..o"]
            r.hats = ["..x...x...x...xx", "..x.o.x...x.o.xx"]
            r.perc = ["...x..x....x..x."]
            r.bass = ["R-----..R---5---", "R-----..8---5-3-"]
            r.chords = ["..x..x....x..x..", "..x..x...x...x.."]
            r.leads = [["....3.2.....1...", "....3.2...4.3..."]]
            r.swing = 0.2
            r.kickKind = .punchy
            r.snareKind = .snare
            r.percKind = .rim
            r.bassKind = .reese
            r.chordKind = .stab
            r.leadKind = .pluck
            r.sevenths = true
            r.sidechain = 0.35
            r.reverb = 0.3
        case .drill:
            r.kick = ["x......x..x.....", "x.........x..x.."]
            r.snare = ["........x.......", "........x.....o."]
            r.hats = ["x..x..x.x..x..x.", "x..x..x.x..xr.x."]
            r.perc = ["................"]
            r.bass = ["R-------5-----7-", "R-----3-------5-"]
            r.chords = ["x---------------"]
            r.leads = [["1..2..3.....2...", "1..2..4.....3..."],
                       ["3..2..1.........", "3..4..5...4....."]]
            r.kickKind = .punchy
            r.snareKind = .snare
            r.percKind = .none
            r.bassKind = .eight08
            r.chordKind = .strings
            r.leadKind = .bell
            r.reverb = 0.35
        case .lofi:
            r.kick = ["x......x..x.....", "x.x.......x....."]
            r.snare = ["....x.......x...", "....x..o....x..."]
            r.hats = ["x.o.x.o.x.o.x.oo"]
            r.perc = ["................"]
            r.bass = ["R-----..5---3---"]
            r.chords = ["x-------x-----x-"]
            r.leads = [["..3...2.....1...", "........4...3..."]]
            r.swing = 0.22
            r.kickKind = .soft
            r.snareKind = .snare
            r.percKind = .none
            r.bassKind = .sub
            r.chordKind = .keys
            r.leadKind = .keys
            r.sevenths = true
            r.reverb = 0.3
            r.lofi = true
            r.crash = false
            r.riser = false
        case .pop:
            r.kick = ["x...x...x...x...", "x...x...x...x.x."]
            r.snare = ["....x.......x..."]
            r.hats = ["x.x.x.x.x.x.x.x."]
            r.perc = ["..x...x...x...x."]
            r.bass = ["R.R.R.R.R.R.5.R.", "R.R.R.R.R.R.8.5."]
            r.chords = ["x---x---x---x-x-"]
            r.leads = [["1.3.4.3.2.3.4.3."], ["4...3...2.3.4..."]]
            r.kickKind = .punchy
            r.snareKind = .clap
            r.percKind = .shaker
            r.bassKind = .synth
            r.chordKind = .piano
            r.leadKind = .pluck
            r.sidechain = 0.3
            r.reverb = 0.3
        case .cinematic:
            r.kick = ["x.......x..x....", "x.....x.x......."]
            r.snare = ["........x.......", "........x......."]
            r.hats = ["................"]
            r.perc = ["x.o.x.o.x.o.x.o."]
            r.bass = ["R---------------"]
            r.chords = ["x---------------"]
            r.leads = [["1...2...3.......", "5...4...3...2..."],
                       ["3.......2...1...", "4.......5......."]]
            r.kickKind = .taiko
            r.snareKind = .big
            r.percKind = .tick
            r.bassKind = .sub
            r.chordKind = .strings
            r.leadKind = .piano
            r.reverb = 0.5
        case .trap:
            r.kick = ["x.........x.....", "x......x.x......"]
            r.snare = ["........x.......", "........x......."]
            r.hats = ["x.x.x.x.x.x.x.x.", "x.x.x.x.x.ttx.rr"]
            r.perc = ["................"]
            r.bass = ["R---------R---5-", "R-------R---3---"]
            r.chords = ["x---------------"]
            r.leads = [["1.3.2.4.3.2.1...", "1.3.2.5.4.3.2..."]]
            r.kickKind = .punchy
            r.snareKind = .clap
            r.percKind = .none
            r.bassKind = .eight08
            r.chordKind = .pad
            r.leadKind = .bell
            r.reverb = 0.35
        case .rnb:
            r.kick = ["x......x..x.....", "x.........x..x.."]
            r.snare = ["....x.......x...", "....x.......x..o"]
            r.hats = ["x.x.x.xxx.x.x.x.", "x.x.x.x.x.x.xtx."]
            r.perc = ["..x.....x....x..", "..x.....x......."]
            r.bass = ["R------.R---7---", "R------.5---3---"]
            r.chords = ["x-------x-------"]
            r.leads = [["....3...2.......", "....4...3...2..."]]
            r.swing = 0.12
            r.kickKind = .soft
            r.snareKind = .snap
            r.percKind = .rim
            r.bassKind = .sub
            r.chordKind = .keys
            r.leadKind = .bell
            r.sevenths = true
            r.reverb = 0.35
        }
        return r
    }
}

// MARK: - Voices

/// Instrument voices. Every function returns mono samples at 44.1 kHz.
enum SynthVoice {
    static let sr = SynthDSP.sampleRate

    // MARK: Drums

    static func kick(_ kind: SynthKick, rng: inout SynthRandom) -> [Float] {
        var tune: Float = 52
        var sweep: Float = 3
        var decay: Float = 0.3
        var click: Float = 0.5
        var length: Float = 0.5
        var drive: Float = 1.8
        switch kind {
        case .punchy: break
        case .soft:
            tune = 55; sweep = 2.2; decay = 0.24; click = 0.18; length = 0.45; drive = 1.2
        case .deep:
            tune = 47; sweep = 2.6; decay = 0.5; click = 0.25; length = 0.8; drive = 1.5
        case .taiko:
            tune = 68; sweep = 0.9; decay = 0.42; click = 0.6; length = 0.9; drive = 1.4
        }
        let n = Int(length * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        var amp: Float = 1
        let ampMul = SynthDSP.decay(decay)
        var pitch: Float = 1
        let pitchMul = SynthDSP.decay(0.035)
        var clickEnv = click
        let clickMul = SynthDSP.decay(0.004)
        var noise: Float = 0
        let noiseA = SynthDSP.onePole(kind == .taiko ? 900 : 3000)
        let skin: Float = kind == .taiko ? 0.25 : 0
        let norm = tanh(drive)
        for i in 0..<n {
            let f = tune * (1 + sweep * pitch)
            phase += f / sr
            if phase >= 1 { phase -= 1 }
            noise += noiseA * (rng.bipolar() - noise)
            let body = SynthDSP.sine(phase) * amp
            let s = body + noise * (clickEnv + skin * amp)
            out[i] = tanh(s * drive) / norm
            amp *= ampMul
            pitch *= pitchMul
            clickEnv *= clickMul
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func snare(_ kind: SynthSnare, rng: inout SynthRandom) -> [Float] {
        switch kind {
        case .snare: return snareDrum(body: 185, bodyDecay: 0.07, noiseDecay: 0.15, length: 0.4, rng: &rng)
        case .big: return snareDrum(body: 160, bodyDecay: 0.12, noiseDecay: 0.3, length: 0.8, rng: &rng)
        case .clap: return clap(rng: &rng)
        case .snap: return snap(rng: &rng)
        case .rim: return rim()
        }
    }

    static func snareDrum(body: Float, bodyDecay: Float, noiseDecay: Float,
                          length: Float, rng: inout SynthRandom) -> [Float] {
        let n = Int(length * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        var bodyAmp: Float = 0.7
        let bodyMul = SynthDSP.decay(bodyDecay)
        var noiseAmp: Float = 0.8
        let noiseMul = SynthDSP.decay(noiseDecay)
        var pitch: Float = 1
        let pitchMul = SynthDSP.decay(0.01)
        var low: Float = 0
        let lowA = SynthDSP.onePole(900)
        for i in 0..<n {
            phase += body * (1 + 0.5 * pitch) / sr
            if phase >= 1 { phase -= 1 }
            let x = rng.bipolar()
            low += lowA * (x - low)
            let high = x - low
            out[i] = SynthDSP.sine(phase) * bodyAmp + high * noiseAmp
            bodyAmp *= bodyMul
            noiseAmp *= noiseMul
            pitch *= pitchMul
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func clap(rng: inout SynthRandom) -> [Float] {
        let n = Int(0.45 * sr)
        var out = [Float](repeating: 0, count: n)
        var low: Float = 0
        var band: Float = 0
        let f = SynthDSP.svf(1300)
        let damping: Float = 0.7
        for i in 0..<n {
            let t = Float(i) / sr
            var env: Float = 0
            for k in 0..<3 {
                let start = Float(k) * 0.011
                if t >= start { env = max(env, exp(-(t - start) / 0.0045)) }
            }
            if t >= 0.022 { env = max(env, 0.7 * exp(-(t - 0.022) / 0.11)) }
            let x = rng.bipolar()
            low += f * band
            let high = x - low - damping * band
            band += f * high
            out[i] = band * env
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func snap(rng: inout SynthRandom) -> [Float] {
        let n = Int(0.18 * sr)
        var out = [Float](repeating: 0, count: n)
        var low: Float = 0
        var band: Float = 0
        let f = SynthDSP.svf(2400)
        var amp: Float = 1
        let mul = SynthDSP.decay(0.035)
        for i in 0..<n {
            let x = rng.bipolar()
            low += f * band
            let high = x - low - 0.5 * band
            band += f * high
            out[i] = band * amp
            amp *= mul
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func rim() -> [Float] {
        let n = Int(0.08 * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / sr
            let a = SynthDSP.sine(1700 * t) * exp(-t / 0.012)
            let b = SynthDSP.sine(2900 * t) * 0.5 * exp(-t / 0.008)
            out[i] = a + b
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    /// 808-style metal (six detuned squares) plus noise, high-passed hard.
    static func hat(open: Bool, rng: inout SynthRandom) -> [Float] {
        let n = Int((open ? 0.6 : 0.12) * sr)
        var out = [Float](repeating: 0, count: n)
        let freqs: [Float] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]
        var phases: [Float] = [0, 0.13, 0.27, 0.41, 0.58, 0.77]
        var low1: Float = 0
        var low2: Float = 0
        let a = SynthDSP.onePole(7000)
        var amp: Float = 1
        let mul = SynthDSP.decay(open ? 0.22 : 0.035)
        for i in 0..<n {
            var metal: Float = 0
            for k in 0..<6 {
                phases[k] += freqs[k] / sr
                if phases[k] >= 1 { phases[k] -= 1 }
                metal += phases[k] < 0.5 ? 1 : -1
            }
            let x = metal * 0.12 + rng.bipolar() * 0.6
            low1 += a * (x - low1)
            let high1 = x - low1
            low2 += a * (high1 - low2)
            let high2 = high1 - low2
            out[i] = high2 * amp
            amp *= mul
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func shaker(rng: inout SynthRandom) -> [Float] {
        let n = Int(0.12 * sr)
        var out = [Float](repeating: 0, count: n)
        var low: Float = 0
        let a = SynthDSP.onePole(5000)
        for i in 0..<n {
            let t = Float(i) / sr
            let env = t < 0.01 ? t / 0.01 : exp(-(t - 0.01) / 0.045)
            let x = rng.bipolar()
            low += a * (x - low)
            out[i] = (x - low) * env
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func conga(pitch: Float, rng: inout SynthRandom) -> [Float] {
        let n = Int(0.3 * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            phase += pitch * (1 + 0.25 * exp(-t / 0.015)) / sr
            if phase >= 1 { phase -= 1 }
            let slap = t < 0.003 ? rng.bipolar() * 0.4 * (1 - t / 0.003) : 0
            out[i] = SynthDSP.sine(phase) * exp(-t / 0.16) + slap
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func tick() -> [Float] {
        let n = Int(0.05 * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / sr
            out[i] = (SynthDSP.sine(2500 * t) + 0.6 * SynthDSP.sine(4100 * t)) * exp(-t / 0.01)
        }
        SynthDSP.fadeTail(&out)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    static func crash(rng: inout SynthRandom) -> [Float] {
        let n = Int(2.4 * sr)
        var out = [Float](repeating: 0, count: n)
        let freqs: [Float] = [349, 517, 628, 888, 917, 1360]
        var phases: [Float] = [0, 0.21, 0.37, 0.52, 0.66, 0.83]
        var low1: Float = 0
        var low2: Float = 0
        let a = SynthDSP.onePole(4500)
        var amp: Float = 1
        let mul = SynthDSP.decay(1.0)
        for i in 0..<n {
            var metal: Float = 0
            for k in 0..<6 {
                phases[k] += freqs[k] / sr
                if phases[k] >= 1 { phases[k] -= 1 }
                metal += phases[k] < 0.5 ? 1 : -1
            }
            let x = metal * 0.08 + rng.bipolar() * 0.7
            low1 += a * (x - low1)
            let high1 = x - low1
            low2 += a * (high1 - low2)
            out[i] = (high1 - low2) * amp
            amp *= mul
        }
        SynthDSP.fadeTail(&out, seconds: 0.2)
        return SynthDSP.normalised(out, peak: 0.9)
    }

    /// White noise swept up through a band-pass, swelling into the drop.
    static func riser(length: Int, rng: inout SynthRandom) -> [Float] {
        let n = max(1, length)
        var out = [Float](repeating: 0, count: n)
        var low: Float = 0
        var band: Float = 0
        for i in 0..<n {
            let p = Float(i) / Float(n)
            let hz = 300 * pow(20, p)
            let f = SynthDSP.svf(hz)
            let x = rng.bipolar()
            low += f * band
            let high = x - low - 0.6 * band
            band += f * high
            out[i] = band * p * p
        }
        return SynthDSP.normalised(out, peak: 0.8)
    }

    /// Vinyl bed for lo-fi: sparse crackle over a low hiss.
    static func crackle(length: Int, rng: inout SynthRandom) -> [Float] {
        let n = max(1, length)
        var out = [Float](repeating: 0, count: n)
        var pop: Float = 0
        let popMul = SynthDSP.decay(0.0015)
        var hiss: Float = 0
        let hissA = SynthDSP.onePole(2500)
        for i in 0..<n {
            if rng.unit() < 0.0004 { pop = (0.3 + 0.7 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1) }
            hiss += hissA * (rng.bipolar() - hiss)
            out[i] = pop * rng.unit() + hiss * 0.08
            pop *= popMul
        }
        return out
    }

    // MARK: Bass

    /// One bass note, `length` samples long plus its release.
    static func bass(_ kind: SynthBass, midi: Int, length: Int, glideFrom: Int?,
                     rng: inout SynthRandom) -> [Float] {
        let f = SynthDSP.hz(midi)
        switch kind {
        case .synth: return synthBass(f, length: length)
        case .sub: return subBass(f, length: length)
        case .eight08: return bass808(f, length: length, from: glideFrom.map { SynthDSP.hz($0) })
        case .log: return logDrum(f, length: length)
        case .reese: return reese(f, length: length)
        }
    }

    /// Attack / hold / release gain for a note at sample `i`.
    @inline(__always)
    static func gate(_ i: Int, length: Int, attack: Float, release: Float) -> Float {
        let t = Float(i) / sr
        let att = t < attack ? t / attack : 1
        if i < length { return att }
        let r = Float(i - length) / sr
        return att * max(0, 1 - r / release)
    }

    static func synthBass(_ f: Float, length: Int) -> [Float] {
        let release: Float = 0.03
        let n = length + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        let dt = f / sr
        var low: Float = 0
        var band: Float = 0
        var env: Float = 1
        let envMul = SynthDSP.decay(0.09)
        for i in 0..<n {
            phase += dt
            if phase >= 1 { phase -= 1 }
            let saw = 2 * phase - 1 - SynthDSP.blep(phase, dt)
            let sub = SynthDSP.sine(phase)
            let x = saw * 0.6 + sub * 0.5
            let cf = SynthDSP.svf(220 + 1800 * env)
            low += cf * band
            let high = x - low - 0.5 * band
            band += cf * high
            out[i] = low * gate(i, length: length, attack: 0.004, release: release) * 0.8
            env *= envMul
        }
        return out
    }

    static func subBass(_ f: Float, length: Int) -> [Float] {
        let release: Float = 0.05
        let n = length + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        let dt = f / sr
        let norm = tanh(Float(1.4))
        for i in 0..<n {
            phase += dt
            if phase >= 1 { phase -= 1 }
            let x = SynthDSP.sine(phase) + 0.25 * SynthDSP.sine(phase * 2)
            let g = gate(i, length: length, attack: 0.006, release: release)
            out[i] = tanh(x * 1.4) / norm * g * 0.85
        }
        return out
    }

    static func bass808(_ f: Float, length: Int, from: Float?) -> [Float] {
        let release: Float = 0.04
        let n = length + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        var freq = from ?? f
        let glide = SynthDSP.decay(0.035)
        var punch: Float = 1
        let punchMul = SynthDSP.decay(0.02)
        var amp: Float = 1
        let ampMul = SynthDSP.decay(1.4)
        let norm = tanh(Float(2.2))
        for i in 0..<n {
            freq = f + (freq - f) * glide
            phase += freq * (1 + 0.4 * punch) / sr
            if phase >= 1 { phase -= 1 }
            let g = gate(i, length: length, attack: 0.003, release: release)
            out[i] = tanh(SynthDSP.sine(phase) * 2.2) / norm * amp * g * 0.9
            punch *= punchMul
            amp *= ampMul
        }
        return out
    }

    /// Amapiano's log drum: a pitched, saturated knock with a fast drop.
    static func logDrum(_ f: Float, length: Int) -> [Float] {
        let ring = min(length, Int(0.45 * sr))
        let release: Float = 0.04
        let n = ring + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        var drop: Float = 1
        let dropMul = SynthDSP.decay(0.012)
        var amp: Float = 1
        let ampMul = SynthDSP.decay(0.22)
        var second: Float = 0.35
        let secondMul = SynthDSP.decay(0.08)
        var low: Float = 0
        let lowA = SynthDSP.onePole(1800)
        let norm = tanh(Float(2.5))
        for i in 0..<n {
            phase += f * (1 + 0.9 * drop) / sr
            if phase >= 1 { phase -= 1 }
            let x = SynthDSP.sine(phase) + second * SynthDSP.sine(phase * 2)
            let y = tanh(x * 2.5) / norm
            low += lowA * (y - low)
            let g = gate(i, length: ring, attack: 0.002, release: release)
            out[i] = low * amp * g * 0.9
            drop *= dropMul
            amp *= ampMul
            second *= secondMul
        }
        return out
    }

    static func reese(_ f: Float, length: Int) -> [Float] {
        let release: Float = 0.05
        let n = length + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var p1: Float = 0
        var p2: Float = 0.5
        var p3: Float = 0
        let d1 = f * 1.007 / sr
        let d2 = f * 0.993 / sr
        let d3 = f / sr
        var low: Float = 0
        var band: Float = 0
        for i in 0..<n {
            p1 += d1; if p1 >= 1 { p1 -= 1 }
            p2 += d2; if p2 >= 1 { p2 -= 1 }
            p3 += d3; if p3 >= 1 { p3 -= 1 }
            let saw1 = 2 * p1 - 1 - SynthDSP.blep(p1, d1)
            let saw2 = 2 * p2 - 1 - SynthDSP.blep(p2, d2)
            let t = Float(i) / sr
            let cf = SynthDSP.svf(380 + 160 * SynthDSP.sine(0.3 * t))
            let x = (saw1 + saw2) * 0.4
            low += cf * band
            let high = x - low - 0.6 * band
            band += cf * high
            let g = gate(i, length: length, attack: 0.008, release: release)
            out[i] = (low * 0.8 + SynthDSP.sine(p3) * 0.5) * g * 0.8
        }
        return out
    }

    // MARK: Chords and leads

    /// Two detuned saws through a soft two-pole low-pass. Rendered once per
    /// side with mirrored detune so the pad is wide.
    static func padNote(_ f: Float, length: Int, detune: Float, cutoff: Float,
                        attack: Float, release: Float) -> [Float] {
        let n = length + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        let ratio = pow(2, detune / 1200)
        let d1 = f * ratio / sr
        let d2 = f / ratio / sr
        var p1: Float = 0
        var p2: Float = 0.37
        var low1: Float = 0
        var low2: Float = 0
        let a = SynthDSP.onePole(cutoff)
        for i in 0..<n {
            p1 += d1; if p1 >= 1 { p1 -= 1 }
            p2 += d2; if p2 >= 1 { p2 -= 1 }
            let saw1 = 2 * p1 - 1 - SynthDSP.blep(p1, d1)
            let saw2 = 2 * p2 - 1 - SynthDSP.blep(p2, d2)
            let x = (saw1 + saw2) * 0.5
            low1 += a * (x - low1)
            low2 += a * (low1 - low2)
            out[i] = low2 * gate(i, length: length, attack: attack, release: release)
        }
        return out
    }

    /// Two-operator FM electric piano: bright on the strike, mellow as it rings.
    static func keysNote(_ f: Float, length: Int, brightness: Float) -> [Float] {
        let release: Float = 0.08
        let ring = Int(2.5 * sr)
        let n = min(length, ring) + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var pc: Float = 0
        var pm: Float = 0
        let dt = f / sr
        var index: Float = 1.6 * brightness
        let indexMul = SynthDSP.decay(0.25)
        var amp: Float = 1
        let ampMul = SynthDSP.decay(1.6)
        var tine: Float = 0.12 * brightness
        let tineMul = SynthDSP.decay(0.03)
        let held = min(length, ring)
        for i in 0..<n {
            pm += dt; if pm >= 1 { pm -= 1 }
            pc += dt; if pc >= 1 { pc -= 1 }
            let mod = SynthDSP.sine(pm) * (index + 0.12)
            let car = SynthDSP.sine(pc + mod / (2 * Float.pi))
            let bell = SynthDSP.sine(pc * 7) * tine
            out[i] = (car + bell) * amp * gate(i, length: held, attack: 0.003, release: release)
            index *= indexMul
            amp *= ampMul
            tine *= tineMul
        }
        return out
    }

    /// Short filtered saw chord stab.
    static func stabNote(_ f: Float, length: Int) -> [Float] {
        let held = min(length, Int(0.22 * sr))
        let release: Float = 0.03
        let n = held + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        let d1 = f * 1.004 / sr
        let d2 = f * 0.996 / sr
        var p1: Float = 0
        var p2: Float = 0.5
        var low: Float = 0
        var band: Float = 0
        var env: Float = 1
        let envMul = SynthDSP.decay(0.06)
        var amp: Float = 1
        let ampMul = SynthDSP.decay(0.14)
        for i in 0..<n {
            p1 += d1; if p1 >= 1 { p1 -= 1 }
            p2 += d2; if p2 >= 1 { p2 -= 1 }
            let saw1 = 2 * p1 - 1 - SynthDSP.blep(p1, d1)
            let saw2 = 2 * p2 - 1 - SynthDSP.blep(p2, d2)
            let cf = SynthDSP.svf(400 + 3000 * env)
            let x = (saw1 + saw2) * 0.5
            low += cf * band
            let high = x - low - 0.7 * band
            band += cf * high
            out[i] = low * amp * gate(i, length: held, attack: 0.002, release: release)
            env *= envMul
            amp *= ampMul
        }
        return out
    }

    /// Three slow saws with a little vibrato: a string section in miniature.
    static func stringsNote(_ f: Float, length: Int, detune: Float) -> [Float] {
        let release: Float = 0.7
        let n = length + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        let spread: [Float] = [pow(2, -detune / 1200), 1, pow(2, detune / 1200)]
        var phases: [Float] = [0, 0.33, 0.66]
        var low1: Float = 0
        var low2: Float = 0
        let a = SynthDSP.onePole(2400)
        for i in 0..<n {
            let t = Float(i) / sr
            let vibrato = 1 + 0.0025 * min(1, t / 0.6) * SynthDSP.sine(5.2 * t)
            var x: Float = 0
            for k in 0..<3 {
                let dt = f * spread[k] * vibrato / sr
                phases[k] += dt
                if phases[k] >= 1 { phases[k] -= 1 }
                x += 2 * phases[k] - 1 - SynthDSP.blep(phases[k], dt)
            }
            low1 += a * (x / 3 - low1)
            low2 += a * (low1 - low2)
            out[i] = low2 * gate(i, length: length, attack: 0.45, release: release)
        }
        return out
    }

    /// Additive piano: six slightly stretched partials, the high ones dying first.
    static func pianoNote(_ f: Float, length: Int) -> [Float] {
        let release: Float = 0.12
        let ring = Int(3.0 * sr)
        let held = min(length, ring)
        let n = held + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        let partialAmps: [Float] = [1, 0.5, 0.32, 0.2, 0.12, 0.08]
        var phases = [Float](repeating: 0, count: 6)
        var steps = [Float](repeating: 0, count: 6)
        var amps = [Float](repeating: 0, count: 6)
        var muls = [Float](repeating: 0, count: 6)
        for k in 0..<6 {
            let h = Float(k + 1)
            steps[k] = f * h * (1 + 0.0004 * h * h).squareRoot() / sr
            amps[k] = partialAmps[k]
            muls[k] = SynthDSP.decay(1.8 / (1 + 0.6 * h))
        }
        for i in 0..<n {
            var x: Float = 0
            for k in 0..<6 {
                phases[k] += steps[k]
                if phases[k] >= 1 { phases[k] -= 1 }
                x += SynthDSP.sine(phases[k]) * amps[k]
                amps[k] *= muls[k]
            }
            out[i] = x * 0.45 * gate(i, length: held, attack: 0.002, release: release)
        }
        return out
    }

    /// Karplus-Strong plucked string (the guitar and the pluck lead).
    static func pluck(_ f: Float, length: Int, damping: Float, brightness: Float,
                      rng: inout SynthRandom) -> [Float] {
        let release: Float = 0.05
        let ring = min(length + Int(0.4 * sr), Int(1.6 * sr))
        let n = ring + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        let period = max(2, Int((sr / f).rounded()))
        var line = [Float](repeating: 0, count: period)
        // Excitation: noise softened by a one-pole, so the attack is not harsh.
        var soft: Float = 0
        let softA = SynthDSP.onePole(1500 + 6000 * brightness)
        for k in 0..<period {
            soft += softA * (rng.bipolar() - soft)
            line[k] = soft
        }
        var index = 0
        for i in 0..<n {
            let next = index + 1 == period ? 0 : index + 1
            let current = line[index]
            line[index] = (current + line[next]) * 0.5 * damping
            out[i] = current * gate(i, length: ring, attack: 0.001, release: release)
            index = next
        }
        return SynthDSP.normalised(out, peak: 0.8)
    }

    /// FM bell: an inharmonic ratio with a fast-falling index.
    static func bell(_ f: Float, length: Int) -> [Float] {
        let release: Float = 0.1
        let held = min(length + Int(0.3 * sr), Int(1.8 * sr))
        let n = held + Int(release * sr)
        var out = [Float](repeating: 0, count: n)
        var pc: Float = 0
        var pm: Float = 0
        let dc = f / sr
        let dm = f * 3.5 / sr
        var index: Float = 2.4
        let indexMul = SynthDSP.decay(0.25)
        var amp: Float = 1
        let ampMul = SynthDSP.decay(0.9)
        for i in 0..<n {
            pc += dc; if pc >= 1 { pc -= 1 }
            pm += dm; if pm >= 1 { pm -= 1 }
            let mod = SynthDSP.sine(pm) * index
            out[i] = SynthDSP.sine(pc + mod / (2 * Float.pi)) * amp
                * gate(i, length: held, attack: 0.002, release: release)
            index *= indexMul
            amp *= ampMul
        }
        return out
    }
}

// MARK: - Reverb

/// Freeverb in miniature: four damped combs and two all-passes per side. It
/// runs over a loop twice and keeps the second pass, so the tail wraps round
/// and the loop stays seamless.
enum SynthReverb {
    private static let combL = [1116, 1188, 1277, 1356]
    private static let combR = [1139, 1211, 1300, 1379]
    private static let allL = [556, 441]
    private static let allR = [579, 464]

    static func apply(to buffer: SynthBuffer, wet: Float, room: Float = 0.82, damp: Float = 0.25) {
        guard wet > 0.001 else { return }
        let n = buffer.count
        let input = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { input.deallocate() }
        for i in 0..<n { input[i] = (buffer.left[i] + buffer.right[i]) * 0.5 }
        let wetL = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let wetR = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { wetL.deallocate(); wetR.deallocate() }
        run(input, count: n, combs: combL, alls: allL, room: room, damp: damp, out: wetL)
        run(input, count: n, combs: combR, alls: allR, room: room, damp: damp, out: wetR)
        let g = wet * 0.6
        for i in 0..<n {
            buffer.left[i] += wetL[i] * g
            buffer.right[i] += wetR[i] * g
        }
    }

    private static func run(_ input: UnsafeMutablePointer<Float>, count n: Int,
                            combs: [Int], alls: [Int], room: Float, damp: Float,
                            out: UnsafeMutablePointer<Float>) {
        let total = combs.reduce(0, +) + alls.reduce(0, +)
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: total)
        memory.initialize(repeating: 0, count: total)
        defer { memory.deallocate() }
        var starts: [Int] = []
        var cursor = 0
        for length in combs + alls {
            starts.append(cursor)
            cursor += length
        }
        var combIndex = [Int](repeating: 0, count: combs.count)
        var combStore = [Float](repeating: 0, count: combs.count)
        var allIndex = [Int](repeating: 0, count: alls.count)
        for pass in 0..<2 {
            for i in 0..<n {
                let x = input[i] * 0.3
                var sum: Float = 0
                for c in 0..<combs.count {
                    let slot = memory + starts[c]
                    let y = slot[combIndex[c]]
                    combStore[c] = y * (1 - damp) + combStore[c] * damp
                    slot[combIndex[c]] = x + combStore[c] * room
                    combIndex[c] += 1
                    if combIndex[c] == combs[c] { combIndex[c] = 0 }
                    sum += y
                }
                for a in 0..<alls.count {
                    let slot = memory + starts[combs.count + a]
                    let buffered = slot[allIndex[a]]
                    let y = buffered - sum
                    slot[allIndex[a]] = sum + buffered * 0.5
                    allIndex[a] += 1
                    if allIndex[a] == alls[a] { allIndex[a] = 0 }
                    sum = y
                }
                if pass == 1 { out[i] = sum }
            }
        }
    }
}

// MARK: - Arrangement

enum MusicSectionKind {
    case intro, verse, main, breakdown, outro
}

struct MusicSection {
    let kind: MusicSectionKind
    let startBar: Int
    let bars: Int
}

enum MusicArrangement {
    /// Eight-bar sections. The last one leads back into the first, so the
    /// whole track loops.
    static func sections(for track: GeneratedTrack) -> [MusicSection] {
        let count = max(1, track.bars / 8)
        var kinds: [MusicSectionKind]
        switch count {
        case 1: kinds = [.main]
        case 2: kinds = [.intro, .main]
        case 3: kinds = [.intro, .main, .main]
        case 4: kinds = [.intro, .verse, .main, .outro]
        case 5: kinds = [.intro, .verse, .main, .breakdown, .main]
        case 6: kinds = [.intro, .verse, .main, .breakdown, .main, .outro]
        case 7: kinds = [.intro, .verse, .main, .breakdown, .verse, .main, .outro]
        default:
            kinds = [.intro]
            let cycle: [MusicSectionKind] = [.verse, .main, .breakdown, .main]
            var i = 0
            while kinds.count < count - 1 {
                kinds.append(cycle[i % cycle.count])
                i += 1
            }
            kinds.append(.outro)
        }
        var result: [MusicSection] = []
        for (i, kind) in kinds.enumerated() {
            let start = i * 8
            let bars = i == kinds.count - 1 ? max(8, track.bars - start) : 8
            result.append(MusicSection(kind: kind, startBar: start, bars: bars))
        }
        return result
    }

    /// Stem gains: kick, snare, hats, perc, bass, chords, lead, fx.
    static func gains(_ kind: MusicSectionKind, energy: Int) -> [Float] {
        switch kind {
        case .intro: return [0, 0, 0.55, 0.7, 0, 0.9, 0, 1]
        case .verse: return [1, 1, 0.85, 0.85, 1, 0.85, energy >= 4 ? 0.7 : 0, 1]
        case .main: return [1, 1, 1, 1, 1, 1, 1, 1]
        case .breakdown: return [0, 0, 0.45, 0.6, 0, 1, 1, 1]
        case .outro: return [1, 0.9, 0.8, 0.8, 0.85, 0.8, 0, 1]
        }
    }

    /// First bar with drums: where an audition should start.
    static func previewBar(for track: GeneratedTrack) -> Int {
        sections(for: track).first(where: { $0.kind != .intro })?.startBar ?? 0
    }
}

// MARK: - Song builder

/// Builds one track: stems for a four-bar loop, then sections mixed from them.
final class SynthSong {
    static let stemCount = 8
    // Stem indices.
    static let kick = 0, snare = 1, hats = 2, perc = 3, bass = 4, chords = 5, lead = 6, fx = 7

    let track: GeneratedTrack
    let recipe: SynthRecipe
    let sections: [MusicSection]
    let sr: Double = 44100
    let stepSamples: Double
    let barSamples: Double
    let loopBars = 4
    let loopLength: Int
    let totalLength: Int
    private(set) var stems: [SynthBuffer] = []
    private var rng: SynthRandom
    private var kickOffsets: [Int] = []
    private var crashSample: [Float] = []
    private var fillSample: [Float] = []
    private var riserSample: [Float] = []
    private var lowpassL: Float = 0
    private var lowpassR: Float = 0

    /// Mix level per stem. Drums are set by gain (their one-shots are already
    /// peak-normalised); bass, chords and lead are set by loudness first (see
    /// `balance`), so their level here is 1.
    private let stemLevels: [Float] = [0.5, 0.42, 0.2, 0.22, 1, 1, 1, 0.3]
    private let carryLength: Int

    init(track: GeneratedTrack) {
        self.track = track
        recipe = SynthRecipe.recipe(for: track.genre)
        sections = MusicArrangement.sections(for: track)
        stepSamples = 44100 * 60 / track.bpm / 4
        barSamples = stepSamples * 16
        loopLength = Int((barSamples * 4).rounded())
        totalLength = Int((barSamples * Double(track.bars)).rounded())
        rng = SynthRandom(seed: track.seed)
        carryLength = Int(3 * 44100.0)
    }

    // MARK: Harmony

    private func scaleNote(_ index: Int) -> Int {
        let scale = track.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let octave = index >= 0 ? index / 7 : (index - 6) / 7
        let degree = index - octave * 7
        return octave * 12 + scale[degree]
    }

    private func degree(bar: Int) -> Int {
        let progression = track.progression.isEmpty ? [0] : track.progression
        return progression[bar % progression.count]
    }

    /// Semitones above the key root for the chord on `bar`.
    private func chordTones(bar: Int) -> [Int] {
        let d = degree(bar: bar)
        var tones = [scaleNote(d), scaleNote(d + 2), scaleNote(d + 4)]
        if recipe.sevenths { tones.append(scaleNote(d + 6)) }
        return tones
    }

    private func fold(_ note: Int, low: Int, high: Int) -> Int {
        var n = note
        while n > high { n -= 12 }
        while n < low { n += 12 }
        return n
    }

    private func chordMidi(bar: Int) -> [Int] {
        chordTones(bar: bar).map { fold(track.root + $0, low: 52, high: 71) }.sorted()
    }

    private func bassMidi(bar: Int, symbol: Character) -> Int? {
        let tones = chordTones(bar: bar)
        let base: Int
        switch recipe.bassKind {
        case .eight08: base = 29
        case .log: base = 40
        default: base = 36
        }
        let rootClass = ((track.root + tones[0]) % 12 + 12) % 12
        let baseClass = base % 12
        let root = base + (rootClass - baseClass + 12) % 12
        switch symbol {
        case "R": return root
        case "3": return root + (tones[1] - tones[0])
        case "5": return root + (tones[2] - tones[0])
        case "7": return root + ((tones.count > 3 ? tones[3] : scaleNote(degree(bar: bar) + 6)) - tones[0])
        case "8": return root + 12
        default: return nil
        }
    }

    private func leadMidi(bar: Int, symbol: Character) -> Int? {
        guard let digit = symbol.wholeNumberValue, digit >= 1, digit <= 6 else { return nil }
        let tones = chordTones(bar: bar)
        let index = (digit - 1) % 3
        let octave = digit > 3 ? 12 : 0
        let tone = tones[min(index, tones.count - 1)]
        return fold(track.root + 12 + tone + octave, low: 62, high: 86)
    }

    // MARK: Patterns

    private func char(_ pattern: [String], bar: Int, step: Int) -> Character {
        guard !pattern.isEmpty else { return "." }
        let chars = Array(pattern[bar % pattern.count])
        return step < chars.count ? chars[step] : "."
    }

    /// Steps a held note lasts: itself plus every `-` after it (within the bar).
    private func holdSteps(_ pattern: [String], bar: Int, step: Int) -> Int {
        guard !pattern.isEmpty else { return 1 }
        let chars = Array(pattern[bar % pattern.count])
        var length = 1
        var s = step + 1
        while s < 16, s < chars.count, chars[s] == "-" {
            length += 1
            s += 1
        }
        return length
    }

    private func offset(bar: Int, step: Int) -> Int {
        var t = Double(bar * 16 + step) * stepSamples
        if step % 2 == 1 { t += Double(recipe.swing) * stepSamples }
        return Int(t.rounded())
    }

    private func human() -> Float {
        0.9 + 0.1 * rng.unit()
    }

    // MARK: Stems

    func buildStems() {
        stems = (0..<Self.stemCount).map { _ in SynthBuffer(count: loopLength) }
        buildDrums()
        buildBass()
        buildChords()
        buildLead()
        buildFX()
        applySidechain()
        SynthReverb.apply(to: stems[Self.chords], wet: recipe.reverb)
        SynthReverb.apply(to: stems[Self.lead], wet: recipe.reverb * 1.2)
        balance(Self.bass, targetRMS: 0.12)
        balance(Self.chords, targetRMS: 0.07)
        balance(Self.lead, targetRMS: 0.05)
        buildEvents()
    }

    /// Tonal voices differ a lot in raw level (an 808 against a four-note
    /// pad), so bass, chords and lead are scaled to a loudness instead of
    /// trusting a fixed gain. The boost is capped so a sparse line stays sparse.
    private func balance(_ stem: Int, targetRMS: Float) {
        let buffer = stems[stem]
        var sum: Double = 0
        for i in 0..<buffer.count {
            let l = Double(buffer.left[i])
            let r = Double(buffer.right[i])
            sum += l * l + r * r
        }
        let rms = Float((sum / Double(buffer.count * 2)).squareRoot())
        guard rms > 0.000_01 else { return }
        let scale = min(4, targetRMS / rms)
        for i in 0..<buffer.count {
            buffer.left[i] *= scale
            buffer.right[i] *= scale
        }
    }

    private func buildDrums() {
        let kick = SynthVoice.kick(recipe.kickKind, rng: &rng)
        let snare = SynthVoice.snare(recipe.snareKind, rng: &rng)
        let closed = SynthVoice.hat(open: false, rng: &rng)
        let open = SynthVoice.hat(open: true, rng: &rng)
        var percHigh: [Float] = []
        var percLow: [Float] = []
        switch recipe.percKind {
        case .shaker: percHigh = SynthVoice.shaker(rng: &rng); percLow = percHigh
        case .conga:
            percHigh = SynthVoice.conga(pitch: 330, rng: &rng)
            percLow = SynthVoice.conga(pitch: 220, rng: &rng)
        case .rim: percHigh = SynthVoice.rim(); percLow = percHigh
        case .tick: percHigh = SynthVoice.tick(); percLow = percHigh
        case .none: break
        }
        let stepHalf = Int(stepSamples / 2)
        let stepThird = Int(stepSamples / 3)
        for bar in 0..<loopBars {
            for step in 0..<16 {
                let at = offset(bar: bar, step: step)

                switch char(recipe.kick, bar: bar, step: step) {
                case "x", "X":
                    stems[Self.kick].addWrapped(kick, at: at, gainL: 1, gainR: 1)
                    kickOffsets.append(at)
                case "o":
                    stems[Self.kick].addWrapped(kick, at: at, gainL: 0.6, gainR: 0.6)
                default: break
                }

                switch char(recipe.snare, bar: bar, step: step) {
                case "x", "X":
                    let v = human()
                    stems[Self.snare].addWrapped(snare, at: at, gainL: v, gainR: v)
                case "o":
                    let v = 0.4 * human()
                    stems[Self.snare].addWrapped(snare, at: at, gainL: v, gainR: v)
                default: break
                }

                let hatPan = SynthBuffer.pan(0.18, gain: 1)
                switch char(recipe.hats, bar: bar, step: step) {
                case "x", "X":
                    let v = 0.9 * human()
                    stems[Self.hats].addWrapped(closed, at: at, gainL: hatPan.0 * v, gainR: hatPan.1 * v)
                case "o":
                    let v = 0.5 * human()
                    stems[Self.hats].addWrapped(closed, at: at, gainL: hatPan.0 * v, gainR: hatPan.1 * v)
                case "O":
                    let v = 0.75 * human()
                    stems[Self.hats].addWrapped(open, at: at, gainL: hatPan.0 * v, gainR: hatPan.1 * v)
                case "r":
                    for k in 0..<2 {
                        let v = 0.65 * human()
                        stems[Self.hats].addWrapped(closed, at: at + k * stepHalf,
                                                    gainL: hatPan.0 * v, gainR: hatPan.1 * v)
                    }
                case "t":
                    for k in 0..<3 {
                        let v = (0.5 + 0.12 * Float(k)) * human()
                        stems[Self.hats].addWrapped(closed, at: at + k * stepThird,
                                                    gainL: hatPan.0 * v, gainR: hatPan.1 * v)
                    }
                default: break
                }

                guard !percHigh.isEmpty else { continue }
                let percPan = SynthBuffer.pan(-0.25, gain: 1)
                switch char(recipe.perc, bar: bar, step: step) {
                case "x", "X", "h":
                    let v = human()
                    stems[Self.perc].addWrapped(percHigh, at: at, gainL: percPan.0 * v, gainR: percPan.1 * v)
                case "l":
                    let v = human()
                    stems[Self.perc].addWrapped(percLow, at: at, gainL: percPan.0 * v, gainR: percPan.1 * v)
                case "o":
                    let v = 0.5 * human()
                    stems[Self.perc].addWrapped(percHigh, at: at, gainL: percPan.0 * v, gainR: percPan.1 * v)
                default: break
                }
            }
        }
        crashSample = recipe.crash ? SynthVoice.crash(rng: &rng) : []
        fillSample = recipe.snareKind == .rim ? [] : snare
    }

    private func buildBass() {
        var previous: Int?
        var cache: [Int: [Float]] = [:]
        for bar in 0..<loopBars {
            for step in 0..<16 {
                let symbol = char(recipe.bass, bar: bar, step: step)
                guard let midi = bassMidi(bar: bar, symbol: symbol) else { continue }
                let steps = holdSteps(recipe.bass, bar: bar, step: step)
                let length = max(1, Int(Double(steps) * stepSamples) - Int(0.01 * sr))
                let note: [Float]
                if recipe.bassKind == .eight08 {
                    note = SynthVoice.bass(.eight08, midi: midi, length: length,
                                           glideFrom: previous, rng: &rng)
                } else {
                    let key = midi * 1000 + steps
                    if let hit = cache[key] {
                        note = hit
                    } else {
                        note = SynthVoice.bass(recipe.bassKind, midi: midi, length: length,
                                               glideFrom: nil, rng: &rng)
                        cache[key] = note
                    }
                }
                previous = midi
                stems[Self.bass].addWrapped(note, at: offset(bar: bar, step: step), gainL: 1, gainR: 1)
            }
        }
    }

    private func buildChords() {
        var cache: [Int: [Float]] = [:]
        let energyCutoff = Float(1200 + 300 * track.energy)
        for bar in 0..<loopBars {
            let notes = chordMidi(bar: bar)
            for step in 0..<16 {
                let symbol = char(recipe.chords, bar: bar, step: step)
                guard symbol == "x" || symbol == "X" else { continue }
                let steps = holdSteps(recipe.chords, bar: bar, step: step)
                let length = max(1, Int(Double(steps) * stepSamples) - Int(0.015 * sr))
                let at = offset(bar: bar, step: step)
                for (i, midi) in notes.enumerated() {
                    let f = SynthDSP.hz(midi)
                    let spread = notes.count > 1 ? Float(i) / Float(notes.count - 1) - 0.5 : 0
                    let pan = SynthBuffer.pan(spread * 0.5, gain: 1)
                    switch recipe.chordKind {
                    case .pad:
                        let left = SynthVoice.padNote(f, length: length, detune: 7, cutoff: energyCutoff,
                                                      attack: 0.18, release: 0.35)
                        let right = SynthVoice.padNote(f, length: length, detune: -7, cutoff: energyCutoff,
                                                       attack: 0.18, release: 0.35)
                        stems[Self.chords].addWrapped(left, at: at, gainL: 0.32, gainR: 0)
                        stems[Self.chords].addWrapped(right, at: at, gainL: 0, gainR: 0.32)
                    case .strings:
                        let left = SynthVoice.stringsNote(f, length: length, detune: 9)
                        let right = SynthVoice.stringsNote(f * 1.0015, length: length, detune: 11)
                        stems[Self.chords].addWrapped(left, at: at, gainL: 0.4, gainR: 0)
                        stems[Self.chords].addWrapped(right, at: at, gainL: 0, gainR: 0.4)
                    case .keys, .stab, .piano:
                        let key = midi * 1000 + steps
                        let note: [Float]
                        if let hit = cache[key] {
                            note = hit
                        } else {
                            switch recipe.chordKind {
                            case .keys: note = SynthVoice.keysNote(f, length: length, brightness: 0.8)
                            case .stab: note = SynthVoice.stabNote(f, length: length)
                            default: note = SynthVoice.pianoNote(f, length: length)
                            }
                            cache[key] = note
                        }
                        let v: Float = 0.3 * human()
                        stems[Self.chords].addWrapped(note, at: at, gainL: pan.0 * v, gainR: pan.1 * v)
                    }
                }
            }
        }
    }

    private func buildLead() {
        guard recipe.leadKind != .none, !recipe.leads.isEmpty else { return }
        let choice = Int(track.seed % UInt32(recipe.leads.count))
        let pattern = recipe.leads[choice]
        let pan = SynthBuffer.pan(0.12, gain: 1)
        for bar in 0..<loopBars {
            for step in 0..<16 {
                let symbol = char(pattern, bar: bar, step: step)
                guard let midi = leadMidi(bar: bar, symbol: symbol) else { continue }
                let steps = holdSteps(pattern, bar: bar, step: step)
                let length = max(1, Int(Double(steps) * stepSamples) - Int(0.01 * sr))
                let f = SynthDSP.hz(midi)
                let note: [Float]
                switch recipe.leadKind {
                case .pluck: note = SynthVoice.pluck(f, length: length, damping: 0.994, brightness: 0.7, rng: &rng)
                case .guitar: note = SynthVoice.pluck(f, length: length, damping: 0.997, brightness: 0.5, rng: &rng)
                case .bell: note = SynthVoice.bell(f, length: length)
                case .keys: note = SynthVoice.keysNote(f, length: length, brightness: 1)
                case .piano: note = SynthVoice.pianoNote(f, length: length)
                case .none: note = []
                }
                let v = 0.8 * human()
                stems[Self.lead].addWrapped(note, at: offset(bar: bar, step: step),
                                            gainL: pan.0 * v, gainR: pan.1 * v)
            }
        }
    }

    private func buildFX() {
        guard recipe.lofi else { return }
        let left = SynthVoice.crackle(length: loopLength, rng: &rng)
        let right = SynthVoice.crackle(length: loopLength, rng: &rng)
        stems[Self.fx].addWrapped(left, at: 0, gainL: 1, gainR: 0)
        stems[Self.fx].addWrapped(right, at: 0, gainL: 0, gainR: 1)
    }

    /// Ducks bass and chords under each kick (house and garage pump).
    private func applySidechain() {
        guard recipe.sidechain > 0.01, !kickOffsets.isEmpty else { return }
        let sorted = kickOffsets.sorted()
        let depth = recipe.sidechain
        let tau = Float(0.11 * sr)
        var next = 0
        var last = (sorted.last ?? 0) - loopLength
        for i in 0..<loopLength {
            while next < sorted.count, sorted[next] <= i {
                last = sorted[next]
                next += 1
            }
            let since = Float(i - last)
            let g = 1 - depth * exp(-since / tau)
            stems[Self.bass].left[i] *= g
            stems[Self.bass].right[i] *= g
            stems[Self.chords].left[i] *= g
            stems[Self.chords].right[i] *= g
        }
    }

    private func buildEvents() {
        if recipe.riser, track.energy >= 3 {
            riserSample = SynthVoice.riser(length: Int(barSamples * 2), rng: &rng)
        }
    }

    // MARK: Mix

    /// Section start sample on the absolute timeline.
    private func sectionStart(_ index: Int) -> Int {
        guard index < sections.count else { return totalLength }
        return Int((Double(sections[index].startBar) * barSamples).rounded())
    }

    /// Mixes every section in order and hands each block to `block`.
    /// `gain` is applied after the soft clip; pass 1 to measure.
    func render(gain: Float, block: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) {
        lowpassL = 0
        lowpassR = 0
        var maxFrames = 0
        for i in 0..<sections.count {
            maxFrames = max(maxFrames, sectionStart(i + 1) - sectionStart(i))
        }
        let work = SynthBuffer(count: maxFrames + carryLength)
        let carry = SynthBuffer(count: carryLength)
        var previousGains: [Float]?
        for index in 0..<sections.count {
            let start = sectionStart(index)
            let frames = sectionStart(index + 1) - start
            guard frames > 0 else { continue }
            work.clear()
            for i in 0..<carryLength {
                work.left[i] += carry.left[i]
                work.right[i] += carry.right[i]
            }
            carry.clear()
            let section = sections[index]
            let gains = MusicArrangement.gains(section.kind, energy: track.energy)
            mixStems(into: work, start: start, frames: frames, gains: gains, previous: previousGains)
            previousGains = gains
            addEvents(into: work, index: index, frames: frames)
            master(work, frames: frames, gain: gain)
            for i in 0..<carryLength {
                carry.left[i] = work.left[frames + i]
                carry.right[i] = work.right[frames + i]
            }
            block(work.left, work.right, frames)
        }
    }

    private func mixStems(into work: SynthBuffer, start: Int, frames: Int,
                          gains: [Float], previous: [Float]?) {
        let ramp = 512
        for stem in 0..<Self.stemCount {
            let target = gains[stem] * stemLevels[stem]
            let from = (previous?[stem] ?? gains[stem]) * stemLevels[stem]
            if target < 0.0001 && from < 0.0001 { continue }
            let source = stems[stem]
            var pos = start % loopLength
            for i in 0..<frames {
                let g = i < ramp ? from + (target - from) * Float(i) / Float(ramp) : target
                work.left[i] += source.left[pos] * g
                work.right[i] += source.right[pos] * g
                pos += 1
                if pos == loopLength { pos = 0 }
            }
        }
    }

    private func addEvents(into work: SynthBuffer, index: Int, frames: Int) {
        let kind = sections[index].kind
        let nextKind: MusicSectionKind? = index + 1 < sections.count ? sections[index + 1].kind : nil
        // A crash marks every drop.
        if kind == .main, !crashSample.isEmpty {
            work.addClipped(crashSample, at: 0, gainL: 0.16, gainR: 0.2)
        }
        // A snare run into the drop.
        if nextKind == .main, kind != .breakdown, !fillSample.isEmpty {
            let gains: [Float] = [0.25, 0.32, 0.4, 0.5]
            for k in 0..<4 {
                let at = frames - Int(stepSamples * Double(4 - k))
                let v = gains[k] * stemLevels[Self.snare] * 2
                work.addClipped(fillSample, at: at, gainL: v, gainR: v)
            }
        }
        // A riser over the last two bars before a drop.
        if nextKind == .main, !riserSample.isEmpty, kind != .main {
            work.addClipped(riserSample, at: frames - riserSample.count, gainL: 0.12, gainR: 0.12)
        }
    }

    private func master(_ work: SynthBuffer, frames: Int, gain: Float) {
        let lofiA = SynthDSP.onePole(3800)
        for i in 0..<frames {
            var l = work.left[i]
            var r = work.right[i]
            if recipe.lofi {
                lowpassL += lofiA * (l - lowpassL)
                lowpassR += lofiA * (r - lowpassR)
                l = lowpassL
                r = lowpassR
            }
            // tanh: linear when quiet, rounds off only the loudest peaks.
            work.left[i] = tanh(l) * gain
            work.right[i] = tanh(r) * gain
        }
    }

    /// The loudest sample after the soft clip, for normalising.
    func measurePeak() -> Float {
        var peak: Float = 0
        render(gain: 1) { left, right, count in
            for i in 0..<count {
                peak = max(peak, abs(left[i]), abs(right[i]))
            }
        }
        return peak
    }
}

// MARK: - Rendering to a file

enum MusicSynth {
    /// Bump when the sound changes so cached files are rendered again.
    static let version = 1
    static let sampleRate: Double = 44100

    /// Renders `track` into `url` (an .m4a). Falls back to a 16-bit .caf next
    /// to it when the AAC encoder is unavailable. Returns the written file.
    static func renderFile(_ track: GeneratedTrack, to url: URL) -> URL? {
        let song = SynthSong(track: track)
        song.buildStems()
        let peak = song.measurePeak()
        let gain: Float = peak > 0.0001 ? min(4, 0.93 / peak) : 1
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let temp = folder.appendingPathComponent("rendering-\(UUID().uuidString).m4a")
        if write(song, gain: gain, to: temp, aac: true) {
            try? FileManager.default.removeItem(at: url)
            if (try? FileManager.default.moveItem(at: temp, to: url)) != nil { return url }
        }
        try? FileManager.default.removeItem(at: temp)

        let caf = url.deletingPathExtension().appendingPathExtension("caf")
        let tempCAF = folder.appendingPathComponent("rendering-\(UUID().uuidString).caf")
        if write(song, gain: gain, to: tempCAF, aac: false) {
            try? FileManager.default.removeItem(at: caf)
            if (try? FileManager.default.moveItem(at: tempCAF, to: caf)) != nil { return caf }
        }
        try? FileManager.default.removeItem(at: tempCAF)
        return nil
    }

    private static func write(_ song: SynthSong, gain: Float, to url: URL, aac: Bool) -> Bool {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        if aac {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 160_000
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        return encode(song, gain: gain, url: url, settings: settings)
    }

    /// Kept separate so the AVAudioFile is released (and finalised) before
    /// the caller moves the file into place.
    private static func encode(_ song: SynthSong, gain: Float, url: URL, settings: [String: Any]) -> Bool {
        guard let file = try? AVAudioFile(forWriting: url, settings: settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false) else {
            return false
        }
        let capacity: Int = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(capacity)),
              let channels = buffer.floatChannelData,
              buffer.format.channelCount == 2 else {
            return false
        }
        var ok = true
        song.render(gain: gain) { left, right, count in
            var done = 0
            while done < count, ok {
                let n = min(capacity, count - done)
                let outL = channels[0]
                let outR = channels[1]
                for i in 0..<n {
                    outL[i] = left[done + i]
                    outR[i] = right[done + i]
                }
                buffer.frameLength = AVAudioFrameCount(n)
                do {
                    try file.write(from: buffer)
                } catch {
                    ok = false
                }
                done += n
            }
        }
        return ok
    }
}
