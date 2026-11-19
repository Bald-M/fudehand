import Foundation
import Testing
@testable import FudehandCore

private let catalog = IconCatalog(symbolExists: { ["house", "house.fill", "heart"].contains($0) },
                                  symbolNames: { ["heart", "house", "house.fill"] })

@Test func bundledIconsExist() {
    for name in ["lucide/house", "material-outlined/home", "material-rounded/home.fill", "material-sharp/search", "weui/success"] {
        #expect(catalog.exists(name), "\(name)")
    }
    for name in ["lucide/nope", "material-outlined/home.fill.fill", "weui/house", "bogus/house", "lucide"] {
        #expect(!catalog.exists(name), "\(name)")
    }
}

@Test func svgIsParseable() throws {
    let svg = try #require(catalog.svg("lucide/house"))
    #expect(DesignJSON.isSVG(svg))
    #expect(catalog.svg("sf/house") == nil)
    #expect(catalog.svg("lucide/nope") == nil)
}

@Test func sfUsesInjectedFunctions() {
    #expect(catalog.exists("sf/house"))
    #expect(!catalog.exists("sf/nope"))
    #expect(catalog.search("house", library: .sf) == ["sf/house", "sf/house.fill"])
    #expect(IconCatalog().search("house", library: .sf).isEmpty)
}

@Test func searchRanksExactThenPrefixThenSubstringThenTag() {
    let results = catalog.search("house", library: .lucide)
    #expect(results.first == "lucide/house")
    let names = results.map { String($0.dropFirst("lucide/".count)) }
    let firstTagOnly = names.firstIndex { !$0.contains("house") }
    let lastNameHit = names.lastIndex { $0.contains("house") }
    #expect(firstTagOnly != nil && lastNameHit != nil && lastNameHit! < firstTagOnly!)
    // "home" only appears as a tag of lucide/house.
    #expect(catalog.search("home", library: .lucide).contains("lucide/house"))
}

@Test func searchAcrossLibraries() {
    let results = catalog.search("home", limit: 200)
    #expect(results.contains("material-outlined/home"))
    #expect(results.contains("material-rounded/home.fill"))
    #expect(results.contains("lucide/house"))
}

@Test func searchIsCaseInsensitiveAndTrimmed() {
    #expect(catalog.search("  House ", library: .lucide).first == "lucide/house")
    #expect(catalog.search("   ").isEmpty)
}

@Test func searchRespectsLimit() {
    #expect(catalog.search("arrow", limit: 5).count == 5)
    #expect(catalog.search("arrow", library: .weui).allSatisfy { $0.hasPrefix("weui/") })
}

@Test func suggestionsPreferSameLibrary() {
    let suggestions = catalog.suggestions(for: "lucide/hous")
    #expect(suggestions.first == "lucide/house")
    #expect(suggestions.count <= 5)
    #expect(suggestions.allSatisfy { $0.hasPrefix("lucide/") })
    #expect(catalog.suggestions(for: "sf/hous").first == "sf/house")
}

@Test func suggestionsForUnknownLibraryAreEmpty() {
    #expect(catalog.suggestions(for: "bogus/house").isEmpty)
    #expect(catalog.suggestions(for: "house").isEmpty)
}

@Test func sfSearchMatchesSystemKeywords() {
    let catalog = IconCatalog(symbolExists: { _ in true }, symbolNames: { ["magnifyingglass", "gearshape", "house"] },
                              symbolTags: { ["magnifyingglass": ["search"], "gearshape": ["general", "settings"], "house": ["home"]] })
    #expect(catalog.search("search", library: .sf) == ["sf/magnifyingglass"])
    #expect(catalog.search("settings", library: .sf) == ["sf/gearshape"])
    #expect(catalog.search("home", library: .sf) == ["sf/house"])
}

@Test func multiWordQueriesMatchAnySeparator() {
    let results = catalog.search("shopping cart", limit: 200)
    #expect(results.contains("lucide/shopping-cart"))
    #expect(results.contains("material-outlined/shopping_cart"))
    #expect(catalog.search("arrow left", library: .lucide).first == "lucide/arrow-left")
    #expect(catalog.search("Arrow_Left", library: .lucide).first == "lucide/arrow-left")
    #expect(catalog.search("house.fill", library: .sf).first == "sf/house.fill")
    // Every word must match, in any order.
    #expect(catalog.search("cart shopping", library: .lucide).contains("lucide/shopping-cart"))
    #expect(!catalog.search("shopping zebra", library: .lucide).contains("lucide/shopping-cart"))
}

@Test func listingWithoutAQueryIsTheWholeLibrarySorted() {
    let all = catalog.listing("", library: .weui)
    #expect(all.count == 27)
    #expect(all.allSatisfy { $0.hasPrefix("weui/") })
    #expect(all == all.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    #expect(catalog.listing("  ", library: .weui) == all)
}

@Test func listingWithAQuerySearchesOnlyThatLibrary() {
    let results = catalog.listing("house", library: .lucide)
    #expect(results.first == "lucide/house")
    #expect(results.allSatisfy { $0.hasPrefix("lucide/") })
}

@Test func sfListingUsesTheInjectedNames() {
    #expect(IconCatalog(symbolNames: { ["b", "a"] }).listing("", library: .sf) == ["sf/a", "sf/b"])
    #expect(IconCatalog().listing("", library: .sf).isEmpty)
}

@Test func sfListingPutsLocalizedVariantsAfterTheBaseNames() {
    let catalog = IconCatalog(symbolNames: { ["0.circle.ar", "0.circle", "a.rtl", "character.ja", "house", "textformat.el", "arrow.up"] })
    #expect(catalog.listing("", library: .sf)
        == ["sf/0.circle", "sf/arrow.up", "sf/house", "sf/0.circle.ar", "sf/a.rtl", "sf/character.ja", "sf/textformat.el"])
    // Search results keep them in rank order.
    #expect(catalog.listing("0 circle", library: .sf) == ["sf/0.circle", "sf/0.circle.ar"])
}
