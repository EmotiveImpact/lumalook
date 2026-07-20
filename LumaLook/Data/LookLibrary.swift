import Foundation

/// One entry in the unified look library — the single value type every
/// "pick a look" surface renders, so installed packs, imported LUTs, saved
/// looks and the built-in presets all appear wherever a look can be applied.
///
/// Before this, each surface read a different slice (the editor saw only
/// `MockData.looks.prefix(10)`), so everything the Store sold and every LUT the
/// user imported was invisible exactly where they wanted to use it.
struct LibraryLook: Identifiable, Hashable {
    /// Stable across launches — `LookPreset.id` regenerates per launch, so a
    /// built-in is keyed by name; LUTs and saved looks by their persistent id.
    let id: String
    let name: String
    let section: Section
    let source: LookSource
    /// Cross-source favourite (LUTs read `LUTFile.isFavourite`; built-in and
    /// saved looks are favourited via `LookLibraryStore`).
    var isFavourite: Bool = false
    /// Display name of the source pack for `.installed` looks
    /// ("Film Stocks 01", "Basics"), nil for everything else.
    var packName: String? = nil
    /// The one cache key every `LookThumbs` consumer uses.
    var thumbKey: String { id }

    enum LookSource {
        case builtIn(LookPreset)
        case lut(LUTFile)
        case saved(SavedLook)
    }

    /// Display order: the user's own first, then the curated presets, then
    /// what they bought, then what they imported.
    enum Section: Int, CaseIterable, Comparable {
        case saved, builtIn, installed, imported
        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .saved:     return "Your Looks"
            case .builtIn:   return "Signature"
            case .installed: return "Purchased"
            case .imported:  return "Imported"
            }
        }
    }

    /// Identity is the stable id; `isFavourite` participates in == so a
    /// favourite toggle invalidates SwiftUI diffs, but not in hashing.
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.isFavourite == b.isFavourite }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// The ONE converter every apply-site uses. Setting `lutID` here is what
    /// makes installed/imported looks actually grade a clip — the engine
    /// (`TimelineEngine.makeLookState`) already loads the LUT when `lutID` is
    /// set; the old strip cells just hardcoded `lutID: nil`.
    func clipGrade() -> ClipGrade {
        switch source {
        case .builtIn(let p):
            return ClipGrade(baseLookName: p.name, lutID: nil, settings: LookSettings())
        case .lut(let f):
            return ClipGrade(baseLookName: "", lutID: f.id, settings: LookSettings())
        case .saved(let s):
            return ClipGrade(baseLookName: s.baseLookName, lutID: s.lutID, settings: s.settings)
        }
    }
}

extension AppModel {
    /// The unified library, ordered Saved → Built-in → Installed → Imported.
    /// Thin forward to `LookLibraryStore` — kept during migration so existing
    /// surfaces compile unchanged; new code should read `library` directly.
    var libraryLooks: [LibraryLook] { library.all }

    /// Grouped for sectioned pickers: [(section, looks)] in display order,
    /// omitting empty sections.
    var libraryLooksBySection: [(section: LibraryLook.Section, looks: [LibraryLook])] {
        library.bySection
    }
}
