import SwiftUI

/// Lets a bare UUID drive `.sheet(item:)`.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// Draggable volume-automation editor for one audio lane: tap the graph to add
/// a point, drag points to shape the curve, swipe a point off the top/bottom to
/// delete. X = time across the lane's span, Y = 0…1 gain.
struct AudioEnvelopeEditor: View {
    @ObservedObject var editor: EditorState
    let trackID: UUID
    let onClose: () -> Void

    private var track: EditorState.MusicTrack? {
        editor.audioTracks.first { $0.id == trackID }
    }
    private var duration: Double { max(0.1, track?.timelineDuration ?? 1) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Volume envelope").font(.luma(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Clear") { commit([]) }
                    .font(.luma(.footnote, weight: .semibold)).foregroundStyle(LumaTheme.textSecondary)
                Button("Done", action: onClose)
                    .font(.luma(.footnote, weight: .semibold)).foregroundStyle(LumaTheme.accentBright)
            }

            GeometryReader { geo in
                let pts = normalizedPoints()
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(LumaTheme.surface)
                    // Gridlines.
                    ForEach(1..<4) { i in
                        let y = geo.size.height * CGFloat(i) / 4
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                    // Envelope polyline.
                    Path { p in
                        guard let first = pts.first else { return }
                        p.move(to: point(first, in: geo.size))
                        for pt in pts.dropFirst() { p.addLine(to: point(pt, in: geo.size)) }
                    }
                    .stroke(LumaTheme.accentBright, lineWidth: 2)
                    // Draggable handles.
                    ForEach(Array(pts.enumerated()), id: \.offset) { idx, pt in
                        Circle().fill(.white).frame(width: 16, height: 16)
                            .position(point(pt, in: geo.size))
                            .gesture(DragGesture()
                                .onChanged { g in dragPoint(idx, to: g.location, in: geo.size) })
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in addPoint(at: loc, in: geo.size) }
            }
            .frame(height: 220)

            Text("Tap to add a point · drag to shape")
                .font(.luma(.caption)).foregroundStyle(LumaTheme.textMuted)
        }
        .padding(20)
        .background(LumaTheme.background)
    }

    // MARK: - Point maths (unit: x = time/duration, y = volume 0…1)

    private func normalizedPoints() -> [AudioVolumePoint] {
        let existing = track?.volumePoints ?? []
        if existing.isEmpty {
            return [AudioVolumePoint(time: 0, volume: 1), AudioVolumePoint(time: duration, volume: 1)]
        }
        return existing.sorted { $0.time < $1.time }
    }

    private func point(_ p: AudioVolumePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.time / duration) * size.width,
                y: (1 - CGFloat(p.volume)) * size.height)
    }

    private func addPoint(at loc: CGPoint, in size: CGSize) {
        let t = Double(loc.x / size.width) * duration
        let v = Double(1 - loc.y / size.height)
        var pts = track?.volumePoints ?? normalizedPoints()
        pts.append(AudioVolumePoint(time: min(max(0, t), duration), volume: min(max(0, v), 1)))
        commit(pts.sorted { $0.time < $1.time })
        LumaHaptics.shared.tap()
    }

    private func dragPoint(_ idx: Int, to loc: CGPoint, in size: CGSize) {
        var pts = normalizedPoints()
        guard pts.indices.contains(idx) else { return }
        pts[idx].time = min(max(0, Double(loc.x / size.width) * duration), duration)
        pts[idx].volume = min(max(0, Double(1 - loc.y / size.height)), 1)
        commit(pts.sorted { $0.time < $1.time })
    }

    private func commit(_ points: [AudioVolumePoint]) {
        editor.setMusicEnvelope(id: trackID, points)
    }
}
