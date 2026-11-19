import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Icons listed for one library must not show, or be clickable, once the picker has switched to another; while typing, the
/// previous query's icons (from the same library) stay until the new results arrive, so the grid does not flicker.
@Test func pickerShowsOnlyResultsForTheCurrentLibrary() {
    let listed = IconPicker.Listing(library: .lucide, names: ["lucide/shopping-cart"])
    #expect(listed.names(for: .lucide) == ["lucide/shopping-cart"])
    #expect(listed.names(for: .materialOutlined) == nil)
}
