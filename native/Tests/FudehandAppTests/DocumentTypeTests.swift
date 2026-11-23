import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// The Info.plist in the repository (copied as is into the app bundle at build time).
private func infoPlist() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    return try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

@Test @MainActor func infoPlistExportsTheProjectFileTypeTheAppUses() throws {
    let plist = try infoPlist()
    let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let declaration = try #require(exported.first { $0["UTTypeIdentifier"] as? String == FudehandStore.contentTypeIdentifier })
    #expect((declaration["UTTypeConformsTo"] as? [String])?.contains("public.json") == true)
    let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
    #expect(tags["public.filename-extension"] as? [String] == [DesignDocument.fileExtension])
    #expect(FudehandStore.contentType.identifier == FudehandStore.contentTypeIdentifier)
}

@Test @MainActor func infoPlistDeclaresTheAppAsEditorOfProjectFiles() throws {
    let documents = try #require(try infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
    let document = try #require(documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(FudehandStore.contentTypeIdentifier) == true })
    #expect(document["CFBundleTypeRole"] as? String == "Editor")
    #expect(document["LSHandlerRank"] as? String == "Owner")
}

@Test @MainActor func filesOpenedFromFinderBeforeLaunchFinishesOpenOnceTheStoreIsReady() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-\(UUID().uuidString).fudehand")
    defer { try? FileManager.default.removeItem(at: url) }
    try DesignDocument(nodes: [DesignNode(id: "r", type: .rectangle)]).encoded().write(to: url)
    let delegate = FudehandAppDelegate()
    delegate.application(NSApplication.shared, open: [url])
    let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!)
    delegate.attach(store)
    await store.opening?.value
    #expect(store.fileURL == url && store.editor.document.node("r") != nil)
    // Later open requests go straight to the store; a bad file shows an error and the current document is unchanged.
    let bad = url.deletingLastPathComponent().appendingPathComponent("fudehand-\(UUID().uuidString).fudehand")
    try Data("not json".utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    delegate.application(NSApplication.shared, open: [bad])
    await store.opening?.value
    #expect(store.alert == "Not a Fudehand project file" && store.fileURL == url)
}

@Test @MainActor func uppercaseExtensionsOpenToo() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-\(UUID().uuidString).FUDEHAND")
    defer { try? FileManager.default.removeItem(at: url) }
    try DesignDocument(nodes: [DesignNode(id: "u", type: .ellipse)]).encoded().write(to: url)
    let delegate = FudehandAppDelegate()
    let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!)
    delegate.attach(store)
    delegate.application(NSApplication.shared, open: [url, URL(fileURLWithPath: "/tmp/readme.txt")])
    await store.opening?.value
    #expect(store.fileURL == url && store.editor.document.node("u") != nil)
}
