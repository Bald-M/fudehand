import AppKit
import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

/// 仓库里的 Info.plist（构建时原样复制进 App 包）。
private func infoPlist() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    return try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

@Test @MainActor func infoPlistExportsTheProjectFileTypeTheAppUses() throws {
    let plist = try infoPlist()
    let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let declaration = try #require(exported.first { $0["UTTypeIdentifier"] as? String == AtlasStore.contentTypeIdentifier })
    #expect((declaration["UTTypeConformsTo"] as? [String])?.contains("public.json") == true)
    let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
    #expect(tags["public.filename-extension"] as? [String] == [DesignDocument.fileExtension])
    #expect(AtlasStore.contentType.identifier == AtlasStore.contentTypeIdentifier)
}

@Test @MainActor func infoPlistDeclaresTheAppAsEditorOfProjectFiles() throws {
    let documents = try #require(try infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
    let document = try #require(documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(AtlasStore.contentTypeIdentifier) == true })
    #expect(document["CFBundleTypeRole"] as? String == "Editor")
    #expect(document["LSHandlerRank"] as? String == "Owner")
}

@Test @MainActor func filesOpenedFromFinderBeforeLaunchFinishesOpenOnceTheStoreIsReady() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-\(UUID().uuidString).uiatlas")
    defer { try? FileManager.default.removeItem(at: url) }
    try DesignDocument(nodes: [DesignNode(id: "r", type: .rectangle)]).encoded().write(to: url)
    let delegate = AtlasAppDelegate()
    delegate.application(NSApplication.shared, open: [url])
    let store = AtlasStore(defaults: UserDefaults(suiteName: "ui-atlas-tests-\(UUID().uuidString)")!)
    delegate.attach(store)
    #expect(store.fileURL == url && store.editor.document.node("r") != nil)
    // 之后的打开请求直接交给 store；坏文件显示错误，当前文档不变。
    let bad = url.deletingLastPathComponent().appendingPathComponent("ui-atlas-\(UUID().uuidString).uiatlas")
    try Data("not json".utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    delegate.application(NSApplication.shared, open: [bad])
    #expect(store.alert == "不是 ui-atlas 工程文件" && store.fileURL == url)
}
