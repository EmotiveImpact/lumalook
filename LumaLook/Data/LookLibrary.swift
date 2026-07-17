import Foundation

/// One entry in the unified look library — the single value type every
/// "pick a look" surface renders, so installed packs, imported LUTs, saved
/// looks and the built-in presets all appear wherever a look can be applied.
///
/// Before this, each surface read a different slice (the editor saw only
/// `MockData.looks.prefix(10)`), so everything the Store sold and every LUT the
/// user imported was invisible exactly where they wanted to use it.
struct LibraryLook: Identifiable {
    /// Stable across launches — `LookPreset.id` regenerates per launch, so a
    /// built-in is keyed by name; LUTs and saved looks by their persistent id.
    let id: String
    let name: String
    let section: Section
    let source: LookSource

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
            case .installed: return "Installed Packs"
            case .imported:  return "Imported LUTs"
            }
        }
    }

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
    /// Reads the three live stores (`store`, `lutRepository`, `packStore`);
    /// AppModel forwards their change notifications, so this stays current.
    var libraryLooks: [LibraryLook] {
        var out: [LibraryLook] = []

        // Your saved looks first.
        for s in store.savedLooks {
            out.append(LibraryLook(id: "saved:\(s.id.uuidString)", name: s.name,
                                   section: .saved, source: .saved(s)))
        }
        // The 10 built-in signature presets.
        for p in MockData.looks {
            out.append(LibraryLook(id: "builtin:\(p.name)", name: p.name,
                                   section: .builtIn, source: .builtIn(p)))
        }
        // LUTs split by origin: pack-installed vs user-imported.
        for f in lutRepository.luts {
            let section: LibraryLook.Section = f.packID == nil ? .imported : .installed
            out.append(LibraryLook(id: "lut:\(f.id.uuidString)", name: f.displayName,
                                   section: section, source: .lut(f)))
        }
        return out
    }

    /// Grouped for sectioned pickers: [(section, looks)] in display order,
    /// omitting empty sections.
    var libraryLooksBySection: [(section: LibraryLook.Section, looks: [LibraryLook])] {
        let all = libraryLooks
        return LibraryLook.Section.allCases.compactMap { sec in
            let looks = all.filter { $0.section == sec }
            return looks.isEmpty ? nil : (sec, looks)
        }
    }
}
