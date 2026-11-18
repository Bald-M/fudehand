import AppKit
import FudehandCore
import CoreText

/// A font family a text layer can use.
struct FontFamily: Equatable {
    let name: String
    /// From a font file in the font library, as opposed to installed on the system.
    let imported: Bool
}

/// A font file that could not be imported; `localizedDescription` is for the UI, `english` for the control channel.
struct FontImportError: LocalizedError, Equatable {
    let file: String
    /// The file holds no font, as opposed to failing to be copied or registered.
    let notAFont: Bool
    var english: String { notAFont ? "Not a font file: \(file)" : "Could not import font: \(file)" }
    var errorDescription: String? { notAFont ? L("Not a font file: %@", file) : L("Could not import font: %@", file) }
}

/// The font library: third-party font files copied into one directory and registered for this process only, so they are
/// available to Fudehand without being installed on the system.
@MainActor
final class FontLibrary {
    static let fileExtensions = ["ttf", "otf", "ttc"]

    static var savedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/fudehand/Fonts")
    }

    private let directory: URL?
    /// The font families of each registered file, by path; a file replaced under the same name drops its old families.
    private var files: [String: [String]] = [:]
    private var imported: Set<String> { Set(files.values.joined()) }

    /// Registers the font files already in `directory`. With nil, imported files are used in place, until the App quits.
    init(directory: URL?) {
        self.directory = directory
        guard let directory, let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in contents where Self.fileExtensions.contains(file.pathExtension.lowercased()) {
            let names = Self.familyNames(in: file)
            if !names.isEmpty, Self.register(file) { files[file.path] = names }
        }
    }

    /// Installed and imported families, sorted by name, without the system's hidden families (their names start with a period).
    func families() -> [FontFamily] {
        Set(NSFontManager.shared.availableFontFamilies).union(imported)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FontFamily(name: $0, imported: imported.contains($0)) }
    }

    /// Copies a font file into the library, replacing a file of the same name, and registers it. Returns its font families.
    func importFont(_ url: URL) throws -> [String] {
        let names = Self.familyNames(in: url)
        guard !names.isEmpty else { throw FontImportError(file: url.lastPathComponent, notAFont: true) }
        var target = url
        if let directory {
            target = directory.appendingPathComponent(url.lastPathComponent)
            if target.standardizedFileURL != url.standardizedFileURL {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: target.path) {
                        CTFontManagerUnregisterFontsForURL(target as CFURL, .process, nil)
                        files[target.path] = nil
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: url, to: target)
                } catch {
                    throw FontImportError(file: url.lastPathComponent, notAFont: false)
                }
            }
        }
        guard Self.register(target) else { throw FontImportError(file: url.lastPathComponent, notAFont: false) }
        files[target.path] = names
        return names
    }

    /// The font families a file holds; empty when it is not a font file.
    private static func familyNames(in url: URL) -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }).sorted()
    }

    /// Registering a file that is already registered counts as success.
    private static func register(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        return error.map { CFErrorGetCode($0.takeRetainedValue()) == CTFontManagerError.alreadyRegistered.rawValue } ?? false
    }
}
