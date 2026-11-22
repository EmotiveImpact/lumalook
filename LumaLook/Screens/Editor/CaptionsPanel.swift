import SwiftUI
import UIKit

// MARK: - Languages

/// A language the Captions panel offers, by BCP-47 identifier.
struct CaptionLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

/// The panel's language list: a short, plain-named list filtered to what the
/// speech recogniser supports here, plus the phone's own language if missing.
enum CaptionLanguages {
    private static let curated: [CaptionLanguage] = [
        CaptionLanguage(id: "en-GB", name: "English (UK)"),
        CaptionLanguage(id: "en-US", name: "English (US)"),
        CaptionLanguage(id: "en-AU", name: "English (Australia)"),
        CaptionLanguage(id: "en-IN", name: "English (India)"),
        CaptionLanguage(id: "fr-FR", name: "French"),
        CaptionLanguage(id: "es-ES", name: "Spanish (Spain)"),
        CaptionLanguage(id: "es-MX", name: "Spanish (Mexico)"),
        CaptionLanguage(id: "de-DE", name: "German"),
        CaptionLanguage(id: "it-IT", name: "Italian"),
        CaptionLanguage(id: "pt-BR", name: "Portuguese (Brazil)"),
        CaptionLanguage(id: "pt-PT", name: "Portuguese (Portugal)"),
        CaptionLanguage(id: "nl-NL", name: "Dutch"),
        CaptionLanguage(id: "sv-SE", name: "Swedish"),
        CaptionLanguage(id: "pl-PL", name: "Polish"),
        CaptionLanguage(id: "tr-TR", name: "Turkish"),
        CaptionLanguage(id: "ru-RU", name: "Russian"),
        CaptionLanguage(id: "ar-SA", name: "Arabic"),
        CaptionLanguage(id: "hi-IN", name: "Hindi"),
        CaptionLanguage(id: "ja-JP", name: "Japanese"),
        CaptionLanguage(id: "ko-KR", name: "Korean"),
        CaptionLanguage(id: "zh-CN", name: "Chinese (Mandarin)"),
    ]

    static let all: [CaptionLanguage] = {
        let supported = CaptionEngine.recognizerLocaleKeys()
        var list = CaptionLanguages.curated.filter {
            supported.isEmpty || supported.contains(CaptionEngine.localeKey($0.id))
        }
        let device = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let deviceKey = CaptionEngine.localeKey(device)
        if supported.contains(deviceKey), !list.contains(where: { CaptionEngine.localeKey($0.id) == deviceKey }) {
            let name = Locale.current.localizedString(forIdentifier: device) ?? device
            list.insert(CaptionLanguage(id: device, name: name), at: 0)
        }
        return list.isEmpty ? [CaptionLanguage(id: "en-GB", name: "English (UK)")] : list
    }()

    /// The stored choice, or the phone's language, or English (UK).
    static func resolvedID(_ stored: String) -> String {
        if !stored.isEmpty, all.contains(where: { $0.id == stored }) { return stored }
        let deviceKey = CaptionEngine.localeKey(Locale.current.identifier)
        if let match = all.first(where: { CaptionEngine.localeKey($0.id) == deviceKey }) { return match.id }
        let language = deviceKey.split(separator: "-").first.map(String.init) ?? deviceKey
        if let match = all.first(where: { CaptionEngine.localeKey($0.id).hasPrefix(language + "-") }) {
            return match.id
        }
        return all.first(where: { $0.id == "en-GB" })?.id ?? all[0].id
    }

    static func name(for id: String) -> String {
        all.first(where: { $0.id == id })?.name ?? id
    }
}

// MARK: - Job state

/// Why the last run made no captions, in words the panel can show.
enum CaptionFailure: Equatable {
    case permission
    case noSpeech
    case noAudio
    case language
    case other(String)

    init(_ error: Error) {
        if let engine = error as? CaptionEngineError {
            switch engine {
            case .notAuthorized:         self = .permission
            case .noSpeech:              self = .noSpeech
            case .noAudio:               self = .noAudio
            case .recognizerUnavailable: self = .language
            case .failed:                self = .other("Speech recognition stopped before it finished.")
            }
        } else if error is CancellationError {
            self = .other("Transcribing was stopped.")
        } else {
            self = .other(error.localizedDescription)
        }
    }

    var icon: String {
        switch self {
        case .permission: return "lock"
        case .noSpeech:   return "waveform.slash"
        case .noAudio:    return "speaker.slash"
        case .language:   return "globe"
        case .other:      return "exclamationmark.circle"
        }
    }

    var title: String {
        switch self {
        case .permission: return "Speech recognition is off"
        case .noSpeech:   return "No speech found"
        case .noAudio:    return "No sound to listen to"
        case .language:   return "Language not available"
        case .other:      return "Couldn't make captions"
        }
    }

    func message(language: String) -> String {
        switch self {
        case .permission:
            return "LumaLook needs speech recognition to hear your video. Turn it on in Settings, then try again."
        case .noSpeech:
            return "Check the clips' sound is on, or pick the language people speak in."
        case .noAudio:
            return "This edit has no audio. Add a clip with sound, or unmute your clips."
        case .language:
            return "\(language) can't be transcribed right now. Try another language, or connect to the internet."
        case .other(let detail):
            return detail
        }
    }
}

/// Progress and outcome of a transcription, kept in a class so the progress
/// callback (which arrives off the main actor) has one stable place to land.
@MainActor
final class CaptionJob: ObservableObject {
    @Published var progress: CaptionProgress?
    @Published var failure: CaptionFailure?
    @Published var lastRunOnDevice: Bool?
    @Published var privacy: CaptionPrivacy?
}

// MARK: - Panel

/// The editor's Captions tool: generate karaoke captions from the edit's own
/// speech, pick a style, place them, and fix any line by tapping it.
struct CaptionsPanel: View {
    @ObservedObject var editor: EditorState
    @Binding var isCaptioning: Bool
    @EnvironmentObject private var app: AppModel

    @AppStorage("luma.captions.language") private var storedLanguage: String = ""
    @AppStorage("luma.captions.style") private var preferredStyle: String = CaptionStyle.karaoke.rawValue

    @StateObject private var job = CaptionJob()
    @State private var editingID: UUID?
    @State private var draftText: String = ""
    @State private var srtURL: URL?
    @FocusState private var fieldFocused: Bool

    private var languageID: String { CaptionLanguages.resolvedID(storedLanguage) }
    private var languageName: String { CaptionLanguages.name(for: languageID) }
    private var lines: [EditorState.OverlayItem] { editor.captionLines }

    private var currentStyle: CaptionStyle {
        if let raw = lines.first?.captionStyle, let style = CaptionStyle(rawValue: raw) { return style }
        return CaptionStyle(rawValue: preferredStyle) ?? .karaoke
    }

    private var currentPosition: CaptionPosition {
        guard let first = lines.first else { return .lower }
        return CaptionPosition.nearest(to: Double(first.center.y))
    }

    private var currentSize: CaptionSize {
        guard let first = lines.first else { return .medium }
        return CaptionSize.nearest(to: first.sizeFraction, aspect: editor.format.aspect)
    }

    private var isBurnedIn: Bool { !(lines.first?.captionHidden ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if isCaptioning {
                progressCard
            } else if let failure = job.failure {
                failureCard(failure)
            }
            if lines.isEmpty {
                if !isCaptioning { emptyState }
            } else {
                styleRow
                placementRow
                lineList
                burnRow
                actionRow
                removeAllButton
            }
        }
        .task(id: languageID) {
            job.privacy = nil
            job.privacy = await CaptionEngine.privacy(for: Locale(identifier: languageID))
        }
        .onAppear { refreshSRTFile() }
        .onChange(of: srtSignature) { _, _ in refreshSRTFile() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Captions")
                .font(.luma(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.textPrimary)
            Spacer(minLength: 8)
            languageMenu
            if !lines.isEmpty {
                Text("· \(lines.count) \(lines.count == 1 ? "line" : "lines")")
                    .font(.luma(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(CaptionLanguages.all) { language in
                Button {
                    storedLanguage = language.id
                    LumaHaptics.shared.tap()
                } label: {
                    if language.id == languageID {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(languageName)
                    .font(.luma(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .disabled(isCaptioning)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn the speech in your edit into big captions that light up word by word.")
                .font(.luma(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SolidCTA(title: "Generate captions", icon: "captions.bubble", height: 46) {
                generate()
            }
            privacyNote
        }
    }

    @ViewBuilder
    private var privacyNote: some View {
        if let privacy = job.privacy {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: privacyIcon(privacy))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.top, 1)
                Text(privacyText(privacy))
                    .font(.luma(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(LumaTheme.textMuted)
        }
    }

    private func privacyIcon(_ privacy: CaptionPrivacy) -> String {
        switch privacy {
        case .onDevice:    return "iphone"
        case .server:      return "icloud"
        case .unavailable: return "exclamationmark.circle"
        }
    }

    private func privacyText(_ privacy: CaptionPrivacy) -> String {
        switch privacy {
        case .onDevice:
            return "Runs on this iPhone. Your audio stays here."
        case .server:
            return "\(languageName) isn't available on this iPhone, so the sound is sent to Apple to transcribe."
        case .unavailable:
            return "\(languageName) can't be transcribed on this iPhone. Pick another language."
        }
    }

    // MARK: Progress and errors

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(LumaTheme.signal)
                Text(progressTitle)
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.textPrimary)
                Spacer(minLength: 4)
                if let fraction = progressFraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.luma(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(LumaTheme.textSecondary)
                }
            }
            if let fraction = progressFraction {
                ProgressView(value: fraction)
                    .tint(LumaTheme.signal)
            }
            Text(progressDetail)
                .font(.luma(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(LumaTheme.hairline, lineWidth: 1))
    }

    private var progressTitle: String {
        switch job.progress {
        case .preparingAudio?:   return "Getting the sound ready"
        case .downloadingModel?: return "Downloading the speech model"
        case .listening?:        return "Listening"
        case nil:                return "Transcribing"
        }
    }

    private var progressFraction: Double? {
        if case .listening(let fraction)? = job.progress, let fraction, fraction > 0 { return fraction }
        return nil
    }

    private var progressDetail: String {
        switch job.progress {
        case .downloadingModel?:
            return "Only the first time for \(languageName). It stays on your iPhone after."
        default:
            switch job.privacy {
            case .onDevice?: return "\(languageName) · on this iPhone"
            case .server?:   return "\(languageName) · sent to Apple to transcribe"
            default:         return languageName
            }
        }
    }

    private func failureCard(_ failure: CaptionFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: failure.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.luma(size: 14, weight: .semibold))
                        .foregroundStyle(LumaTheme.textPrimary)
                    Text(failure.message(language: languageName))
                        .font(.luma(size: 12.5))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // With no captions yet, the Generate button below is the retry.
            if failure == .permission || !lines.isEmpty {
                HStack(spacing: 8) {
                    if failure == .permission {
                        smallButton("Open Settings", icon: "gear", emphasised: true) { openSettings() }
                    }
                    if !lines.isEmpty {
                        smallButton("Try again", icon: "arrow.clockwise", emphasised: false) { generate() }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(LumaTheme.hairline, lineWidth: 1))
    }

    // MARK: Style, position, size

    private var styleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CaptionStyle.allCases) { style in
                    CaptionStyleTile(style: style, isOn: style == currentStyle) {
                        preferredStyle = style.rawValue
                        editor.setCaptionStyle(style)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            .padding(.trailing, 20)
        }
        .lumaEdgeFade(leading: 0, trailing: 20)
    }

    private var placementRow: some View {
        HStack(spacing: 8) {
            CaptionSegmented(labels: CaptionPosition.allCases.map(\.label),
                             selected: CaptionPosition.allCases.firstIndex(of: currentPosition)) { index in
                editor.setCaptionPlacement(position: CaptionPosition.allCases[index])
                LumaHaptics.shared.tap()
            }
            CaptionSegmented(labels: CaptionSize.allCases.map(\.label),
                             selected: CaptionSize.allCases.firstIndex(of: currentSize)) { index in
                editor.setCaptionPlacement(size: CaptionSize.allCases[index])
                LumaHaptics.shared.tap()
            }
            .frame(width: 104)
        }
    }

    // MARK: Lines

    private var lineList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                if line.id == editingID {
                    lineEditor(line)
                } else {
                    lineRow(line)
                }
            }
        }
    }

    private func isLive(_ line: EditorState.OverlayItem) -> Bool {
        editor.currentTime >= line.timelineOffset && editor.currentTime < line.timelineEnd
    }

    private func lineRow(_ line: EditorState.OverlayItem) -> some View {
        let live = isLive(line)
        return Button {
            beginEditing(line)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.timecode(line.timelineOffset))
                    .font(.luma(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LumaTheme.textMuted)
                    .frame(width: 44, alignment: .leading)
                rowText(line, live: live)
                    .font(.luma(size: 13.5, weight: .medium))
                    .foregroundStyle(live ? LumaTheme.textPrimary : LumaTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if live {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(LumaTheme.border, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The line's words, with the word being spoken in signal yellow while
    /// the playhead is inside the line.
    private func rowText(_ line: EditorState.OverlayItem, live: Bool) -> Text {
        let text = line.text ?? ""
        guard live else { return Text(text) }
        let ns = text as NSString
        let tokens = TextRasterizer.captionTokens(text).map { ns.substring(with: $0) }
        guard !tokens.isEmpty else { return Text(text) }
        let state = TextAnimator.captionState(style: .karaoke,
                                              words: line.captionWords,
                                              tokenCount: tokens.count,
                                              localTime: editor.currentTime - line.timelineOffset,
                                              duration: line.duration)
        var out = Text("")
        for (i, token) in tokens.enumerated() {
            if i > 0 { out = out + Text(" ") }
            if i == state.active {
                out = out + Text(token).foregroundColor(LumaTheme.signal)
            } else {
                out = out + Text(token)
            }
        }
        return out
    }

    private func lineEditor(_ line: EditorState.OverlayItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Caption", text: $draftText)
                .font(.luma(size: 15, weight: .medium))
                .foregroundStyle(LumaTheme.textPrimary)
                .tint(LumaTheme.signal)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit { commitText(line) }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(LumaTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaTheme.border, lineWidth: 1))
            HStack(spacing: 8) {
                timeNudger("Start", value: line.timelineOffset) { newStart in
                    editor.updateCaptionLine(id: line.id, text: line.text ?? "",
                                             start: newStart,
                                             duration: line.timelineEnd - newStart)
                    editor.seek(to: max(0, newStart + 0.02))
                }
                timeNudger("End", value: line.timelineEnd) { newEnd in
                    editor.updateCaptionLine(id: line.id, text: line.text ?? "",
                                             start: line.timelineOffset,
                                             duration: newEnd - line.timelineOffset)
                }
            }
            HStack(spacing: 8) {
                Button {
                    editingID = nil
                    fieldFocused = false
                    editor.removeOverlay(id: line.id)
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Delete line", systemImage: "trash")
                        .font(.luma(size: 12.5, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                Spacer(minLength: 4)
                Button {
                    commitText(line)
                } label: {
                    Text("Done")
                        .font(.luma(size: 13, weight: .semibold))
                        .foregroundStyle(LumaTheme.onLight)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(LumaTheme.textPrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(LumaTheme.border, lineWidth: 1))
    }

    private func timeNudger(_ label: String, value: Double,
                            onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.luma(size: 11, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.leading, 10)
            Spacer(minLength: 2)
            Button {
                onChange(value - 0.1)
                LumaHaptics.shared.tap()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Text(Self.timecode(value))
                .font(.luma(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(LumaTheme.textPrimary)
                .frame(minWidth: 42)
            Button {
                onChange(value + 0.1)
                LumaHaptics.shared.tap()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
        .foregroundStyle(LumaTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func beginEditing(_ line: EditorState.OverlayItem) {
        if let current = editingID, current != line.id,
           let open = lines.first(where: { $0.id == current }) {
            commitText(open, close: false)
        }
        draftText = line.text ?? ""
        editingID = line.id
        editor.seek(to: line.timelineOffset + 0.02)
        LumaHaptics.shared.tap()
    }

    private func commitText(_ line: EditorState.OverlayItem, close: Bool = true) {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != line.text {
            editor.updateCaptionLine(id: line.id, text: text,
                                     start: line.timelineOffset, duration: line.duration)
        }
        if close {
            editingID = nil
            fieldFocused = false
        }
    }

    // MARK: Burn-in, SRT, regenerate

    private var burnRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isBurnedIn },
                                 set: { on in editor.setCaptionsHidden(!on) })) {
                Text("Burn into the video")
                    .font(.luma(size: 13.5, weight: .medium))
                    .foregroundStyle(LumaTheme.textPrimary)
            }
            .tint(LumaTheme.signal)
            if !isBurnedIn {
                Text("The video stays clean. Share the SRT file with your post instead.")
                    .font(.luma(size: 12))
                    .foregroundStyle(LumaTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let onDevice = job.lastRunOnDevice {
                Text(onDevice ? "Made on this iPhone." : "Made with Apple's speech servers.")
                    .font(.luma(size: 12))
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            smallButton("Regenerate", icon: "arrow.clockwise", emphasised: true) { generate() }
                .disabled(isCaptioning)
                .opacity(isCaptioning ? 0.4 : 1)
            smallButton("Copy SRT", icon: "doc.on.doc", emphasised: false) {
                UIPasteboard.general.string = editor.captionsSRT()
                app.importToast = "SRT copied"
            }
            if let srtURL {
                ShareLink(item: srtURL) {
                    smallLabel("Share SRT", icon: "square.and.arrow.up", emphasised: false)
                }
                .buttonStyle(.lumaPress)
            }
        }
    }

    private var removeAllButton: some View {
        Button {
            editingID = nil
            editor.removeAllCaptions()
            LumaHaptics.shared.tap()
        } label: {
            Text("Remove all captions")
                .font(.luma(size: 12.5, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCaptioning)
    }

    private func smallButton(_ title: String, icon: String, emphasised: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            smallLabel(title, icon: icon, emphasised: emphasised)
        }
        .buttonStyle(.lumaPress)
    }

    /// Emphasised = signal text on a faint signal rim (Regenerate, Open
    /// Settings); otherwise a quiet panel pill.
    private func smallLabel(_ title: String, icon: String, emphasised: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.luma(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(emphasised ? LumaTheme.signal : LumaTheme.textPrimary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(emphasised ? LumaTheme.signal.opacity(0.1) : LumaTheme.surface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(emphasised ? LumaTheme.signal.opacity(0.45) : LumaTheme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func generate() {
        guard !isCaptioning else { return }
        let locale = Locale(identifier: languageID)
        let style = currentStyle
        let position = currentPosition
        let size = currentSize
        let hidden = !lines.isEmpty && !isBurnedIn
        let job = self.job
        let editor = self.editor
        job.failure = nil
        job.progress = nil
        editingID = nil
        isCaptioning = true
        LumaHaptics.shared.tap()

        let onProgress: CaptionProgressHandler = { progress in
            Task { @MainActor in job.progress = progress }
        }
        Task { @MainActor in
            do {
                let transcript = try await editor.transcribeCaptions(locale: locale, onProgress: onProgress)
                let added = editor.replaceCaptions(transcript.segments, style: style,
                                                   position: position, size: size, hidden: hidden)
                job.lastRunOnDevice = transcript.onDevice
                job.failure = added == 0 ? .noSpeech : nil
                if added > 0 { app.importToast = "Added \(added) caption \(added == 1 ? "line" : "lines")" }
            } catch {
                job.failure = CaptionFailure(error)
            }
            job.progress = nil
            isCaptioning = false
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Changes whenever the SRT would.
    private var srtSignature: String {
        lines.map { "\($0.timelineOffset)|\($0.duration)|\($0.text ?? "")" }.joined(separator: "\n")
    }

    private func refreshSRTFile() {
        guard !lines.isEmpty else {
            srtURL = nil
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Captions.srt")
        do {
            try editor.captionsSRT().write(to: url, atomically: true, encoding: .utf8)
            srtURL = url
        } catch {
            srtURL = nil
        }
    }

    /// "0:06.2": minutes, then seconds to a tenth.
    static func timecode(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let minutes = Int(safe / 60)
        let rest = safe - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

// MARK: - Parts

/// One caption style, previewed as "Aa" in that style. Picked = signal rim,
/// as in the Night Lab captions mock.
private struct CaptionStyleTile: View {
    let style: CaptionStyle
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .frame(width: 58, height: 44)
                    .background(LumaTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isOn ? LumaTheme.signal : LumaTheme.hairline,
                                      lineWidth: isOn ? 1.5 : 1))
                Text(style.label)
                    .font(.luma(size: 10.5, weight: .medium))
                    .foregroundStyle(isOn ? LumaTheme.textPrimary : LumaTheme.textMuted)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }

    @ViewBuilder
    private var preview: some View {
        switch style {
        case .karaoke:
            HStack(spacing: 0) {
                Text("A").foregroundStyle(LumaTheme.signal)
                Text("a").foregroundStyle(Color.white)
            }
            .font(.luma(size: 17, weight: .heavy))
            .shadow(color: .black.opacity(0.6), radius: 3)
        case .highlight:
            Text("Aa")
                .font(.luma(size: 15, weight: .heavy))
                .foregroundStyle(LumaTheme.onSignal)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(LumaTheme.signal, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .pop:
            Text("Aa")
                .font(.luma(size: 19, weight: .heavy))
                .foregroundStyle(LumaTheme.signal)
                .shadow(color: .black, radius: 0.5)
        case .clean:
            Text("Aa")
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
        case .boxed:
            Text("Aa")
                .font(.luma(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

/// A compact segmented control for the drawer (30 pt tall).
private struct CaptionSegmented: View {
    let labels: [String]
    let selected: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                segment(index)
            }
        }
        .padding(2)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(LumaTheme.hairline, lineWidth: 1))
    }

    private func segment(_ index: Int) -> some View {
        let isOn = index == selected
        return Button {
            onSelect(index)
        } label: {
            Text(labels[index])
                .font(.luma(size: 12, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? LumaTheme.textPrimary : LumaTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LumaTheme.control)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(LumaTheme.border, lineWidth: 1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
