import AppKit
import SwiftUI
import Testing
@testable import FudehandApp

/// The AppKit pop-up button SwiftUI creates for a `.borderlessButton` menu with `label`.
@MainActor private func popUpSize<Label: View>(_ label: Label) throws -> NSSize {
    let menu = Menu { Button("Item") {} } label: { label }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    let host = NSHostingView(rootView: menu)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> NSButton? { (view as? NSButton) ?? view.subviews.lazy.compactMap(find).first }
    return try #require(find(host)).frame.size
}

/// AppKit draws a plain symbol menu 15pt tall; `MenuIcon` keeps it at least 16×16 (#174).
@Test @MainActor func menuIconGivesBorderlessMenusAClickTargetOfAtLeastSixteenPoints() throws {
    #expect(try popUpSize(Image(systemName: "clock.arrow.circlepath")).height < 16)
    let size = try popUpSize(MenuIcon(symbol: "clock.arrow.circlepath", label: "Conversation history"))
    #expect(size.width >= 16 && size.height >= 16)
}

@Test func menuIconIsATemplateWithTheLabelAsItsDescription() {
    let image = MenuIcon.image("chevron.up.chevron.down", label: "Choose model")
    #expect(image.size == NSSize(width: 20, height: 20) && image.isTemplate)
    #expect(image.accessibilityDescription == "Choose model")
}
