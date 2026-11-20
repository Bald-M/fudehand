import AppKit
import Foundation
import Testing
@testable import FudehandApp

@Test @MainActor func appearanceSettingMapsToTheAppAppearance() {
    #expect(FudehandStore.appearance(for: "dark")?.name == .darkAqua)
    #expect(FudehandStore.appearance(for: "light")?.name == .aqua)
    #expect(FudehandStore.appearance(for: "system") == nil)
    #expect(FudehandStore.appearance(for: nil) == nil)
    #expect(FudehandStore.appearance(for: "sepia") == nil)
}

/// AppKit-presented UI (open and save panels, alerts) follows `NSApp.appearance`, not SwiftUI's preferred color scheme.
@Test @MainActor func appAppearanceFollowsTheAppearanceSetting() {
    let app = NSApplication.shared
    let defaults = UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!
    defaults.set("dark", forKey: "native.theme")
    let store = FudehandStore(defaults: defaults)
    let delegate = FudehandAppDelegate()
    delegate.attach(store)
    #expect(app.appearance?.name == .darkAqua)
    store.theme = "light"
    #expect(app.appearance?.name == .aqua)
    store.theme = "system"
    #expect(app.appearance == nil)
}
