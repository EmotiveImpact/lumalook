import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Imports and registers user .ttf/.otf fonts so `TextRasterizer` can resolve
/// them by PostScript name on the compositor's render queue.
///
/// Registration is `.process`-scoped — it lives for the app session only, so
/// `registerInstalledFonts(in:)` must run at every launch before any text is
/// rasterized. Everything here is callable off the main queue: CoreText font
/// registration and CGFont parsing are both thread-safe, and the name cache is
/// behind an `NSLock` like the other renderers.
enum FontLibrary {
    private static let lock = NSLock()
    /// file path -> PostScript name. Bounded: the picker asks for names often.
    private static var nameCache: [String: String] = [:]
    private static let maxEntries = 40
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    // MARK: - Built-ins

    /// PostScript names of the curated system faces offered in the picker.
    static var builtInFontNames: [String] { resolvedBuiltIns }

    private static let curatedBuiltIns = [
        "HelveticaNeue-Bold",
        "AvenirNext-Bold",
        "Futura-Bold",
        "Georgia-Bold",
        "Menlo-Bold",
        "SnellRoundhand-Black",
        "MarkerFelt-Wide",
        "Copperplate-Bold",
        "DINCondensed-Bold",
        "Baskerville-Bold"
    ]

    /// Filtered to names the system actually resolves — an unavailable name
    /// silently substitutes Helvetica rather than failing, so a bad entry would
    /// show the user a lying preview. `static let` init is lazy and once-only,
    /// hence safe from the render queue.
    private static let resolvedBuiltIns: [String] = curatedBuiltIns.filter(isResolvable)

    /// True when CoreText returns the face we asked for rather than a substitute.
    private static func isResolvable(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        let actual = CTFontCopyPostScriptName(font) as String
        return actual.caseInsensitiveCompare(postScriptName) == .orderedSame
    }

    // MARK: - Import

    /// Copies a user font into `folder`, registers it, returns its PostScript name.
    /// Returns nil if the file isn't a font we can name or address.
    @discardableResult
    static func importFont(from url: URL, into folder: URL) -> String? {
        guard fontExtensions.contains(url.pathExtension.lowercased()) else { return nil }

        // fileImporter hands back a security-scoped URL: hold the scope across the
        // whole read and drop it on every exit path.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }

        let destination = folder.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        guard (try? fm.copyItem(at: url, to: destination)) != nil else { return nil }

        // Name it from OUR copy, before registering: an unnameable file is useless
        // to the rasterizer, so bin it rather than leave a dead weight in Documents.
        guard let name = postScriptName(of: destination) else {
            try? fm.removeItem(at: destination)
            return nil
        }
        guard register(destination) else {
            try? fm.removeItem(at: destination)
            return nil
        }
        cache(name, for: destination)
        return name
    }

    // MARK: - Launch registration

    /// Registers every font already in `folder` (call at launch); returns the
    /// registered PostScript names.
    @discardableResult
    static func registerInstalledFonts(in folder: URL) -> [String] {
        var names: [String] = []
        for url in fontFiles(in: folder) {
            guard let name = postScriptName(of: url), register(url) else { continue }
            cache(name, for: url)
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }

    /// All usable PostScript names = builtIn + registered.
    static func allFontNames(in folder: URL) -> [String] {
        var names = builtInFontNames
        for name in installedFontNames(in: folder) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    // MARK: - Helpers

    /// Returns true when the font is usable afterwards — including when something
    /// already registered it (re-import of the same face, or a second launch pass).
    private static func register(_ url: URL) -> Bool {
        var cfError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) { return true }
        // The error out-param follows the Create rule, so it arrives at +1.
        guard let error = cfError?.takeRetainedValue() else { return false }
        return CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
    }

    /// PostScript name straight off the file. CGFont reads the first face only,
    /// which is all a single name can address anyway.
    private static func postScriptName(of url: URL) -> String? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider),
              let name = font.postScriptName else { return nil }
        return name as String
    }

    /// Names of the fonts sitting in `folder`, cache-first so the picker can call
    /// this per redraw without re-parsing font files off disk.
    private static func installedFontNames(in folder: URL) -> [String] {
        var names: [String] = []
        for url in fontFiles(in: folder) {
            guard let name = cachedName(for: url) ?? postScriptName(of: url) else { continue }
            cache(name, for: url)
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }

    private static func fontFiles(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { fontExtensions.contains($0.pathExtension.lowercased()) }
    }

    private static func cachedName(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return nameCache[url.path]
    }

    private static func cache(_ name: String, for url: URL) {
        lock.lock()
        if nameCache.count > maxEntries { nameCache.removeAll() }
        nameCache[url.path] = name
        lock.unlock()
    }
}
