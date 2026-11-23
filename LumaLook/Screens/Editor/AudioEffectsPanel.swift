import SwiftUI

/// Audio effect editor for one lane: EQ presets + 5 bands (C1), pitch shift
/// (C2), voice changer (C3), reverb (C4), loudness normalize (C5). Every change
/// re-bakes the lane through AudioEffectsRenderer via editor.applyTrackEffects.
struct AudioEffectsPanel: View {
    @ObservedObject var editor: EditorState
    let trackID: UUID
    let onClose: () -> Void

    private var track: EditorState.MusicTrack? { editor.audioTracks.first { $0.id == trackID } }
    private var fx: AudioEffectSettings { track?.effects ?? AudioEffectSettings() }

    static let eqPresets: [(String, [Double])] = [
        ("Flat", [0, 0, 0, 0, 0]),
        ("Bass Boost", [8, 4, 0, 0, 0]),
        ("Treble", [0, 0, 0, 4, 8]),
        ("Voice", [-2, 0, 3, 5, 2]),
        ("Podcast", [-4, -2, 2, 4, 1]),
        ("Warm", [4, 2, 0, -2, -4]),
        ("De-Rumble", [-12, -4, 0, 0, 0]),
    ]
    private let bandLabels = ["80", "250", "1k", "3.5k", "10k"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Audio").font(.luma(size: 18, weight: .light))
                        Text("effects").font(.luma(size: 18, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    if editor.isRenderingEffects {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    }
                    Spacer()
                    LPanelPill(title: "Reset", height: 32) { apply(AudioEffectSettings()) }
                    // The panel's confirm: a white pill, as in the calm mock.
                    // The signal stays on Export, the editor's main action.
                    LPanelConfirmButton(title: "Done", action: onClose)
                }

                section("Equaliser") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.eqPresets, id: \.0) { name, gains in
                                chip(name, on: (fx.eqBandGains ?? [0,0,0,0,0]) == gains) {
                                    var s = fx; s.eqBandGains = gains; s.eqPresetName = name; apply(s)
                                }
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            VStack(spacing: 4) {
                                let g = fx.eqBandGains?[safe: i] ?? 0
                                Text("\(Int(g))").font(.luma(size: 9).monospacedDigit()).foregroundStyle(LumaTheme.textMuted)
                                Slider(value: Binding(
                                    get: { fx.eqBandGains?[safe: i] ?? 0 },
                                    set: { v in
                                        var bands = fx.eqBandGains ?? [0,0,0,0,0]
                                        while bands.count < 5 { bands.append(0) }
                                        bands[i] = v
                                        var s = fx; s.eqBandGains = bands; s.eqPresetName = nil; apply(s)
                                    }), in: -12...12)
                                    .tint(.white)
                                    // Size to the slider's LENGTH first, then
                                    // rotate, then set a NARROW layout footprint
                                    // — rotationEffect doesn't change layout, so
                                    // without the final frame each band stays
                                    // 90pt wide and the panel spills off-screen.
                                    .frame(width: 90)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 46, height: 96)
                                Text(bandLabels[i]).font(.luma(size: 9)).foregroundStyle(LumaTheme.textSecondary)
                            }
                        }
                    }
                }

                section("Pitch") {
                    HStack {
                        Text("\(fx.pitchSemitones > 0 ? "+" : "")\(Int(fx.pitchSemitones)) st")
                            .font(.luma(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        Spacer()
                        Stepper("", value: Binding(
                            get: { fx.pitchSemitones },
                            set: { var s = fx; s.pitchSemitones = $0; s.voiceEffect = nil; apply(s) }
                        ), in: -12...12, step: 1).labelsHidden()
                    }
                }

                section("Voice changer") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(VoiceEffect.allCases, id: \.self) { v in
                                chip(v.label, on: (fx.voiceEffect ?? "none") == v.rawValue) {
                                    var s = fx; s.voiceEffect = v == .none ? nil : v.rawValue; apply(s)
                                }
                            }
                        }
                    }
                }

                section("Reverb") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ReverbPreset.allCases, id: \.self) { p in
                                chip(p.label, on: (fx.reverbPreset ?? "none") == p.rawValue) {
                                    var s = fx; s.reverbPreset = p == .none ? nil : p.rawValue; apply(s)
                                }
                            }
                        }
                    }
                    if (fx.reverbPreset ?? "none") != "none" {
                        // An amount, so it is the Appearance slider (ruler or dial).
                        LPanelAmount("Wet", value: Binding(
                            get: { fx.reverbMix },
                            set: { var s = fx; s.reverbMix = $0; apply(s) }
                        ), range: 0...100)
                    }
                }

                section("Loudness") {
                    Button {
                        LumaHaptics.shared.tap()
                        Task { await editor.normalizeTrack(id: trackID, targetLUFS: -14) }
                    } label: {
                        Label("Normalise to −14 LUFS", systemImage: "waveform.badge.magnifyingglass")
                            .font(.luma(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.86))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(LPanelStyle.glass, in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                    if abs(fx.gainDB) > 0.05 {
                        Text(String(format: "gain %+.1f dB", fx.gainDB))
                            .font(.luma(.caption)).foregroundStyle(LumaTheme.textSecondary)
                    }
                }
            }
            .padding(20)
        }
        .background(LumaTheme.panel)
    }

    private func apply(_ settings: AudioEffectSettings) {
        Task { await editor.applyTrackEffects(id: trackID, settings) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LPanelLabel(title)
            content()
        }
    }

    /// Quiet pills: near-white when picked, glass otherwise.
    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        LPanelPill(title: label, isOn: on) {
            action(); LumaHaptics.shared.tap()
        }
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? { indices.contains(index) ? self[index] : nil }
}
