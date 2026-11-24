import Foundation
import Testing
@testable import FudehandCore

@Suite struct ComponentPropertyTests {
    private static let excluded: Set<String> = Set(["id", "type", "children"]).union(DesignJSON.componentKeys)

    @Test func coversEveryNodeKey() {
        let paths = Set(ComponentProperty.all.map(\.path))
        for key in DesignJSON.nodeKeys.subtracting(Self.excluded) {
            #expect(paths.contains(key) || paths.contains { $0.hasPrefix(key + ".") }, "no path for \(key)")
        }
        for key in Self.excluded { #expect(!paths.contains(key)) }
        #expect(paths.contains("layout.padding"))
        #expect(paths.count == ComponentProperty.all.count)
    }

    @Test func textContentAloneKeepsFont() throws {
        var source = DesignNode(id: "s", type: .text)
        source.text = DesignText(content: "New", fontSize: 40)
        var target = DesignNode(id: "t", type: .text)
        target.text = DesignText(content: "Old", fontSize: 12)
        try #require(ComponentProperty.named("text.content")).copy(from: source, to: &target)
        #expect(target.text?.content == "New")
        #expect(target.text?.fontSize == 12)
    }

    @Test func changedReportsFieldPaths() {
        var a = DesignNode(id: "a", type: .text)
        a.text = DesignText(content: "x")
        var b = a
        b.fill = DesignColor(r: 1, g: 0, b: 0)
        b.text?.color = DesignColor(r: 0, g: 1, b: 0)
        #expect(ComponentProperty.changed(a, b) == ["fill", "text.color"])
        #expect(ComponentProperty.changed(a, a).isEmpty)
    }

    @Test func wholeObjectWhenOneSideNil() throws {
        let a = DesignNode(id: "a", type: .rectangle)
        var b = a
        b.stroke = DesignStroke(color: DesignColor(r: 0, g: 0, b: 0), width: 2)
        #expect(ComponentProperty.changed(a, b) == ["stroke"])
        #expect(ComponentProperty.changed(b, a) == ["stroke"])
        var target = a
        try #require(ComponentProperty.named("stroke")).copy(from: b, to: &target)
        #expect(target.stroke == b.stroke)
        try #require(ComponentProperty.named("stroke.width")).copy(from: a, to: &target)
        #expect(target.stroke == nil)
    }
}
