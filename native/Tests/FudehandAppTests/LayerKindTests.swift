import FudehandCore
import Testing
@testable import FudehandApp

/// The inspector header names a layer's component role, not just its type (a component set is a frame underneath).
@Test func layerKindNamesComponentRoles() {
    var set = DesignNode(id: "set", type: .frame, name: "Button")
    set.componentSet = ["State"]
    var variant = DesignNode(id: "v", type: .frame, name: "State=Default")
    variant.component = true
    variant.variant = ["State": "Default"]
    var main = DesignNode(id: "m", type: .frame, name: "Header")
    main.component = true
    var instance = DesignNode(id: "i", type: .frame, name: "Header")
    instance.instance = "m"
    let frame = DesignNode(id: "f", type: .frame, name: "Screen")

    #expect(set.kindTitle == L("Component Set"))
    #expect(variant.kindTitle == L("Variant"))
    #expect(main.kindTitle == L("Main Component"))
    #expect(instance.kindTitle == L("Instance"))
    #expect(frame.kindTitle == NodeType.frame.title)

    #expect(set.kindSymbol == "square.grid.2x2")
    #expect(variant.kindSymbol == "square.on.square.dashed")
    #expect(instance.kindSymbol == "diamond")
    #expect(frame.kindSymbol == NodeType.frame.symbol)
}
