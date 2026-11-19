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
