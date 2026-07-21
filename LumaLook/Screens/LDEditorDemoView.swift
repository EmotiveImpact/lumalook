import SwiftUI
import AVKit
import PhotosUI

// =============================================================================
// LDEditorDemoView — the VIDEO EDITOR rebuilt in the Lens-Distortions language,
// as a WORKING preview. It drives `app.editor` (the one real EditorState the
// shipping editor uses): real clips, real filmstrips, real player, real audio
// lanes, real looks through LookThumbs. Nothing here is a mock.
//
// -----------------------------------------------------------------------------
// FEATURE INVENTORY — the founder's checklist.
// Every user-facing capability of EditorScreen.swift + Screens/Editor/*.swift.
// ✓ = present and wired here. ✗ = deliberately out of scope, with the reason.
// -----------------------------------------------------------------------------
//
// CHROME / PROJECT
//   ✓ Back / dismiss
//   ✓ Project title (read-out)
//   ✓ Undo                      editor.undo()          + canUndo dimming
//   ✓ Redo                      editor.redo()          + canRedo dimming
//   ✓ Export                    pushes .ldExport — the export preview in this
//                                 same language, built by its own sibling view
//   ✗ Export SPEC SHEET         ExportSpecSheet + the exporter progress overlay
//                                 are LDExportDemoView's subject, not this
//                                 screen's. Deliberately not duplicated here.
//   ✓ Autosave on disappear     editor.saveProject()
//   ✓ New project               editor.startNewProject()
//   ✓ Resume last project       load(project:) from the store on empty open
//
// TRANSPORT
//   ✓ Play / pause              editor.togglePlayback()
//   ✓ Prev / next boundary      editor.seekToBoundary(forward:)
//   ✓ Frame step (hold)         editor.stepFrame(±1) via LumaHoldButtonStyle
//   ✓ Timecode readout          MM:SS:FF ⇄ MM:SS on long-press (TechReadout)
//   ✓ Duration readout          TechReadout
//   ✓ Timeline zoom             cycle button + pinch, clamped to TimelineMetrics
//   ✓ Zoom factor readout       TechReadout
//   ✓ Magnet / snapping         @AppStorage("timelineMagnet") + TimelineSnap
//   ✓ Fullscreen preview        AVPlayer full-screen cover
//   ✓ Rebuild spinner           editor.isRebuilding
//
// TIMELINE
//   ✓ Ruler with adaptive ticks
//   ✓ Playhead + auto-follow during playback
//   ✓ Scrub                     drag/tap the ruler (was: centre-fixed scroller)
//   ✓ Video lane, real filmstrip frames per clip
//   ✓ Clip select / deselect
//   ✓ Trim handles on selected clip → editor.applyTrim(start:end:)
//   ✓ Transition chips at every cut → real transition preview glyph
//   ✓ Clip-audio lane           tap → Clip Sound tool
//   ✓ Overlay lanes (stacked)   drag to reposition → setOverlayOffset (snapped)
//   ✓ Music / voice / sfx lanes real RMS waveform, drag → setMusicOffset
//   ✓ Beat markers on the lane
//   ✓ Pinch zoom
//   ✓ Empty state teaching the 4-lane model (Video / Overlay / Music / Voice)
//   ✓ Mini timeline while a tool is open ("push, never cover")
//   ✗ Long-press-drag clip REORDER — replaced by explicit Move ◀ ▶ in the clip
//     tool row (editor.moveSelected(by:)). Same capability, different gesture:
//     a long-press-drag reorder needs the UIKit scroller EditorScreen wraps.
//   ✗ Clip context menu        every item in it (Duplicate / Copy / Paste /
//     Ripple delete / Delete-keep-lanes) is a first-class chip in the clip row.
//
// CLIP ACTIONS
//   ✓ Split at playhead         editor.splitAtPlayhead()
//   ✓ Duplicate                 editor.duplicateSelected()
//   ✓ Copy                      editor.copySelected()
//   ✓ Paste                     editor.pasteClip()      (dims when clipboard empty)
//   ✓ Delete (ripple)           editor.deleteSelected(ripple: true)
//   ✓ Delete, keep other lanes  editor.deleteSelected(ripple: false)
//   ✓ Move ◀ / ▶                editor.moveSelected(by:)
//   ✓ Trim panel                start/end sliders + live duration
//   ✓ Speed — 9 constant presets editor.setClipSpeed(_:)
//   ✓ Speed ramps (5)           editor.setSpeedRamp(_:) — drawn as a ramp curve
//   ✓ Freeze at playhead        editor.freezeAtPlayhead()
//   ✓ Reverse                   editor.reverseSelectedClip()  (dims for photos)
//   ✓ Rotate 90°                editor.rotateSelectedClip()
//   ✓ Mirror                    editor.mirrorSelectedClip()
//   ✓ Crop + straighten         CropStraightenView → setCropStraighten
//   ✓ Replace media             PhotosPicker → editor.replaceClip(id:with:)
//   ✓ Detach audio              editor.detachAudio(clipID:)
//   ✓ Clip volume               editor.setClipVolume(id:_:)
//   ✓ Clip mute                 editor.setClipMuted(id:_:)
//   ✓ Per-clip Look             app.select(look:forClip:) — real graded tiles
//   ✓ Clear per-clip look       editor.setClipGrade(id:, nil)
//   ✓ Apply look to all clips   editor.applyGradeToAllClips(_:)
//   ✓ Motion / Ken Burns (7)    editor.setKenBurns(id:preset:)
//   ✓ Motion easing (4)         editor.setKenBurnsEasing(id:easing:)
//   ✓ Spot mask — shape         editor.setClipMask(id:shape:…)
//   ✓ Spot mask — effect        blur / mosaic / fill
//   ✓ Spot mask — invert, size, feather, strength, position pad
//
// TRANSITIONS
//   ✓ 14 styles in 3 groups     editor.setTransition(afterClipID:style:duration:)
//   ✓ Duration presets          0.3 / 0.6 / 1.0 / 1.5 s
//   ✓ Apply to all cuts         editor.setTransitionForAllCuts(style:duration:)
//
// OVERLAY / PIP / TEXT / SHAPES / STICKERS
//   ✓ Add overlay from Photos   editor.addOverlay(from:isImage:)
//   ✓ Add text overlay          editor.addTextOverlay()
//   ✓ Edit text content         editor.setOverlayText(id:_:)
//   ✓ Text style (title/sub/mono) setOverlayTextStyle
//   ✓ Text colour swatches      setOverlayTextColor   (content colour, not chrome)
//   ✓ Text font                 setTextDecor(fontName:)
//   ✓ Text alignment            setTextDecor(alignment:)
//   ✓ Text outline + width      setTextDecor(strokeHex:strokeWidth:)
//   ✓ Text box                  setTextDecor(boxHex:)
//   ✓ Text animation (8)        editor.setTextAnimation(id:_:)
//   ✓ Shapes (8 kinds)          editor.addShapeOverlay(kind:)
//   ✓ Stickers (6 emoji sets)   editor.addSticker(emoji:)
//   ✓ Opacity / Size / Rotation setOverlayOpacity / Size / Rotation
//   ✓ 9-anchor position pad     editor.setOverlayCenter(id:_:)
//   ✓ X / Y fine position       editor.setOverlayCenter(id:_:)
//   ✓ Layer back / forward      editor.nudgeOverlayLane(id:by:)
//   ✓ Overlay volume / mute     setOverlayVolume / setOverlayMuted
//   ✓ Keyframes — pin           editor.addOverlayKeyframe(id:)
//   ✓ Keyframes — clear + count editor.clearOverlayKeyframes(id:)
//   ✓ Remove overlay            editor.removeOverlay(id:)
//   ✓ PIP presets (6)           editor.applyPipPreset(id:_:)
//   ✓ Blend modes (7)           editor.setOverlayBlendMode(id:_:)
//   ✓ Chroma key + tolerance/softness/colour  setOverlayChroma
//   ✓ Overlay mask shape/feather/invert       setOverlayMask
//   ✓ Overlay adjust E/C/S/W + reset          setOverlayAdjustments
//   ✓ Overlay border colour/width/corner      setOverlayBorder
//
// AUDIO
//   ✓ Add from Sound Library    BundledAudioLibrary + addAudioTrack
//   ✓ Add from Files            fileImporter → importMusicFile → addAudioTrack
//   ✓ Record voiceover          editor.startVoiceover() / stopVoiceover()
//   ✓ Live input level meter    editor.inputLevel
//   ✓ Track volume              editor.setMusicVolume(id:_:)
//   ✓ Track mute                editor.setMusicMuted(id:_:)
//   ✓ Fade in / out + curve     editor.setMusicFade(id:fadeIn:fadeOut:curve:)
//   ✓ Volume envelope editor    editor.setMusicEnvelope(id:_:) — tap + drag
//   ✓ Ducking under voice       editor.setMusicDucking(id:_:)
//   ✓ Loop                      editor.setMusicLooping(id:_:)
//   ✓ Lane kind (music/voice/sfx) editor.setAudioKind(id:_:)
//   ✓ Head / tail trim          trimMusicHead / trimMusicTail
//   ✓ Detect beats              editor.detectBeats(trackID:)
//   ✓ Auto-cut to beats         editor.autoCutToBeats(trackID:)
//   ✓ Remove track              editor.removeAudioTrack(id:)
//   ✓ EQ presets (7) + 5 bands  editor.applyTrackEffects(id:_:)
//   ✓ Pitch shift ±12           applyTrackEffects
//   ✓ Voice changer (6)         applyTrackEffects
//   ✓ Reverb (5) + wet mix      applyTrackEffects
//   ✓ Normalize to −14 LUFS     editor.normalizeTrack(id:targetLUFS:)
//   ✓ Reset effects             applyTrackEffects with a neutral settings value
//   ✓ Audio-reactive visuals    editor.setAudioReactive(_:) — pulse/glow/shake
//   ✗ Per-track preview player  the Sound Library's play/stop audition button.
//     Auditioning fights the timeline's own AVPlayer inside a preview screen;
//     the add path is fully wired, the audition is not redrawn.
//
// LAYERS / FX
//   ✓ Effect layers (8 kinds)   addEffectLayer + setEffectIntensity + remove
//   ✓ Particle layers (5 kinds) addParticleLayer + setParticleIntensity + remove
//   ✓ Adjustment layers         addAdjustmentLayer(grade:) from the real library
//   ✓ Clear adjustment layers   removeAdjustmentLayer(id:)
//
// PROJECT-WIDE
//   ✓ Format (16:9/9:16/1:1/4:5) editor.setFormat(_:zoom:)
//   ✓ Canvas mode (5)           editor.setCanvasMode(_:)
//   ✓ Frame preset (7)          editor.setFramePreset(_:)
//   ✓ Canvas zoom               editor.zoom
//   ✓ Templates                 editor.applyTemplate(_:) over TemplateLibrary.all
//   ✓ Auto captions             editor.generateCaptions()
//   ✓ Copy SRT                  editor.captionsSRT()
//   ✓ Add clip (video or photo) addClip(from:) / addPhotoClip(from:)
//   ✓ Record new footage        pushes the camera route
//   ✓ Open project library      pushes the project-library route
//   ✓ Colour grading screen     pushes .customLook (a separate LD preview)
//   ✓ Crop / format screen      pushes .cropFormat
//
// LOOKS
//   ✓ Real graded tiles         LookThumbs over app.library.stripLooks()
//   ✓ None tile
//   ✓ Selection = one white ring, nothing else
//
// =============================================================================

// MARK: - Monochrome atoms
//
// Every fill below is a LumaTheme token that is already white-at-an-opacity, so
// this screen inherits the app's elevation ladder without inheriting its violet.

/// Icon-over-label, unboxed. The whole tool-row grammar.
private struct LDToolItem: View {
    let title: String
    let icon: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.white : LumaTheme.textSecondary)
            .frame(width: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
    }
}

/// A pill. Selection is a ring; unselected is a value step. No accent.
private struct LDChip: View {
    let title: String
    var selected = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(selected ? Color.white : LumaTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(LumaTheme.surface, in: Capsule())
                .overlay {
                    if selected { Capsule().strokeBorder(Color.white, lineWidth: 1.2) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.32)
        .disabled(!enabled)
    }
}

/// A wide action row inside a panel — the "do it" affordances that are not
/// selections (Detect beats, Normalize, Remove…).
private struct LDAction: View {
    let title: String
    let icon: String
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if busy {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .light))
                }
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.32)
        .disabled(!enabled || busy)
    }
}

/// Mono microtype on every number, per the pro-cinema signature.
private struct LDSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var readout: (Double) -> String = { String(format: "%.2f", $0) }
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(LumaTheme.textSecondary)
                Spacer(minLength: 4)
                TechReadout(readout(value), size: 10, color: .white)
            }
            GeometryReader { geo in
                let span = range.upperBound - range.lowerBound
                let frac = span > 0 ? (value - range.lowerBound) / span : 0
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(LumaTheme.surfaceStrong).frame(height: 3)
                    Capsule().fill(Color.white.opacity(0.7))
                        .frame(width: max(0, w * frac), height: 3)
                    Circle().fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(0, w * frac - 6), w - 12))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(max(0, g.location.x / w), 1)
                            value = range.lowerBound + f * span
                        }
                        .onEnded { _ in onCommit() }
                )
            }
            .frame(height: 24)
        }
    }
}

/// Small section caption. Mono, muted, never a heading weight.
private struct LDCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { TechReadout(text, size: 9, color: LumaTheme.textMuted) }
}

/// Unit-square drag pad, used by the spot mask and the overlay position tools.
private struct LDPositionPad: View {
    let point: CGPoint
    let onChange: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LumaTheme.surface)
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                Circle().fill(Color.white).frame(width: 11, height: 11)
                    .position(x: point.x * w, y: point.y * h)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    onChange(CGPoint(x: min(max(0, g.location.x / w), 1),
                                     y: min(max(0, g.location.y / h), 1)))
                }
            )
        }
        .frame(height: 92)
    }
}

/// The one calm sentence a tool ends in. ✕ and ✓ at the edges, nothing shouted.
private struct LDInstructionBar: View {
    let sentence: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Text(sentence)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Button(action: onConfirm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Formatting

private enum LDFormat {
    static func secs(_ s: Double) -> String { String(format: "%.1fS", max(0, s)) }

    static func clock(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    static func timecode(_ s: Double, frameDuration: Double) -> String {
        let t = max(0, s)
        let f = frameDuration > 0 ? Int((t - floor(t)) / frameDuration) % 30 : 0
        return String(format: "%02d:%02d:%02d", Int(t) / 60, Int(t) % 60, f)
    }
}

// MARK: - Tools

private enum LDTool: Hashable {
    case none
    // project-level
    case looks, sticker, shape, effects, particles, adjLayer, template
    case canvas, captions, audioReactive, audioAdd, voice
    // clip-level
    case trim, speed, clipLook, motion, mask, transition, clipAudio, geometry
    // element-level
    case overlay, music
}

// MARK: - Screen

struct LDEditorDemoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()

    private var editor: EditorState { app.editor }

    @State private var tool: LDTool = .none
    @State private var timelineZoom: CGFloat = 50
    @AppStorage("timelineMagnet") private var magnetOn = true
    @State private var showFrames = true
    @State private var fullscreen = false

    @State private var selectedOverlayID: UUID?
    @State private var selectedAudioID: UUID?
    @State private var transitionAfterID: UUID?

    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    // Media entry
    @State private var addItem: PhotosPickerItem?
    @State private var overlayItem: PhotosPickerItem?
    @State private var replaceItem: PhotosPickerItem?
    @State private var showAddPicker = false
    @State private var showOverlayPicker = false
    @State private var showReplacePicker = false
    @State private var showFileImporter = false
    @State private var showCrop = false
    @State private var isLoading = false
    @State private var note: String?

    private var toolIsOpen: Bool { tool != .none }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: toolIsOpen ? 210 : nil, alignment: .center)
                    .frame(maxHeight: toolIsOpen ? 210 : .infinity)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                transport
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                timelineSection
                drawer
            }
            if let note {
                VStack {
                    Spacer()
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(LumaTheme.cardRaised, in: Capsule())
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.22), value: toolIsOpen)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.library.all.count) {
            thumbs.render(source: app.previewFrame, library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .onAppear(perform: resumeIfEmpty)
        .onDisappear { editor.saveProject() }
        .fullScreenCover(isPresented: $fullscreen) { fullscreenPlayer }
        .photosPicker(isPresented: $showAddPicker, selection: $addItem,
                      matching: .any(of: [.images, .videos]))
        .photosPicker(isPresented: $showOverlayPicker, selection: $overlayItem,
                      matching: .any(of: [.images, .videos]))
        .photosPicker(isPresented: $showReplacePicker, selection: $replaceItem,
                      matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false, onCompletion: handleAudioFile)
        .sheet(isPresented: $showCrop) { cropSheet }
        .onChange(of: addItem) { _, item in load(item, as: .main) }
        .onChange(of: overlayItem) { _, item in load(item, as: .overlay) }
        .onChange(of: replaceItem) { _, item in load(item, as: .replace) }
    }

    // MARK: Top bar — monochrome, Export is a plain word

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)

            Menu {
                Button("New Project") { editor.startNewProject(); tool = .none }
                Button("Open Project Library") { app.path.append(.projectLibrary) }
            } label: {
                HStack(spacing: 5) {
                    Text(editor.projectTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 4)

            Button { editor.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(editor.canUndo ? Color.white : LumaTheme.textMuted)
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress).disabled(!editor.canUndo)

            Button { editor.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(editor.canRedo ? Color.white : LumaTheme.textMuted)
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress).disabled(!editor.canRedo)

            Button { app.path.append(.ldExport) } label: {
                Text("Export")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.lumaPress)
            .opacity(editor.isEmpty ? 0.35 : 1)
            .disabled(editor.isEmpty)
        }
        .padding(.horizontal, 12)
    }

    // MARK: Preview — the image is the interface. Never covered.

    @ViewBuilder
    private var preview: some View {
        Group {
            if let player = editor.player {
                VideoPlayer(player: player)
                    .onDisappear { if editor.isPlaying { editor.togglePlayback() } }
            } else {
                emptyStage
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var emptyStage: some View {
        ZStack {
            Color(white: 0.07)
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView().tint(.white)
                    Text("Loading clip…").font(.system(size: 13)).foregroundStyle(.white)
                } else {
                    LDCaption("NOTHING ON THE TIMELINE")
                    HStack(spacing: 10) {
                        stageEntry("Add video", "plus") { showAddPicker = true }
                        stageEntry("Record", "record.circle") { app.path.append(.camera) }
                        stageEntry("Projects", "folder") { app.path.append(.projectLibrary) }
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .foregroundStyle(Color.white.opacity(0.14))
        }
    }

    private func stageEntry(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 18, weight: .light))
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(.white)
            .frame(width: 84, height: 74)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    private var fullscreenPlayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = editor.player { VideoPlayer(player: player).ignoresSafeArea() }
            VStack {
                HStack {
                    Spacer()
                    Button { fullscreen = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: Transport — every number in mono

    private var transport: some View {
        HStack(spacing: 0) {
            TechReadout(showFrames
                        ? "\(LDFormat.timecode(editor.currentTime, frameDuration: editor.frameDuration))  \(LDFormat.timecode(editor.totalDuration, frameDuration: editor.frameDuration))"
                        : "\(LDFormat.clock(editor.currentTime))  \(LDFormat.clock(editor.totalDuration))",
                        size: 10.5, color: LumaTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onLongPressGesture { showFrames.toggle(); LumaHaptics.shared.tap() }

            HStack(spacing: 24) {
                Button {} label: { Image(systemName: "backward.end").font(.system(size: 14, weight: .light)) }
                    .buttonStyle(LumaHoldButtonStyle(onTap: { editor.seekToBoundary(forward: false) },
                                                     onHold: { editor.stepFrame(-1) }))
                Button { editor.togglePlayback() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26)
                }
                .buttonStyle(.lumaPress)
                Button {} label: { Image(systemName: "forward.end").font(.system(size: 14, weight: .light)) }
                    .buttonStyle(LumaHoldButtonStyle(onTap: { editor.seekToBoundary(forward: true) },
                                                     onHold: { editor.stepFrame(1) }))
            }
            .foregroundStyle(.white)
            .opacity(editor.isEmpty ? 0.3 : 1)
            .disabled(editor.isEmpty)

            HStack(spacing: 16) {
                Spacer(minLength: 0)
                if editor.isRebuilding {
                    ProgressView().controlSize(.mini).tint(LumaTheme.textMuted)
                }
                Button { magnetOn.toggle(); LumaHaptics.shared.tap() } label: {
                    Image(systemName: magnetOn ? "magnet.fill" : "magnet")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(magnetOn ? Color.white : LumaTheme.textMuted)
                }
                .buttonStyle(.lumaPress)
                Button { fullscreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .light))
                }
                .buttonStyle(.lumaPress).disabled(editor.isEmpty)
                Button {
                    timelineZoom = nextZoom(timelineZoom)
                    LumaHaptics.shared.tap()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 13, weight: .light))
                        TechReadout(String(format: "%g", (timelineZoom / 50 * 10).rounded() / 10),
                                    size: 9, color: LumaTheme.textSecondary)
                    }
                }
                .buttonStyle(.lumaPress).disabled(editor.isEmpty)
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    private static let zoomSteps: [CGFloat] = [25, 50, 100, 200]

    private func nextZoom(_ current: CGFloat) -> CGFloat {
        let next = Self.zoomSteps.first { $0 > current + 0.5 } ?? Self.zoomSteps[0]
        return min(max(next, TimelineMetrics.minPPS), TimelineMetrics.maxPPS)
    }

    // MARK: Timeline — full stack, or a scrubbable mini strip when a tool is up

    @ViewBuilder
    private var timelineSection: some View {
        LDTimeline(editor: editor,
                   zoom: $timelineZoom,
                   magnet: magnetOn,
                   compact: toolIsOpen,
                   onTapTransition: { id in transitionAfterID = id; tool = .transition },
                   onTapOverlay: { id in selectedOverlayID = id; tool = .overlay },
                   onTapMusic: { id in selectedAudioID = id; tool = .music },
                   onTapClipAudio: { id in editor.selectedClipID = id; tool = .clipAudio },
                   onAddClip: { showAddPicker = true })
    }

    // MARK: Drawer — tool rows, or one tool + its instruction bar

    @ViewBuilder
    private var drawer: some View {
        VStack(spacing: 0) {
            if tool == .none {
                Rectangle().fill(LumaTheme.hairline).frame(height: 1)
                toolRow
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            } else {
                Rectangle().fill(LumaTheme.hairline).frame(height: 1)
                panelBody
                LDInstructionBar(sentence: instruction,
                                 onCancel: { closeTool() },
                                 onConfirm: { closeTool() })
                    .padding(.bottom, 2)
            }
        }
        .background(Color.black)
    }

    private func closeTool() {
        withAnimation(.snappy(duration: 0.2)) { tool = .none }
        LumaHaptics.shared.tap()
    }

    /// The tool row swaps on selection — context decides the tools, exactly as
    /// the shipping dock does. The last item is clipped so the row reads scrollable.
    @ViewBuilder
    private var toolRow: some View {
        if editor.selectedClipID != nil, !editor.isEmpty {
            HStack(spacing: 0) {
                Button {
                    editor.selectedClipID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .frame(width: 32, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) { clipTools }.padding(.trailing, 26)
                }
                .lumaEdgeFade(leading: 6, trailing: 20)
            }
            .padding(.horizontal, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) { projectTools }
                    .padding(.horizontal, 12)
                    .padding(.trailing, 26)
            }
            .lumaEdgeFade(leading: 14, trailing: 20)
        }
    }

    private var hasClips: Bool { !editor.isEmpty }

    @ViewBuilder
    private var projectTools: some View {
        LDToolItem(title: "Add", icon: "plus") { showAddPicker = true }
        LDToolItem(title: "Edit", icon: "scissors", enabled: hasClips) { selectClipAtPlayhead() }
        LDToolItem(title: "Looks", icon: "camera.filters", enabled: hasClips) { tool = .looks }
        LDToolItem(title: "Adjust", icon: "slider.horizontal.3", enabled: hasClips) {
            app.path.append(.customLook)
        }
        LDToolItem(title: "Text", icon: "textformat", enabled: hasClips) { addText() }
        LDToolItem(title: "Overlay", icon: "rectangle.on.rectangle", enabled: hasClips) {
            if editor.isEmpty { toast("Add a video clip first") } else { showOverlayPicker = true }
        }
        LDToolItem(title: "Sticker", icon: "face.smiling", enabled: hasClips) { tool = .sticker }
        LDToolItem(title: "Shape", icon: "square.on.circle", enabled: hasClips) { tool = .shape }
        LDToolItem(title: "Effects", icon: "sparkles", enabled: hasClips) { tool = .effects }
        LDToolItem(title: "Particles", icon: "sparkles.rectangle.stack", enabled: hasClips) { tool = .particles }
        LDToolItem(title: "Adj Layer", icon: "square.stack.3d.up", enabled: hasClips) { tool = .adjLayer }
        LDToolItem(title: "Audio", icon: "music.note", enabled: hasClips) { tool = .audioAdd }
        LDToolItem(title: editor.isRecordingVoiceover ? "Stop" : "Voice",
                   icon: editor.isRecordingVoiceover ? "stop.circle" : "mic",
                   active: editor.isRecordingVoiceover, enabled: hasClips) { tool = .voice }
        LDToolItem(title: "Audio FX", icon: "waveform.circle",
                   active: editor.audioReactive != nil,
                   enabled: !editor.audioTracks.isEmpty) { tool = .audioReactive }
        LDToolItem(title: "Captions", icon: "captions.bubble", enabled: hasClips) { tool = .captions }
        LDToolItem(title: "Template", icon: "wand.and.stars", enabled: hasClips) { tool = .template }
        LDToolItem(title: "Canvas", icon: "aspectratio", enabled: hasClips) { tool = .canvas }
        LDToolItem(title: "Spot", icon: "circle.dashed.inset.filled", enabled: hasClips) {
            if editor.selectedClipID == nil { editor.selectedClipID = editor.clips.first?.id }
            tool = .mask
        }
        LDToolItem(title: "Crop", icon: "crop", enabled: hasClips) { app.path.append(.cropFormat) }
    }

    @ViewBuilder
    private var clipTools: some View {
        let clip = editor.selectedClip
        LDToolItem(title: "Split", icon: "square.split.2x1") { editor.splitAtPlayhead(); LumaHaptics.shared.tap() }
        LDToolItem(title: "Trim", icon: "scissors") {
            if let c = clip { trimStart = c.trimStart; trimEnd = c.trimEnd }
            tool = .trim
        }
        LDToolItem(title: clip.map { $0.speed == 1 ? "Speed" : String(format: "%g×", $0.speed) } ?? "Speed",
                   icon: "gauge.with.needle") { tool = .speed }
        LDToolItem(title: "Look", icon: "camera.filters") { tool = .clipLook }
        LDToolItem(title: "Motion", icon: "arrow.up.left.and.down.right.magnifyingglass",
                   active: !(clip?.transformKeyframes.isEmpty ?? true)) { tool = .motion }
        LDToolItem(title: "Volume", icon: "speaker.wave.2") { tool = .clipAudio }
        LDToolItem(title: "Frame", icon: "rotate.right") { tool = .geometry }
        LDToolItem(title: "Crop", icon: "crop") { showCrop = true }
        LDToolItem(title: "Spot", icon: "circle.dashed.inset.filled") { tool = .mask }
        LDToolItem(title: "Freeze", icon: "snowflake") {
            LumaHaptics.shared.tap(); Task { await editor.freezeAtPlayhead() }
        }
        LDToolItem(title: editor.isBaking ? "Reversing" : "Reverse", icon: "backward",
                   enabled: clip?.isImage == false && !editor.isBaking) {
            LumaHaptics.shared.tap(); Task { await editor.reverseSelectedClip() }
        }
        LDToolItem(title: editor.isDetaching ? "Detaching" : "Detach", icon: "waveform.badge.minus",
                   enabled: clip?.hasAudio == true && !editor.isDetaching) {
            guard let id = editor.selectedClipID else { return }
            LumaHaptics.shared.tap(); Task { await editor.detachAudio(clipID: id) }
        }
        LDToolItem(title: "Replace", icon: "arrow.triangle.2.circlepath") { showReplacePicker = true }
        LDToolItem(title: "Duplicate", icon: "plus.square.on.square") {
            editor.duplicateSelected(); LumaHaptics.shared.tap()
        }
        LDToolItem(title: "Copy", icon: "doc.on.doc") { editor.copySelected(); toast("Clip copied") }
        LDToolItem(title: "Paste", icon: "doc.on.clipboard",
                   enabled: EditorState.clipboardClip != nil) { editor.pasteClip() }
        LDToolItem(title: "Move ◀", icon: "arrow.left.to.line") { editor.moveSelected(by: -1) }
        LDToolItem(title: "Move ▶", icon: "arrow.right.to.line") { editor.moveSelected(by: 1) }
        LDToolItem(title: "Delete", icon: "trash") { editor.deleteSelected(ripple: true) }
        LDToolItem(title: "Lift", icon: "trash.slash") { editor.deleteSelected(ripple: false) }
    }

    // MARK: Instruction sentences

    private var instruction: String {
        switch tool {
        case .none:          return ""
        case .looks:         return "Choose a look for the whole edit"
        case .clipLook:      return "Choose a look for this clip"
        case .sticker:       return "Tap a sticker to drop it at the playhead"
        case .shape:         return "Pick a shape to add"
        case .effects:       return "Add an effect, then set its strength"
        case .particles:     return "Add particles, then set their density"
        case .adjLayer:      return "Grade a span of the timeline"
        case .template:      return "Pick a template to restyle the cut"
        case .canvas:        return "Set the frame this project renders into"
        case .captions:      return "Transcribe speech into text overlays"
        case .audioReactive: return "Let the sound drive the picture"
        case .audioAdd:      return "Add music, sound effects or a file"
        case .voice:         return "Record a voiceover over the timeline"
        case .trim:          return "Set where this clip starts and ends"
        case .speed:         return "Set the speed of this clip"
        case .motion:        return "Add a pan or zoom to this clip"
        case .mask:          return "Blur, pixelate or fill a spot"
        case .transition:    return "Choose what happens at this cut"
        case .clipAudio:     return "Balance this clip's own sound"
        case .geometry:      return "Rotate or mirror this clip"
        case .overlay:       return "Place and style this overlay"
        case .music:         return "Shape this audio lane"
        }
    }

    // MARK: Panel body

    @ViewBuilder
    private var panelBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch tool {
                case .none:          EmptyView()
                case .looks:         looksPanel(clipID: nil)
                case .clipLook:      looksPanel(clipID: editor.selectedClipID)
                case .sticker:       LDStickerPanel(editor: editor)
                case .shape:         shapePanel
                case .effects:       LDEffectsPanel(editor: editor, particles: false)
                case .particles:     LDEffectsPanel(editor: editor, particles: true)
                case .adjLayer:      adjustmentPanel
                case .template:      templatePanel
                case .canvas:        LDCanvasPanel(editor: editor)
                case .captions:      captionsPanel
                case .audioReactive: LDAudioReactivePanel(editor: editor)
                case .audioAdd:      audioAddPanel
                case .voice:         voicePanel
                case .trim:          trimPanel
                case .speed:         LDSpeedPanel(editor: editor)
                case .motion:        LDMotionPanel(editor: editor)
                case .mask:          LDMaskPanel(editor: editor)
                case .transition:    LDTransitionPanel(editor: editor, afterClipID: transitionAfterID)
                case .clipAudio:     clipAudioPanel
                case .geometry:      geometryPanel
                case .overlay:       LDOverlayPanel(editor: editor, overlayID: selectedOverlayID)
                case .music:         LDMusicPanel(editor: editor, trackID: selectedAudioID)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 300)
    }

    // MARK: Looks (whole edit, or one clip) — real graded tiles

    @ViewBuilder
    private func looksPanel(clipID: UUID?) -> some View {
        LDCaption(clipID == nil ? "LOOK · WHOLE EDIT" : "LOOK · SELECTED CLIP")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                noneTile(clipID: clipID)
                ForEach(app.library.stripLooks()) { look in
                    Button {
                        app.select(look: look, forClip: clipID)
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let cg = thumbs.images[LookThumbs.key(look)] {
                                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color(white: 0.12)
                                }
                            }
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                if isLookActive(look, clipID: clipID) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 2)
                                }
                            }
                            Text(look.name)
                                .font(.system(size: 10))
                                .foregroundStyle(isLookActive(look, clipID: clipID)
                                                 ? Color.white : LumaTheme.textMuted)
                                .lineLimit(1).frame(width: 68)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.trailing, 24)
        }
        .lumaEdgeFade(leading: 0, trailing: 16)
        if let clipID, let grade = editor.clips.first(where: { $0.id == clipID })?.grade {
            LDAction(title: "Apply this look to every clip", icon: "square.stack.3d.down.right") {
                editor.applyGradeToAllClips(grade)
                LumaHaptics.shared.tap()
            }
        }
    }

    private func noneTile(clipID: UUID?) -> some View {
        let active: Bool = {
            if let clipID { return editor.clips.first(where: { $0.id == clipID })?.grade == nil }
            return false
        }()
        return Button {
            if let clipID { editor.setClipGrade(id: clipID, nil) }
            else { editor.applyGradeToAllClips(nil) }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color(white: 0.12)
                    Image(systemName: "circle.slash")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white, lineWidth: 2)
                    }
                }
                Text("None").font(.system(size: 10))
                    .foregroundStyle(active ? Color.white : LumaTheme.textMuted)
                    .frame(width: 68)
            }
        }
        .buttonStyle(.lumaPress)
    }

    private func isLookActive(_ look: LibraryLook, clipID: UUID?) -> Bool {
        if let clipID {
            guard let g = editor.clips.first(where: { $0.id == clipID })?.grade else { return false }
            let target = look.clipGrade()
            return g.baseLookName == target.baseLookName && g.lutID == target.lutID
        }
        return app.isCurrent(look)
    }

    // MARK: Shapes

    @ViewBuilder
    private var shapePanel: some View {
        LDCaption("SHAPE")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(ShapeKind.allCases, id: \.self) { kind in
                Button {
                    if let id = editor.addShapeOverlay(kind: kind) {
                        selectedOverlayID = id
                        tool = .overlay
                        LumaHaptics.shared.tap()
                    }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: kind.icon).font(.system(size: 18, weight: .light))
                        Text(kind.label).font(.system(size: 9.5)).lineLimit(1)
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 66)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.lumaPress)
            }
        }
    }

    // MARK: Adjustment layers

    @ViewBuilder
    private var adjustmentPanel: some View {
        LDCaption("GRADE A SPAN · \(editor.adjustmentLayers.count) LAYER(S)")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(app.library.stripLooks()) { look in
                    Button {
                        editor.addAdjustmentLayer(grade: look.clipGrade())
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let cg = thumbs.images[LookThumbs.key(look)] {
                                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else { Color(white: 0.12) }
                            }
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(look.name).font(.system(size: 9.5))
                                .foregroundStyle(LumaTheme.textMuted).lineLimit(1).frame(width: 62)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.trailing, 24)
        }
        .lumaEdgeFade(leading: 0, trailing: 16)
        ForEach(editor.adjustmentLayers) { layer in
            HStack(spacing: 10) {
                Text(layer.grade.baseLookName.isEmpty ? "LUT" : layer.grade.baseLookName)
                    .font(.system(size: 12)).foregroundStyle(.white)
                Spacer()
                TechReadout(LDFormat.secs(layer.duration), size: 10, color: LumaTheme.textMuted)
                Button { editor.removeAdjustmentLayer(id: layer.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .light))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .buttonStyle(.lumaPress)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    // MARK: Templates

    @ViewBuilder
    private var templatePanel: some View {
        LDCaption("TEMPLATE")
        if editor.clips.isEmpty {
            Text("Templates restyle clips you already have. Add footage first.")
                .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
        }
        ForEach(TemplateLibrary.all) { template in
            Button {
                if editor.applyTemplate(template) {
                    LumaHaptics.shared.tap()
                    closeTool()
                } else { toast("Add a clip first") }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: template.icon)
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(LumaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        TechReadout("\(template.aspect) · \(template.slots.count) SHOTS · \(LDFormat.secs(template.totalDuration))",
                                    size: 9, color: LumaTheme.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.lumaPress)
            .opacity(editor.clips.isEmpty ? 0.4 : 1)
            .disabled(editor.clips.isEmpty)
        }
    }

    // MARK: Captions

    @State private var isCaptioning = false

    @ViewBuilder
    private var captionsPanel: some View {
        LDCaption("CAPTIONS")
        LDAction(title: isCaptioning ? "Transcribing…" : "Transcribe speech",
                 icon: "captions.bubble", busy: isCaptioning) {
            isCaptioning = true
            Task {
                let n = await editor.generateCaptions()
                isCaptioning = false
                toast(n == 0 ? "No speech found — check Speech Recognition access" : "Added \(n) captions")
            }
        }
        LDAction(title: "Copy SRT", icon: "doc.on.doc") {
            UIPasteboard.general.string = editor.captionsSRT()
            toast("SRT copied")
        }
        Text("Captions land as text overlays you can restyle like any other.")
            .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
    }

    // MARK: Audio add

    @ViewBuilder
    private var audioAddPanel: some View {
        LDCaption("SOUND LIBRARY")
        ForEach(BundledAudioLibrary.all) { entry in
            Button {
                guard let url = BundledAudioLibrary.url(for: entry) else { return }
                guard let imported = editor.importMusicFile(from: url) else {
                    toast("Could not import that file"); return
                }
                Task {
                    await editor.addAudioTrack(importedURL: imported, title: entry.title,
                                               kind: entry.category == "sfx" ? .sfx : .music)
                    LumaHaptics.shared.tap()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.category == "sfx" ? "sparkles" : "music.note")
                        .font(.system(size: 13, weight: .light)).foregroundStyle(.white)
                        .frame(width: 26)
                    Text(entry.title).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 6)
                    TechReadout(LDFormat.secs(entry.duration), size: 10, color: LumaTheme.textMuted)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.lumaPress)
        }
        LDAction(title: "Import from Files", icon: "folder") { showFileImporter = true }
    }

    // MARK: Voiceover

    @ViewBuilder
    private var voicePanel: some View {
        LDCaption(editor.isRecordingVoiceover ? "RECORDING" : "VOICEOVER")
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                let lit = Double(i) / 28.0 < editor.inputLevel
                Capsule()
                    .fill(lit ? Color.white : LumaTheme.surfaceStrong)
                    .frame(width: 3, height: 6 + CGFloat(i % 5) * 4)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.08), value: editor.inputLevel)
        LDAction(title: editor.isRecordingVoiceover ? "Stop recording" : "Start recording",
                 icon: editor.isRecordingVoiceover ? "stop.circle" : "mic") {
            if editor.isRecordingVoiceover {
                editor.stopVoiceover()
                LumaHaptics.shared.exportSuccess()
            } else if editor.totalDuration > 0.4 {
                editor.startVoiceover()
                LumaHaptics.shared.tap()
            } else {
                toast("Add a video clip first")
            }
        }
        Text("Recording plays the timeline back so you can talk to picture. The take lands as its own lane.")
            .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
    }

    // MARK: Trim

    @ViewBuilder
    private var trimPanel: some View {
        if let clip = editor.selectedClip {
            LDCaption("TRIM · \(LDFormat.secs(max(0, trimEnd - trimStart)))")
            LDSlider(label: "Start", value: $trimStart, range: 0...max(0.1, clip.assetDuration),
                     readout: { LDFormat.secs($0) },
                     onCommit: { commitTrim(clip) })
            LDSlider(label: "End", value: $trimEnd, range: 0...max(0.1, clip.assetDuration),
                     readout: { LDFormat.secs($0) },
                     onCommit: { commitTrim(clip) })
            Text("The handles on the selected clip in the timeline do the same thing.")
                .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
        }
    }

    private func commitTrim(_ clip: EditorState.Clip) {
        let s = min(trimStart, trimEnd - 0.1)
        let e = max(trimEnd, s + 0.1)
        editor.selectedClipID = clip.id
        editor.applyTrim(start: max(0, s), end: min(clip.assetDuration, e))
    }

    // MARK: Rotate / mirror

    @ViewBuilder
    private var geometryPanel: some View {
        if let clip = editor.selectedClip {
            LDCaption("FRAME")
            HStack(spacing: 8) {
                LDChip(title: "Rotate 90°", selected: clip.rotationQuarterTurns != 0) {
                    editor.rotateSelectedClip(); LumaHaptics.shared.tap()
                }
                LDChip(title: "Mirror", selected: clip.isMirrored) {
                    editor.mirrorSelectedClip(); LumaHaptics.shared.tap()
                }
                LDChip(title: "Crop & straighten") { showCrop = true }
            }
            TechReadout("ROTATION \(clip.rotationQuarterTurns * 90)°  ·  STRAIGHTEN \(Int(clip.straightenDegrees))°",
                        size: 10, color: LumaTheme.textMuted)
        }
    }

    // MARK: Clip sound

    @ViewBuilder
    private var clipAudioPanel: some View {
        if let clip = editor.selectedClip {
            LDCaption("CLIP SOUND · \(LDFormat.secs(clip.timelineDuration))")
            LDSlider(label: "Volume",
                     value: Binding(get: { clip.volume },
                                    set: { editor.setClipVolume(id: clip.id, $0) }),
                     range: 0...200, readout: { "\(Int($0))%" })
            HStack(spacing: 8) {
                LDChip(title: clip.isMuted ? "Unmute clip" : "Mute clip", selected: clip.isMuted) {
                    editor.setClipMuted(id: clip.id, !clip.isMuted)
                }
                LDChip(title: editor.isDetaching ? "Detaching…" : "Detach audio",
                       enabled: clip.hasAudio && !editor.isDetaching) {
                    Task { await editor.detachAudio(clipID: clip.id) }
                }
            }
            if !clip.hasAudio {
                Text("This clip has no audio track of its own.")
                    .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
            }
        }
    }

    // MARK: Crop sheet

    @ViewBuilder
    private var cropSheet: some View {
        if let clip = editor.selectedClip {
            CropStraightenView(thumbnail: clip.thumbnail,
                               aspect: editor.format.aspect,
                               initialCrop: clip.cropRect,
                               initialStraighten: clip.straightenDegrees,
                               onApply: { rect, deg in
                                   editor.setCropStraighten(id: clip.id, cropRect: rect, straightenDegrees: deg)
                                   showCrop = false
                               },
                               onCancel: { showCrop = false })
            .presentationDetents([.large])
            .presentationBackground(Color.black)
        }
    }

    // MARK: Plumbing

    private enum PickTarget { case main, overlay, replace }

    private func load(_ item: PhotosPickerItem?, as target: PickTarget) {
        guard let item else { return }
        isLoading = true
        Task {
            defer {
                isLoading = false
                switch target {
                case .main: addItem = nil
                case .overlay: overlayItem = nil
                case .replace: replaceItem = nil
                }
            }
            let video = try? await item.loadTransferable(type: PickedVideo.self)
            let imageURL: URL? = video == nil ? await Self.imageFile(from: item) : nil
            switch target {
            case .main:
                if let video { await editor.addClip(from: video.url); editor.selectedClipID = editor.clips.last?.id }
                else if let imageURL { await editor.addPhotoClip(from: imageURL) }
            case .overlay:
                let before = Set(editor.overlays.map(\.id))
                if let video { await editor.addOverlay(from: video.url, isImage: false) }
                else if let imageURL { await editor.addOverlay(from: imageURL, isImage: true) }
                if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
                    selectedOverlayID = added.id
                    tool = .overlay
                }
            case .replace:
                guard let id = editor.selectedClipID else { return }
                if let video { await editor.replaceClip(id: id, with: video.url) }
                else if let imageURL { await editor.replaceClip(id: id, with: imageURL) }
            }
        }
    }

    private static func imageFile(from item: PhotosPickerItem) async -> URL? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ld-\(UUID().uuidString).jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }

    private func handleAudioFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let src = urls.first else { return }
        let scoped = src.startAccessingSecurityScopedResource()
        // Import synchronously while the scope is open — required by the engine.
        let imported = editor.importMusicFile(from: src)
        if scoped { src.stopAccessingSecurityScopedResource() }
        guard let imported else { toast("Could not import that file"); return }
        let title = src.deletingPathExtension().lastPathComponent
        Task { await editor.addAudioTrack(importedURL: imported, title: title, kind: .music) }
    }

    private func addText() {
        let before = Set(editor.overlays.map(\.id))
        editor.addTextOverlay()
        if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
            selectedOverlayID = added.id
            tool = .overlay
        } else {
            toast("Add a video clip first")
        }
    }

    private func selectClipAtPlayhead() {
        guard !editor.isEmpty else { return }
        var elapsed: Double = 0
        for clip in editor.clips {
            elapsed += clip.timelineDuration
            if editor.currentTime < elapsed { editor.selectedClipID = clip.id; return }
        }
        editor.selectedClipID = editor.clips.last?.id
    }

    private func resumeIfEmpty() {
        guard editor.isEmpty else { return }
        if let url = app.selectedVideoURL {
            Task { await editor.addClip(from: url) }
        } else if let last = app.store.projects.max(by: { $0.updatedAt < $1.updatedAt }) {
            editor.load(project: last)
        }
    }

    private func toast(_ message: String) {
        withAnimation { note = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { note = nil }
        }
    }
}

// MARK: - Timeline

/// The lane stack. Real filmstrips, real waveforms, real beat markers.
/// The playhead follows playback; the ruler is the scrub surface.
private struct LDTimeline: View {
    @ObservedObject var editor: EditorState
    @Binding var zoom: CGFloat
    let magnet: Bool
    let compact: Bool
    let onTapTransition: (UUID) -> Void
    let onTapOverlay: (UUID) -> Void
    let onTapMusic: (UUID) -> Void
    let onTapClipAudio: (UUID) -> Void
    let onAddClip: () -> Void

    @State private var trimDraft: (id: UUID, start: Double, end: Double)?
    @State private var zoomAnchor: CGFloat = 50

    private var duration: Double { max(editor.totalDuration, 0.001) }
    private var contentWidth: CGFloat { max(60, CGFloat(duration) * zoom) }

    private var overlayLanes: Int { max(1, editor.maxOverlayLane + 1) }

    private var stackHeight: CGFloat {
        let ruler: CGFloat = 15
        let video: CGFloat = compact ? 34 : 56
        let clipAudio: CGFloat = compact ? 0 : 14
        let overlays: CGFloat = compact ? 0 : CGFloat(overlayLanes) * 20
        let music: CGFloat = compact ? 0 : CGFloat(editor.audioTracks.count) * 24
        return ruler + video + clipAudio + overlays + music + 16
    }

    var body: some View {
        Group {
            if editor.isEmpty && editor.audioTracks.isEmpty {
                emptyState
            } else {
                populated
            }
        }
        .frame(height: stackHeight + 8)
    }

    // The empty state teaches the multi-track model, as the real editor's does.
    private var emptyState: some View {
        VStack(spacing: 6) {
            laneHint("VIDEO", "film", enabled: true)
            laneHint("OVERLAY · TEXT", "rectangle.on.rectangle", enabled: false)
            laneHint("MUSIC", "music.note", enabled: false)
            laneHint("VOICEOVER", "mic", enabled: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func laneHint(_ title: String, _ icon: String, enabled: Bool) -> some View {
        Button { if enabled { onAddClip() } } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .light))
                TechReadout(title, size: 9, color: enabled ? LumaTheme.textSecondary : LumaTheme.textMuted)
                Spacer(minLength: 0)
                TechReadout(enabled ? "ADD" : "ADD A CLIP FIRST", size: 9, color: LumaTheme.textMuted)
            }
            .foregroundStyle(enabled ? Color.white.opacity(0.8) : LumaTheme.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(enabled ? 0.20 : 0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
    }

    private var populated: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ruler
                        videoLane
                        if !compact {
                            clipAudioLane
                            ForEach((0..<overlayLanes).reversed(), id: \.self) { lane in
                                overlayLane(lane)
                            }
                            ForEach(editor.audioTracks) { track in
                                musicLane(track)
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)

                    // Scroll-follow anchors, one per second.
                    HStack(spacing: 0) {
                        ForEach(0...max(1, Int(duration)), id: \.self) { s in
                            Color.clear.frame(width: zoom, height: 1).id("t\(s)")
                        }
                    }

                    playhead
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: editor.currentTime) { _, t in
                guard editor.isPlaying else { return }
                withAnimation(.linear(duration: 0.2)) {
                    proxy.scrollTo("t\(Int(t))", anchor: .center)
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        zoom = min(max(zoomAnchor * scale, TimelineMetrics.minPPS), TimelineMetrics.maxPPS)
                    }
                    .onEnded { _ in zoomAnchor = zoom }
            )
            .onAppear { zoomAnchor = zoom }
        }
    }

    // MARK: Ruler — also the scrub surface

    private var ruler: some View {
        let stride: Double = zoom < 20 ? 10 : (zoom < 45 ? 5 : (zoom < 110 ? 2 : 1))
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                var t: Double = 0
                while t <= duration {
                    let x = CGFloat(t) * zoom
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: x, y: size.height - 5))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(.white.opacity(0.22)), lineWidth: 1)
                    ctx.draw(Text(LDFormat.clock(t))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.32)),
                             at: CGPoint(x: x + 13, y: 5))
                    t += stride
                }
            }
            .frame(width: contentWidth, height: 15)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    editor.seek(to: min(max(0, Double(g.location.x / zoom)), duration))
                }
        )
    }

    // MARK: Video lane

    private var videoLane: some View {
        HStack(spacing: 0) {
            ForEach(editor.clips) { clip in
                let w = max(6, CGFloat(clip.timelineDuration) * zoom)
                LDClipCell(clip: clip, width: w, height: compact ? 34 : 56,
                           selected: editor.selectedClipID == clip.id)
                    .onTapGesture {
                        editor.selectedClipID = editor.selectedClipID == clip.id ? nil : clip.id
                        LumaHaptics.shared.tap()
                    }
                    .overlay(alignment: .leading) {
                        if editor.selectedClipID == clip.id, !compact { trimGrip(clip, head: true) }
                    }
                    .overlay(alignment: .trailing) {
                        if editor.selectedClipID == clip.id, !compact { trimGrip(clip, head: false) }
                    }
                    .overlay(alignment: .trailing) {
                        if !compact, clip.id != editor.clips.last?.id {
                            transitionChip(clip)
                                .offset(x: 11)
                                .zIndex(2)
                        }
                    }
            }
        }
        .padding(.top, 4)
    }

    private func transitionChip(_ clip: EditorState.Clip) -> some View {
        Button { onTapTransition(clip.id) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(clip.transitionAfter == .none ? LumaTheme.surfaceStrong : Color.white)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(45))
                Image(systemName: clip.transitionAfter == .none ? "plus" : clip.transitionAfter.icon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(clip.transitionAfter == .none ? Color.white.opacity(0.7) : .black)
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }

    private func trimGrip(_ clip: EditorState.Clip, head: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 5, height: 34)
            .padding(.horizontal, 2)
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let delta = Double(g.translation.width / zoom) * clip.speed
                        var s = clip.trimStart, e = clip.trimEnd
                        if head { s = min(max(0, clip.trimStart + delta), clip.trimEnd - 0.1) }
                        else { e = max(min(clip.assetDuration, clip.trimEnd + delta), clip.trimStart + 0.1) }
                        trimDraft = (clip.id, s, e)
                    }
                    .onEnded { _ in
                        if let d = trimDraft, d.id == clip.id {
                            editor.selectedClipID = clip.id
                            editor.applyTrim(start: d.start, end: d.end)
                            LumaHaptics.shared.tap()
                        }
                        trimDraft = nil
                    }
            )
    }

    // MARK: Clip audio lane

    private var clipAudioLane: some View {
        HStack(spacing: 0) {
            ForEach(editor.clips) { clip in
                let w = max(4, CGFloat(clip.timelineDuration) * zoom)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(clip.hasAudio && !clip.isMuted ? LumaTheme.surfaceStrong : LumaTheme.surface)
                    .frame(width: max(2, w - 2), height: 12)
                    .overlay(alignment: .leading) {
                        if clip.hasAudio {
                            Image(systemName: clip.isMuted ? "speaker.slash" : "waveform")
                                .font(.system(size: 7, weight: .light))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.horizontal, 1)
                    .contentShape(Rectangle())
                    .onTapGesture { onTapClipAudio(clip.id) }
            }
        }
        .frame(height: 14, alignment: .center)
    }

    // MARK: Overlay lanes

    private func overlayLane(_ lane: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).frame(width: contentWidth, height: 20)
            ForEach(editor.overlays.filter { $0.lane == lane }) { item in
                overlayBar(item)
                    .offset(x: CGFloat(item.timelineOffset) * zoom)
            }
        }
        .frame(height: 20)
    }

    private func overlayBar(_ item: EditorState.OverlayItem) -> some View {
        let w = max(10, CGFloat(item.duration) * zoom)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LumaTheme.cardRaised)
            .frame(width: w, height: 16)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    Image(systemName: item.text != nil ? "textformat"
                          : (item.kind == "sticker" ? "face.smiling"
                             : (item.shapeKind != nil ? "square.on.circle" : "rectangle.on.rectangle")))
                        .font(.system(size: 7, weight: .light))
                    Text(item.text ?? (item.title.isEmpty ? "Overlay" : item.title))
                        .font(.system(size: 8)).lineLimit(1)
                }
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onTapGesture { onTapOverlay(item.id) }
            .highPriorityGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { g in
                        let raw = item.timelineOffset + Double(g.translation.width / zoom)
                        editor.setOverlayOffset(id: item.id, snapped(raw))
                    }
            )
    }

    // MARK: Music lanes

    private func musicLane(_ track: EditorState.MusicTrack) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).frame(width: contentWidth, height: 24)
            musicBar(track).offset(x: CGFloat(track.timelineOffset) * zoom)
        }
        .frame(height: 24)
    }

    private func musicBar(_ track: EditorState.MusicTrack) -> some View {
        let w = max(14, CGFloat(track.timelineDuration) * zoom)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(track.isMuted ? LumaTheme.surface : LumaTheme.surfaceStrong)
            LDWaveform(samples: track.waveform)
                .padding(.horizontal, 3)
                .opacity(track.isMuted ? 0.25 : 0.85)
            // Beat markers, drawn as hairlines on the lane itself.
            ForEach(Array(track.beatMarkers.enumerated()), id: \.offset) { _, beat in
                Rectangle().fill(Color.white.opacity(0.5))
                    .frame(width: 1, height: 20)
                    .offset(x: CGFloat(beat) * zoom)
            }
            HStack(spacing: 4) {
                Image(systemName: track.kind.icon).font(.system(size: 7, weight: .light))
                Text(track.title).font(.system(size: 8)).lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 5)
        }
        .frame(width: w, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onTapGesture { onTapMusic(track.id) }
        .highPriorityGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { g in
                    let raw = track.timelineOffset + Double(g.translation.width / zoom)
                    editor.setMusicOffset(id: track.id, snapped(raw))
                }
        )
    }

    private func snapped(_ time: Double) -> Double {
        let t = max(0, time)
        guard magnet else { return t }
        let window = Double(8 / zoom)
        return TimelineSnap.nearest(to: t, editor: editor, within: window) ?? t
    }

    // MARK: Playhead

    private var playhead: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 1.5, height: stackHeight)
            .overlay(alignment: .top) {
                Circle().fill(Color.white).frame(width: 7, height: 7).offset(y: -3)
            }
            .offset(x: CGFloat(editor.currentTime) * zoom)
            .allowsHitTesting(false)
    }
}

/// The clip cell IS a preview: real filmstrip frames, tiled.
private struct LDClipCell: View {
    let clip: EditorState.Clip
    let width: CGFloat
    let height: CGFloat
    let selected: Bool

    private var tiles: Int { max(1, Int(ceil(width / 40))) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tiles, id: \.self) { i in
                Group {
                    if let cg = frame(i) {
                        Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(white: 0.14)
                    }
                }
                .frame(width: width / CGFloat(tiles), height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if clip.speed != 1 { TechReadout(String(format: "%g×", clip.speed), size: 8, color: .white) }
                TechReadout(LDFormat.secs(clip.timelineDuration), size: 8, color: .white.opacity(0.75))
                if let g = clip.grade {
                    TechReadout(g.baseLookName.isEmpty ? "LUT"
                                : (g.baseLookName.split(separator: " ").last.map(String.init) ?? "LUT").uppercased(),
                                size: 8, color: .white)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
            .padding(3)
            .allowsHitTesting(false)
        }
        // Stroke means selection, and nothing else.
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 1)
    }

    private func frame(_ index: Int) -> CGImage? {
        guard !clip.filmstrip.isEmpty else { return clip.thumbnail }
        let f = tiles > 1 ? Double(index) / Double(tiles - 1) : 0
        let i = min(clip.filmstrip.count - 1, max(0, Int((f * Double(clip.filmstrip.count - 1)).rounded())))
        return clip.filmstrip[i]
    }
}

/// Monochrome RMS bars.
private struct LDWaveform: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int(geo.size.width / 2.5))
            Path { p in
                for i in 0..<count {
                    let x = CGFloat(i) * 2.5
                    let v: CGFloat = {
                        guard !samples.isEmpty else { return 0.08 }
                        let idx = min(samples.count - 1, Int(Double(i) / Double(count) * Double(samples.count)))
                        return CGFloat(max(0.05, min(1, samples[idx])))
                    }()
                    let h = v * geo.size.height
                    p.move(to: CGPoint(x: x, y: geo.size.height / 2 - h / 2))
                    p.addLine(to: CGPoint(x: x, y: geo.size.height / 2 + h / 2))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1.2)
        }
    }
}

// MARK: - Speed

private struct LDSpeedPanel: View {
    @ObservedObject var editor: EditorState

    private let presets: [Double] = [0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("CONSTANT")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(presets, id: \.self) { speed in
                    let on = editor.selectedClip?.speed == speed
                    Button {
                        editor.setClipSpeed(speed); LumaHaptics.shared.tap()
                    } label: {
                        Text(String(format: "%g×", speed))
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(on ? Color.white : LumaTheme.textSecondary)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                if on {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 1.2)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.lumaPress)
                }
            }

            LDCaption("RAMP")
            // Each ramp draws its own curve — the tile shows what it does.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditorState.SpeedRamp.allCases, id: \.self) { ramp in
                        let on = editor.selectedClip?.speedRamp == ramp.rawValue
                        Button {
                            editor.setSpeedRamp(ramp); LumaHaptics.shared.tap()
                        } label: {
                            VStack(spacing: 6) {
                                LDRampCurve(ramp: ramp)
                                    .frame(width: 62, height: 30)
                                Text(ramp.label).font(.system(size: 9.5))
                                    .foregroundStyle(on ? Color.white : LumaTheme.textMuted)
                                    .lineLimit(1).frame(width: 62)
                            }
                            .padding(6)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                if on {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 1.2)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.trailing, 24)
            }
            .lumaEdgeFade(leading: 0, trailing: 16)

            Text("Audio is pitch-preserved at every speed.")
                .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
        }
    }
}

/// The ramp's real `speed(at:)` curve, plotted. Not an icon.
private struct LDRampCurve: View {
    let ramp: EditorState.SpeedRamp

    var body: some View {
        GeometryReader { geo in
            Path { p in
                let n = 24
                for i in 0...n {
                    let t = Double(i) / Double(n)
                    let s = ramp.speed(at: t)
                    let y = geo.size.height * (1 - CGFloat(min(max(s / 4, 0), 1)))
                    let pt = CGPoint(x: geo.size.width * CGFloat(t), y: y)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Color.white.opacity(0.8), lineWidth: 1.4)
        }
    }
}

// MARK: - Motion

private struct LDMotionPanel: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("PAN & ZOOM")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(EditorState.KenBurnsPreset.allCases, id: \.self) { preset in
                    LDChip(title: preset.rawValue == "none" ? "None" : label(preset)) {
                        guard let id = editor.selectedClipID else { return }
                        editor.setKenBurns(id: id, preset: preset)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            if !(editor.selectedClip?.transformKeyframes.isEmpty ?? true) {
                LDCaption("EASING")
                HStack(spacing: 8) {
                    ForEach(KeyframeEasing.allCases, id: \.self) { ease in
                        LDChip(title: ease.label) {
                            guard let id = editor.selectedClipID else { return }
                            editor.setKenBurnsEasing(id: id, easing: ease)
                            LumaHaptics.shared.tap()
                        }
                    }
                }
                TechReadout("\(editor.selectedClip?.transformKeyframes.count ?? 0) KEYFRAMES",
                            size: 9, color: LumaTheme.textMuted)
            }
        }
    }

    private func label(_ p: EditorState.KenBurnsPreset) -> String {
        switch p {
        case .none: return "None"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .panLeft: return "Pan Left"
        case .panRight: return "Pan Right"
        case .panUp: return "Pan Up"
        case .panDown: return "Pan Down"
        }
    }
}

// MARK: - Transition

private struct LDTransitionPanel: View {
    @ObservedObject var editor: EditorState
    let afterClipID: UUID?

    private var current: TransitionStyle {
        guard let id = afterClipID else { return .none }
        return editor.clips.first { $0.id == id }?.transitionAfter ?? .none
    }

    private var currentDuration: Double {
        guard let id = afterClipID else { return 0.6 }
        return editor.clips.first { $0.id == id }?.transitionDuration ?? current.duration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(["Basic", "Motion", "FX"], id: \.self) { group in
                let styles = TransitionStyle.allCases.filter { $0.category == group }
                if !styles.isEmpty {
                    LDCaption(group.uppercased())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(styles, id: \.self) { style in
                            let on = current == style
                            Button {
                                guard let id = afterClipID else { return }
                                editor.setTransition(afterClipID: id, style: style, duration: currentDuration)
                                LumaHaptics.shared.tap()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: style.icon)
                                        .font(.system(size: 15, weight: .light))
                                    Text(style.label).font(.system(size: 9)).lineLimit(1)
                                }
                                .foregroundStyle(on ? Color.white : LumaTheme.textSecondary)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    if on {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(Color.white, lineWidth: 1.2)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.lumaPress)
                        }
                    }
                }
            }

            LDCaption("DURATION")
            HStack(spacing: 8) {
                ForEach([0.3, 0.6, 1.0, 1.5], id: \.self) { seconds in
                    LDChip(title: String(format: "%gs", seconds),
                           selected: abs(currentDuration - seconds) < 0.01) {
                        guard let id = afterClipID else { return }
                        editor.setTransition(afterClipID: id, style: current, duration: seconds)
                        LumaHaptics.shared.tap()
                    }
                }
            }

            if current != .none, editor.clips.count > 2 {
                LDAction(title: "Use this transition at every cut", icon: "arrow.triangle.branch") {
                    editor.setTransitionForAllCuts(style: current, duration: currentDuration)
                    LumaHaptics.shared.tap()
                }
            }
        }
    }
}

// MARK: - Spot mask

private struct LDMaskPanel: View {
    @ObservedObject var editor: EditorState

    private var clip: EditorState.Clip? { editor.selectedClip ?? editor.clips.first }
    private var shape: ClipMaskShape? { ClipMaskShape(rawValue: clip?.maskShape ?? "") }
    private var effect: ClipMaskEffect {
        ClipMaskEffect(rawValue: clip?.maskEffect ?? "") ?? .blur
    }

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 16) {
                LDCaption("SHAPE")
                HStack(spacing: 8) {
                    ForEach(ClipMaskShape.allCases, id: \.self) { s in
                        LDChip(title: s.label, selected: shape == s) {
                            editor.setClipMask(id: clip.id, shape: shape == s ? nil : s)
                            LumaHaptics.shared.tap()
                        }
                    }
                    if shape != nil {
                        LDChip(title: "Clear") {
                            editor.setClipMask(id: clip.id, shape: nil)
                            LumaHaptics.shared.tap()
                        }
                    }
                }

                if let shape {
                    LDCaption("EFFECT")
                    HStack(spacing: 8) {
                        ForEach(ClipMaskEffect.allCases, id: \.self) { e in
                            LDChip(title: e.label, selected: effect == e) {
                                editor.setClipMask(id: clip.id, shape: shape, effect: e)
                            }
                        }
                        LDChip(title: "Invert", selected: clip.maskInverted) {
                            editor.setClipMask(id: clip.id, shape: shape, inverted: !clip.maskInverted)
                        }
                    }

                    LDSlider(label: effect == .fill ? "Opacity" : "Strength",
                             value: Binding(get: { clip.maskAmount },
                                            set: { editor.setClipMask(id: clip.id, shape: shape, amount: $0) }),
                             range: 0...1)
                    LDSlider(label: "Size",
                             value: Binding(get: { clip.maskWidth },
                                            set: { editor.setClipMask(id: clip.id, shape: shape,
                                                                      size: CGSize(width: $0, height: $0)) }),
                             range: 0.05...1.0)
                    LDSlider(label: "Feather",
                             value: Binding(get: { clip.maskFeather },
                                            set: { editor.setClipMask(id: clip.id, shape: shape, feather: $0) }),
                             range: 0...0.3)
                    LDCaption("POSITION")
                    LDPositionPad(point: CGPoint(x: clip.maskCenterX, y: clip.maskCenterY)) { pt in
                        editor.setClipMask(id: clip.id, shape: shape, center: pt)
                    }
                } else {
                    Text("Pick a shape to blur, pixelate or block out part of the frame.")
                        .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
                }
            }
        }
    }
}

// MARK: - Stickers

private struct LDStickerPanel: View {
    @ObservedObject var editor: EditorState
    @State private var category = 0
    @State private var busy = false

    private var categories: [(name: String, emojis: [String])] { StickerBaker.emojiCategories }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                        LDChip(title: cat.name, selected: idx == category) { category = idx }
                    }
                }
                .padding(.trailing, 24)
            }
            .lumaEdgeFade(leading: 0, trailing: 16)

            if categories.indices.contains(category) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(categories[category].emojis, id: \.self) { emoji in
                        Button {
                            busy = true
                            Task {
                                let ok = await editor.addSticker(emoji: emoji)
                                busy = false
                                if ok { LumaHaptics.shared.tap() }
                            }
                        } label: {
                            Text(emoji).font(.system(size: 25))
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.lumaPress)
                        .disabled(busy)
                    }
                }
                .opacity(busy ? 0.5 : 1)
            }
        }
    }
}

// MARK: - Effects & particles

private struct LDEffectsPanel: View {
    @ObservedObject var editor: EditorState
    let particles: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption(particles ? "PARTICLES" : "EFFECT")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                if particles {
                    ForEach(ParticleKind.allCases, id: \.self) { kind in
                        tile(kind.label, kind.icon) {
                            editor.addParticleLayer(kind: kind); LumaHaptics.shared.tap()
                        }
                    }
                } else {
                    ForEach(EffectKind.allCases, id: \.self) { kind in
                        tile(kind.label, kind.icon) {
                            editor.addEffectLayer(kind: kind); LumaHaptics.shared.tap()
                        }
                    }
                }
            }

            if particles {
                ForEach(editor.particleLayers) { layer in
                    row(title: ParticleKind(rawValue: layer.kind)?.label ?? layer.kind,
                        offset: layer.timelineOffset,
                        intensity: Binding(get: { layer.intensity },
                                           set: { editor.setParticleIntensity(id: layer.id, $0) }),
                        remove: { editor.removeParticleLayer(id: layer.id) })
                }
            } else {
                ForEach(editor.effectLayers) { layer in
                    row(title: EffectKind(rawValue: layer.kind)?.label ?? layer.kind,
                        offset: layer.timelineOffset,
                        intensity: Binding(get: { layer.intensity },
                                           set: { editor.setEffectIntensity(id: layer.id, $0) }),
                        remove: { editor.removeEffectLayer(id: layer.id) })
                }
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17, weight: .light))
                Text(title).font(.system(size: 9.5)).lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    private func row(title: String, offset: Double,
                     intensity: Binding<Double>, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(.white)
                Spacer()
                TechReadout("AT \(LDFormat.secs(offset))", size: 9, color: LumaTheme.textMuted)
                Button(action: remove) {
                    Image(systemName: "trash").font(.system(size: 12, weight: .light))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .buttonStyle(.lumaPress)
            }
            LDSlider(label: "Strength", value: intensity, range: 0...1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Canvas / format

private struct LDCanvasPanel: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("FORMAT")
            HStack(spacing: 8) {
                ForEach(EditorFormat.allCases, id: \.self) { f in
                    LDChip(title: f.rawValue, selected: editor.format == f) {
                        editor.setFormat(f, zoom: editor.zoom); LumaHaptics.shared.tap()
                    }
                }
            }
            LDCaption("CANVAS")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CanvasBackgroundMode.allCases, id: \.self) { mode in
                    LDChip(title: mode.rawValue.capitalized, selected: editor.canvasMode == mode) {
                        editor.setCanvasMode(mode); LumaHaptics.shared.tap()
                    }
                }
            }
            LDSlider(label: "Canvas zoom",
                     value: Binding(get: { editor.zoom }, set: { editor.zoom = $0 }),
                     range: 50...200, readout: { "\(Int($0))%" })
            LDCaption("FRAME")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(FramePreset.allCases, id: \.self) { preset in
                    LDChip(title: preset.label, selected: editor.framePreset == preset.rawValue) {
                        editor.setFramePreset(preset); LumaHaptics.shared.tap()
                    }
                }
            }
        }
    }
}

// MARK: - Audio-reactive

private struct LDAudioReactivePanel: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("DRIVEN BY SOUND")
            HStack(spacing: 8) {
                LDChip(title: "Off", selected: editor.audioReactive == nil) {
                    editor.setAudioReactive(nil); LumaHaptics.shared.tap()
                }
                ForEach(AudioReactiveStyle.allCases, id: \.self) { style in
                    LDChip(title: style.label, selected: editor.audioReactive?.style == style) {
                        editor.setAudioReactive(.init(style: style,
                                                      strength: editor.audioReactive?.strength ?? 1.0,
                                                      sourceTrackID: editor.audioReactive?.sourceTrackID
                                                        ?? editor.audioTracks.first?.id))
                        LumaHaptics.shared.tap()
                    }
                }
            }
            if let config = editor.audioReactive {
                LDSlider(label: "Strength",
                         value: Binding(get: { config.strength },
                                        set: { editor.setAudioReactive(.init(style: config.style,
                                                                             strength: $0,
                                                                             sourceTrackID: config.sourceTrackID)) }),
                         range: 0...2)
                LDCaption("SOURCE LANE")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(editor.audioTracks) { track in
                            LDChip(title: track.title, selected: config.sourceTrackID == track.id) {
                                editor.setAudioReactive(.init(style: config.style,
                                                              strength: config.strength,
                                                              sourceTrackID: track.id))
                            }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .lumaEdgeFade(leading: 0, trailing: 16)
            }
        }
    }
}

// MARK: - Overlay panel

private struct LDOverlayPanel: View {
    @ObservedObject var editor: EditorState
    let overlayID: UUID?

    private enum Section: String, CaseIterable {
        case place = "Place", text = "Text", pip = "PIP", blend = "Blend"
        case chroma = "Chroma", mask = "Mask", adjust = "Adjust", border = "Border"
        case motion = "Motion", sound = "Sound"
    }

    @State private var section: Section = .place
    @State private var draftText = ""

    private static let swatches = ["#FFFFFF", "#000000", "#F5C518", "#FF5C5C", "#7A68EE", "#3EC8AC"]

    private var item: EditorState.OverlayItem? {
        guard let overlayID else { return nil }
        return editor.overlays.first { $0.id == overlayID }
    }

    private var sections: [Section] {
        guard let item else { return [] }
        var s: [Section] = [.place]
        if item.text != nil { s.append(.text) }
        if !item.isImage || item.text == nil { s.append(contentsOf: [.pip, .blend, .chroma, .mask, .adjust, .border]) }
        s.append(contentsOf: [.motion, .sound])
        return s
    }

    var body: some View {
        if let item, let id = overlayID {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sections, id: \.self) { s in
                            LDChip(title: s.rawValue, selected: section == s) { section = s }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .lumaEdgeFade(leading: 0, trailing: 16)

                switch section {
                case .place:  place(item, id)
                case .text:   text(item, id)
                case .pip:    pip(id)
                case .blend:  blend(item, id)
                case .chroma: chroma(item, id)
                case .mask:   mask(item, id)
                case .adjust: adjust(item, id)
                case .border: border(item, id)
                case .motion: motion(item, id)
                case .sound:  sound(item, id)
                }

                LDAction(title: "Remove overlay", icon: "trash") {
                    editor.removeOverlay(id: id)
                    LumaHaptics.shared.tap()
                }
            }
            .onAppear { draftText = item.text ?? "" }
        } else {
            Text("Select an overlay on the timeline.")
                .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
        }
    }

    // MARK: sections

    @ViewBuilder
    private func place(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDSlider(label: "Opacity",
                 value: Binding(get: { item.opacity * 100 },
                                set: { editor.setOverlayOpacity(id: id, $0 / 100) }),
                 range: 0...100, readout: { "\(Int($0))%" })
        LDSlider(label: "Size",
                 value: Binding(get: { item.sizeFraction * 100 },
                                set: { editor.setOverlaySize(id: id, $0 / 100) }),
                 range: 5...100, readout: { "\(Int($0))%" })
        LDSlider(label: "Rotation",
                 value: Binding(get: { item.rotationDegrees },
                                set: { editor.setOverlayRotation(id: id, $0) }),
                 range: -180...180, readout: { "\(Int($0))°" })
        LDCaption("POSITION")
        LDPositionPad(point: item.center) { editor.setOverlayCenter(id: id, $0) }
        LDCaption("ANCHORS")
        VStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { col in
                        let pt = CGPoint(x: 0.15 + Double(col) * 0.35, y: 0.15 + Double(row) * 0.35)
                        Button { editor.setOverlayCenter(id: id, pt); LumaHaptics.shared.tap() } label: {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(LumaTheme.surface)
                                .frame(height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
            }
        }
        LDCaption("STACKING · LAYER \(item.lane + 1)")
        HStack(spacing: 8) {
            LDChip(title: "Send back") { editor.nudgeOverlayLane(id: id, by: -1) }
            LDChip(title: "Bring forward") { editor.nudgeOverlayLane(id: id, by: 1) }
        }
        LDCaption("TRIM")
        HStack(spacing: 8) {
            LDChip(title: "Head −0.2s") { editor.trimOverlayHead(id: id, deltaSeconds: -0.2) }
            LDChip(title: "Head +0.2s") { editor.trimOverlayHead(id: id, deltaSeconds: 0.2) }
            LDChip(title: "Tail −0.2s") { editor.trimOverlayTail(id: id, deltaSeconds: -0.2) }
            LDChip(title: "Tail +0.2s") { editor.trimOverlayTail(id: id, deltaSeconds: 0.2) }
        }
    }

    @ViewBuilder
    private func text(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("CONTENT")
        TextField("", text: $draftText, axis: .vertical)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .tint(.white)
            .lineLimit(1...3)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onSubmit { editor.setOverlayText(id: id, draftText) }
            .onChange(of: draftText) { _, new in editor.setOverlayText(id: id, new) }

        LDCaption("STYLE")
        HStack(spacing: 8) {
            ForEach(EditorState.TextLayerStyle.allCases, id: \.self) { style in
                LDChip(title: style.label, selected: item.textStyle == style) {
                    editor.setOverlayTextStyle(id: id, style)
                }
            }
        }

        LDCaption("COLOUR")
        HStack(spacing: 9) {
            ForEach(Self.swatches, id: \.self) { hex in
                Button { editor.setOverlayTextColor(id: id, hex) } label: {
                    Circle().fill(Color(hex: hex))
                        .frame(width: 26, height: 26)
                        .overlay {
                            if item.textColorHex.uppercased() == hex.uppercased() {
                                Circle().strokeBorder(Color.white, lineWidth: 2)
                            } else {
                                Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.lumaPress)
            }
        }

        LDCaption("ALIGN")
        HStack(spacing: 8) {
            ForEach(["left", "center", "right"], id: \.self) { align in
                LDChip(title: align.capitalized, selected: item.textAlignment == align) {
                    editor.setTextDecor(id: id, alignment: align)
                }
            }
        }

        LDCaption("FONT")
        Menu {
            Button("Preset font") { editor.setTextDecor(id: id, fontName: .some(nil)) }
            ForEach(FontLibrary.builtInFontNames, id: \.self) { name in
                Button(name) { editor.setTextDecor(id: id, fontName: .some(name)) }
            }
        } label: {
            HStack {
                Text(item.textFontName ?? "Preset font")
                    .font(.system(size: 12.5)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        LDCaption("DECOR")
        HStack(spacing: 8) {
            LDChip(title: "Outline", selected: item.textStrokeHex != nil) {
                editor.setTextDecor(id: id,
                                    strokeHex: item.textStrokeHex == nil ? .some("#000000") : .some(nil),
                                    strokeWidth: item.textStrokeHex == nil ? 2 : 0)
            }
            LDChip(title: "Box", selected: item.textBoxHex != nil) {
                editor.setTextDecor(id: id, boxHex: item.textBoxHex == nil ? .some("#000000") : .some(nil))
            }
        }
        if item.textStrokeHex != nil {
            LDSlider(label: "Outline width",
                     value: Binding(get: { item.textStrokeWidth },
                                    set: { editor.setTextDecor(id: id, strokeWidth: $0) }),
                     range: 0...12, readout: { String(format: "%.1f", $0) })
        }

        LDCaption("ANIMATION")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(TextAnimation.allCases, id: \.self) { preset in
                LDChip(title: preset.label, selected: item.textAnimation == preset.rawValue) {
                    editor.setTextAnimation(id: id, preset)
                }
            }
        }
    }

    @ViewBuilder
    private func pip(_ id: UUID) -> some View {
        LDCaption("PIP LAYOUT")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(PipPreset.all) { preset in
                Button {
                    editor.applyPipPreset(id: id, preset); LumaHaptics.shared.tap()
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: preset.icon).font(.system(size: 16, weight: .light))
                        Text(preset.name).font(.system(size: 9.5)).lineLimit(1)
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.lumaPress)
            }
        }
    }

    @ViewBuilder
    private func blend(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("BLEND")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(OverlayBlendMode.allCases, id: \.self) { mode in
                LDChip(title: mode.label, selected: item.effects.blendMode == mode) {
                    editor.setOverlayBlendMode(id: id, mode)
                }
            }
        }
    }

    @ViewBuilder
    private func chroma(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        let chroma = item.effects.chroma
        LDCaption("GREEN SCREEN")
        LDChip(title: chroma == nil ? "Off" : "On", selected: chroma != nil) {
            editor.setOverlayChroma(id: id, chroma == nil ? ChromaKeySettings() : nil)
        }
        if let chroma {
            LDCaption("KEY COLOUR")
            HStack(spacing: 9) {
                ForEach(["#00FF00", "#0000FF", "#00FFFF", "#FF00FF"], id: \.self) { hex in
                    Button {
                        var c = chroma; c.colorHex = hex
                        editor.setOverlayChroma(id: id, c)
                    } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 26, height: 26)
                            .overlay {
                                if chroma.colorHex.uppercased() == hex {
                                    Circle().strokeBorder(Color.white, lineWidth: 2)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            LDSlider(label: "Tolerance",
                     value: Binding(get: { chroma.tolerance * 100 },
                                    set: { var c = chroma; c.tolerance = $0 / 100
                                           editor.setOverlayChroma(id: id, c, snapshot: false) }),
                     range: 5...80, readout: { "\(Int($0))" })
            LDSlider(label: "Softness",
                     value: Binding(get: { chroma.softness * 100 },
                                    set: { var c = chroma; c.softness = $0 / 100
                                           editor.setOverlayChroma(id: id, c, snapshot: false) }),
                     range: 0...40, readout: { "\(Int($0))" })
        }
    }

    @ViewBuilder
    private func mask(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("OVERLAY MASK")
        let m = item.effects.mask
        HStack(spacing: 8) {
            ForEach([("none", "None"), ("rect", "Rect"), ("roundedRect", "Rounded"),
                     ("ellipse", "Circle"), ("linear", "Fade")], id: \.0) { pair in
                LDChip(title: pair.1,
                       selected: pair.0 == "none" ? m == nil : m?.shape == pair.0) {
                    if pair.0 == "none" { editor.setOverlayMask(id: id, nil) }
                    else {
                        var s = m ?? OverlayMaskSettings()
                        s.shape = pair.0
                        editor.setOverlayMask(id: id, s)
                    }
                }
            }
        }
        if let m {
            LDSlider(label: "Feather",
                     value: Binding(get: { m.feather * 100 },
                                    set: { var s = m; s.feather = $0 / 100
                                           editor.setOverlayMask(id: id, s, snapshot: false) }),
                     range: 0...40, readout: { "\(Int($0))" })
            LDChip(title: "Invert", selected: m.invert) {
                var s = m; s.invert.toggle(); editor.setOverlayMask(id: id, s)
            }
        }
    }

    @ViewBuilder
    private func adjust(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        let a = item.effects.adjust ?? OverlayAdjustments()
        LDCaption("ADJUST")
        LDSlider(label: "Exposure",
                 value: Binding(get: { a.exposure * 100 },
                                set: { var v = a; v.exposure = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        LDSlider(label: "Contrast",
                 value: Binding(get: { a.contrast * 100 },
                                set: { var v = a; v.contrast = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        LDSlider(label: "Saturation",
                 value: Binding(get: { a.saturation * 100 },
                                set: { var v = a; v.saturation = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        LDSlider(label: "Warmth",
                 value: Binding(get: { a.warmth * 100 },
                                set: { var v = a; v.warmth = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        if !a.isIdentity {
            LDAction(title: "Reset adjustments", icon: "arrow.counterclockwise") {
                editor.setOverlayAdjustments(id: id, nil)
            }
        }
    }

    @ViewBuilder
    private func border(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("BORDER")
        let b = item.effects.border
        LDChip(title: b == nil ? "Off" : "On", selected: b != nil) {
            editor.setOverlayBorder(id: id, b == nil ? OverlayBorderSettings() : nil)
        }
        if let b {
            HStack(spacing: 9) {
                ForEach(["#FFFFFF", "#000000", "#F5C518", "#FF5C5C", "#7A68EE"], id: \.self) { hex in
                    Button {
                        var v = b; v.colorHex = hex; editor.setOverlayBorder(id: id, v)
                    } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay {
                                if b.colorHex.uppercased() == hex {
                                    Circle().strokeBorder(Color.white, lineWidth: 2)
                                } else {
                                    Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            LDSlider(label: "Width",
                     value: Binding(get: { b.widthFraction * 100 },
                                    set: { var v = b; v.widthFraction = $0 / 100
                                           editor.setOverlayBorder(id: id, v, snapshot: false) }),
                     range: 1...12, readout: { String(format: "%.1f", $0) })
            LDSlider(label: "Corner",
                     value: Binding(get: { b.cornerRadiusFraction * 100 },
                                    set: { var v = b; v.cornerRadiusFraction = $0 / 100
                                           editor.setOverlayBorder(id: id, v, snapshot: false) }),
                     range: 0...50, readout: { "\(Int($0))" })
        }
    }

    @ViewBuilder
    private func motion(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("KEYFRAMES · \(item.keyframes.count) PINNED")
        LDAction(title: "Pin this placement at the playhead", icon: "diamond") {
            editor.addOverlayKeyframe(id: id); LumaHaptics.shared.tap()
        }
        if !item.keyframes.isEmpty {
            LDAction(title: "Clear keyframes", icon: "trash") {
                editor.clearOverlayKeyframes(id: id)
            }
        }
        Text("Move the overlay, pin it, move it again — the pins animate between placements.")
            .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
    }

    @ViewBuilder
    private func sound(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("OVERLAY SOUND")
        LDSlider(label: "Volume",
                 value: Binding(get: { item.volume },
                                set: { editor.setOverlayVolume(id: id, $0) }),
                 range: 0...200, readout: { "\(Int($0))%" })
        LDChip(title: item.isMuted ? "Unmute" : "Mute", selected: item.isMuted) {
            editor.setOverlayMuted(id: id, !item.isMuted)
        }
    }
}

// MARK: - Music / audio lane panel

private struct LDMusicPanel: View {
    @ObservedObject var editor: EditorState
    let trackID: UUID?

    private enum Section: String, CaseIterable {
        case level = "Level", fade = "Fade", envelope = "Envelope"
        case effects = "Effects", beats = "Beats", lane = "Lane"
    }

    @State private var section: Section = .level

    private var track: EditorState.MusicTrack? {
        guard let trackID else { return editor.audioTracks.first }
        return editor.audioTracks.first { $0.id == trackID }
    }

    var body: some View {
        if let track {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Section.allCases, id: \.self) { s in
                            LDChip(title: s.rawValue, selected: section == s) { section = s }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .lumaEdgeFade(leading: 0, trailing: 16)

                switch section {
                case .level:    level(track)
                case .fade:     fade(track)
                case .envelope: LDEnvelopeEditor(editor: editor, track: track)
                case .effects:  LDAudioEffects(editor: editor, track: track)
                case .beats:    beats(track)
                case .lane:     lane(track)
                }
            }
        } else {
            Text("No audio lanes yet. Add music, an effect or a voiceover.")
                .font(.system(size: 12)).foregroundStyle(LumaTheme.textMuted)
        }
    }

    @ViewBuilder
    private func level(_ track: EditorState.MusicTrack) -> some View {
        LDCaption("\(track.title.uppercased()) · \(LDFormat.secs(track.timelineDuration))")
        LDWaveform(samples: track.waveform).frame(height: 34)
        LDSlider(label: "Volume",
                 value: Binding(get: { track.volume },
                                set: { editor.setMusicVolume(id: track.id, $0) }),
                 range: 0...200, readout: { "\(Int($0))%" })
        HStack(spacing: 8) {
            LDChip(title: track.isMuted ? "Unmute" : "Mute", selected: track.isMuted) {
                editor.setMusicMuted(id: track.id, !track.isMuted)
            }
            LDChip(title: "Duck under voice", selected: track.duckingEnabled) {
                editor.setMusicDucking(id: track.id, !track.duckingEnabled)
            }
            LDChip(title: "Loop", selected: track.isLooping) {
                editor.setMusicLooping(id: track.id, !track.isLooping)
            }
        }
        LDAction(title: "Remove this lane", icon: "trash") {
            editor.removeAudioTrack(id: track.id)
        }
    }

    @ViewBuilder
    private func fade(_ track: EditorState.MusicTrack) -> some View {
        LDSlider(label: "Fade in",
                 value: Binding(get: { track.fadeIn },
                                set: { editor.setMusicFade(id: track.id, fadeIn: $0) }),
                 range: 0...5, readout: { LDFormat.secs($0) })
        LDSlider(label: "Fade out",
                 value: Binding(get: { track.fadeOut },
                                set: { editor.setMusicFade(id: track.id, fadeOut: $0) }),
                 range: 0...5, readout: { LDFormat.secs($0) })
        LDCaption("CURVE")
        HStack(spacing: 8) {
            ForEach(FadeCurve.allCases, id: \.self) { curve in
                LDChip(title: curve.label, selected: track.fadeCurve == curve) {
                    editor.setMusicFade(id: track.id, curve: curve)
                }
            }
        }
        LDCaption("EDGE TRIM")
        HStack(spacing: 8) {
            LDChip(title: "Head −0.5s") { editor.trimMusicHead(id: track.id, deltaSeconds: -0.5) }
            LDChip(title: "Head +0.5s") { editor.trimMusicHead(id: track.id, deltaSeconds: 0.5) }
            LDChip(title: "Tail −0.5s") { editor.trimMusicTail(id: track.id, deltaSeconds: -0.5) }
            LDChip(title: "Tail +0.5s") { editor.trimMusicTail(id: track.id, deltaSeconds: 0.5) }
        }
    }

    @ViewBuilder
    private func beats(_ track: EditorState.MusicTrack) -> some View {
        LDAction(title: editor.isDetectingBeats ? "Detecting…" : "Detect beats",
                 icon: "metronome", busy: editor.isDetectingBeats) {
            Task { await editor.detectBeats(trackID: track.id) }
        }
        LDAction(title: "Auto-cut clips to the beat", icon: "scissors",
                 enabled: !track.beatMarkers.isEmpty) {
            Task { await editor.autoCutToBeats(trackID: track.id) }
        }
        TechReadout(track.beatMarkers.isEmpty ? "NO BEATS DETECTED"
                    : "\(track.beatMarkers.count) BEATS ON THE LANE",
                    size: 9, color: LumaTheme.textMuted)
    }

    @ViewBuilder
    private func lane(_ track: EditorState.MusicTrack) -> some View {
        LDCaption("LANE KIND")
        HStack(spacing: 8) {
            ForEach(AudioLaneKind.allCases, id: \.self) { kind in
                LDChip(title: kind.label, selected: track.kind == kind) {
                    editor.setAudioKind(id: track.id, kind)
                }
            }
        }
        LDCaption("OFFSET")
        LDSlider(label: "Start at",
                 value: Binding(get: { track.timelineOffset },
                                set: { editor.setMusicOffset(id: track.id, $0) }),
                 range: 0...max(0.1, editor.totalDuration),
                 readout: { LDFormat.secs($0) })
    }
}

// MARK: - Volume envelope

private struct LDEnvelopeEditor: View {
    @ObservedObject var editor: EditorState
    let track: EditorState.MusicTrack

    private var points: [AudioVolumePoint] {
        track.volumePoints.isEmpty
            ? [AudioVolumePoint(time: 0, volume: 1),
               AudioVolumePoint(time: max(0.1, track.timelineDuration), volume: 1)]
            : track.volumePoints.sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LDCaption("VOLUME OVER TIME")
            GeometryReader { geo in
                let dur = max(0.1, track.timelineDuration)
                let w = max(1, geo.size.width)
                let h = max(1, geo.size.height)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LumaTheme.surface)
                    ForEach(1..<3, id: \.self) { i in
                        Rectangle().fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                            .offset(y: h * CGFloat(i) / 3)
                    }
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let x = CGFloat(pt.time / dur) * w
                            let y = h * (1 - CGFloat(pt.volume))
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    ForEach(Array(points.enumerated()), id: \.offset) { idx, pt in
                        Circle().fill(Color.white).frame(width: 13, height: 13)
                            .position(x: CGFloat(pt.time / dur) * w, y: h * (1 - CGFloat(pt.volume)))
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { g in
                                    var next = points
                                    guard next.indices.contains(idx) else { return }
                                    next[idx].time = min(max(0, Double(g.location.x / w) * dur), dur)
                                    next[idx].volume = min(max(0, 1 - Double(g.location.y / h)), 1)
                                    editor.setMusicEnvelope(id: track.id, next.sorted { $0.time < $1.time })
                                }
                            )
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture { location in
                    var next = points
                    next.append(AudioVolumePoint(time: min(max(0, Double(location.x / w) * dur), dur),
                                                 volume: min(max(0, 1 - Double(location.y / h)), 1)))
                    editor.setMusicEnvelope(id: track.id, next.sorted { $0.time < $1.time })
                    LumaHaptics.shared.tap()
                }
            }
            .frame(height: 130)
            HStack(spacing: 8) {
                LDChip(title: "Clear") { editor.setMusicEnvelope(id: track.id, []) }
                Text("Tap to add a point · drag to shape")
                    .font(.system(size: 11.5)).foregroundStyle(LumaTheme.textMuted)
            }
        }
    }
}

// MARK: - Audio effects

private struct LDAudioEffects: View {
    @ObservedObject var editor: EditorState
    let track: EditorState.MusicTrack

    private static let eqPresets: [(String, [Double])] = [
        ("Flat", [0, 0, 0, 0, 0]), ("Bass Boost", [8, 4, 0, 0, 0]),
        ("Treble", [0, 0, 0, 4, 8]), ("Voice", [-2, 0, 3, 5, 2]),
        ("Podcast", [-4, -2, 2, 4, 1]), ("Warm", [4, 2, 0, -2, -4]),
        ("De-Rumble", [-12, -4, 0, 0, 0])
    ]
    private static let bandLabels = ["80", "250", "1k", "3.5k", "10k"]

    private var fx: AudioEffectSettings { track.effects }

    private func commit(_ s: AudioEffectSettings) {
        Task { await editor.applyTrackEffects(id: track.id, s) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editor.isRenderingEffects {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.white)
                    TechReadout("BAKING", size: 9, color: LumaTheme.textMuted)
                }
            }

            LDCaption("EQ")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.eqPresets, id: \.0) { name, gains in
                        LDChip(title: name, selected: fx.eqPresetName == name) {
                            var s = fx; s.eqBandGains = gains; s.eqPresetName = name
                            commit(s)
                        }
                    }
                }
                .padding(.trailing, 24)
            }
            .lumaEdgeFade(leading: 0, trailing: 16)

            ForEach(0..<5, id: \.self) { band in
                LDSlider(label: "\(Self.bandLabels[band]) Hz",
                         value: Binding(
                            get: { (fx.eqBandGains?.count == 5 ? fx.eqBandGains![band] : 0) },
                            set: { v in
                                var gains = fx.eqBandGains?.count == 5 ? fx.eqBandGains! : [0, 0, 0, 0, 0]
                                gains[band] = v
                                var s = fx; s.eqBandGains = gains; s.eqPresetName = nil
                                commit(s)
                            }),
                         range: -12...12, readout: { String(format: "%+.0f dB", $0) })
            }

            LDSlider(label: "Pitch",
                     value: Binding(get: { fx.pitchSemitones },
                                    set: { var s = fx; s.pitchSemitones = $0.rounded(); s.voiceEffect = nil; commit(s) }),
                     range: -12...12, readout: { String(format: "%+.0f st", $0) })

            LDCaption("VOICE")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(VoiceEffect.allCases, id: \.self) { effect in
                    LDChip(title: effect.label,
                           selected: effect == .none ? fx.voiceEffect == nil : fx.voiceEffect == effect.rawValue) {
                        var s = fx
                        s.voiceEffect = effect == .none ? nil : effect.rawValue
                        commit(s)
                    }
                }
            }

            LDCaption("REVERB")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ReverbPreset.allCases, id: \.self) { preset in
                    LDChip(title: preset.label,
                           selected: preset == .none ? fx.reverbPreset == nil : fx.reverbPreset == preset.rawValue) {
                        var s = fx
                        s.reverbPreset = preset == .none ? nil : preset.rawValue
                        commit(s)
                    }
                }
            }
            if fx.reverbPreset != nil {
                LDSlider(label: "Wet",
                         value: Binding(get: { fx.reverbMix },
                                        set: { var s = fx; s.reverbMix = $0; commit(s) }),
                         range: 0...100, readout: { "\(Int($0))%" })
            }

            LDCaption("LOUDNESS")
            LDAction(title: "Normalize to −14 LUFS", icon: "waveform.path.ecg") {
                Task { await editor.normalizeTrack(id: track.id) }
            }
            if abs(fx.gainDB) > 0.05 {
                TechReadout(String(format: "GAIN %+.1f DB", fx.gainDB), size: 9, color: LumaTheme.textMuted)
            }
            LDAction(title: "Reset all effects", icon: "arrow.counterclockwise") {
                commit(AudioEffectSettings())
            }
        }
    }
}
