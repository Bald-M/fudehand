import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// A font file that ships with macOS, standing in for a third-party font file.
private let sampleFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-fonts-\(UUID().uuidString)")
}

@MainActor private func makeStore(fonts: URL? = nil) -> FudehandStore {
    FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!, fontDirectory: fonts)
}

@Test @MainActor func listsInstalledFamiliesSortedWithoutHiddenOnes() {
    let families = FontLibrary(directory: nil).families()
    #expect(families.contains(FontFamily(name: "Helvetica", imported: false)))
    #expect(!families.contains { $0.name.hasPrefix(".") })
    #expect(families.map(\.name) == families.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
}

@Test @MainActor func importCopiesTheFileIntoTheLibraryAndReportsItsFamilies() throws {
    let directory = temporaryDirectory()
    let library = FontLibrary(directory: directory)
    #expect(try library.importFont(sampleFont) == ["Arial"])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Arial.ttf").path))
    #expect(library.families().contains(FontFamily(name: "Arial", imported: true)))
    // Importing a file with the same name again replaces it.
    #expect(try library.importFont(sampleFont) == ["Arial"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Arial.ttf"])
}

@Test @MainActor func replacingAFileDropsTheFamiliesItNoLongerHolds() throws {
    let directory = temporaryDirectory()
    let library = FontLibrary(directory: directory)
    _ = try library.importFont(sampleFont)
    // Another font file under the same file name.
    let source = temporaryDirectory()
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let renamed = source.appendingPathComponent("Arial.ttf")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf"), to: renamed)
    #expect(try library.importFont(renamed) == ["Georgia"])
    #expect(library.families().contains(FontFamily(name: "Georgia", imported: true)))
    #expect(library.families().contains(FontFamily(name: "Arial", imported: false)))
}

@Test @MainActor func aNewLibraryRegistersTheFilesAlreadyInItsDirectory() throws {
    let directory = temporaryDirectory()
    _ = try FontLibrary(directory: directory).importFont(sampleFont)
    #expect(FontLibrary(directory: directory).families().contains(FontFamily(name: "Arial", imported: true)))
}

@Test @MainActor func importRejectsAFileThatIsNotAFont() throws {
    let directory = temporaryDirectory()
    let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-\(UUID().uuidString).ttf")
    try Data("not a font".utf8).write(to: bogus)
    let library = FontLibrary(directory: directory)
    #expect(throws: FontImportError(file: bogus.lastPathComponent, notAFont: true)) { try library.importFont(bogus) }
    #expect(throws: FontImportError(file: "missing.otf", notAFont: true)) { try library.importFont(directory.appendingPathComponent("missing.otf")) }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(bogus.lastPathComponent).path))
}

@Test @MainActor func agentListsFontsAndImportsAFontFile() async throws {
    let directory = temporaryDirectory()
    let store = makeStore(fonts: directory)
    let listed = try #require(try await store.handleControl(.listFonts) as? [String: Any])
    let fonts = try #require(listed["fonts"] as? [[String: String]])
    #expect(fonts.contains(["family": "Helvetica", "source": "system"]))

    let imported = try #require(try await store.handleControl(.importFont(sampleFont.path)) as? [String: Any])
    #expect(imported["families"] as? [String] == ["Arial"])
    #expect(store.fontFamilies.contains(FontFamily(name: "Arial", imported: true)))
    let after = try #require((try await store.handleControl(.listFonts) as? [String: Any])?["fonts"] as? [[String: String]])
    #expect(after.contains(["family": "Arial", "source": "imported"]))

    do {
        _ = try await store.handleControl(.importFont(directory.appendingPathComponent("missing.ttf").path))
        Issue.record("Importing a missing file should fail")
    } catch {
        #expect(error.localizedDescription == "Not a font file: missing.ttf")
    }
}

@Test @MainActor func textIsDrawnAgainWhenTheFontsChange() throws {
    let renderer = DesignRenderer()
    var node = DesignNode(id: "t", type: .text, width: 80, height: 20)
    node.text = DesignText(content: "Title", fontFamily: "Arial")
    renderer.sync([node])
    let layer = try #require(renderer.layer(for: "t") as? TextLayer)
    let before = layer.attributed
    renderer.sync([node])
    #expect(layer.attributed === before)
    renderer.fontsChanged()
    renderer.sync([node])
    #expect(layer.attributed !== before)
}
