import Foundation
import Testing
@testable import FudehandCore

/// The starter templates in `native/Resources/Templates/` and the values in `docs/design-foundations.md`; update both together.
private enum Foundations {
    static let colors: Set<String> = ["#F6F5F2", "#FFFFFF", "#1D1C21", "#6B6874", "#E4E1DB", "#1F6B57", "#E1EEE9"]
    static let fontFamily = "Avenir Next"
    static let fontWeights: Set<Int> = [400, 500, 600]
    static let fontSizes: Set<Double> = [12, 14, 16, 20, 24, 32, 48]
    static let spacing: Set<Double> = [0, 4, 8, 12, 16, 24, 32, 48, 64]
    static let cornerRadii: Set<Double> = [0, 4, 8, 16, 999]
    static let strokeWidth = 1.0
}

private let templateDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Templates")

private func templateURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: templateDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == DesignDocument.fileExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func templateName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

@Test func bundledTemplatesAreTheThreeStarters() throws {
    #expect(try templateURLs().map(templateName) == ["Dashboard", "Mobile App", "Web Page"])
}

@Test(arguments: try templateURLs())
func bundledTemplateDecodesAndFollowsTheFoundations(url: URL) throws {
    let document = try DesignDocument.decode(Data(contentsOf: url))
    let name = templateName(url)
    #expect(document.nodes.contains { $0.type == .frame && $0.name == "Design system" }, "\(name) has no Design system frame")
    #expect(document.nodes.count >= 2, "\(name) needs its screen next to the Design system frame")

    func check(_ node: DesignNode, parent: DesignNode?) {
        let where_ = "\(name) › \(node.name)"
        let colors = [node.fill, node.stroke?.color, node.text?.color, node.icon?.color].compactMap { $0?.hex }
        for color in colors { #expect(Foundations.colors.contains(color), "\(where_): color \(color)") }
        if let stroke = node.stroke { #expect(stroke.width == Foundations.strokeWidth, "\(where_): stroke width") }
        #expect(Foundations.cornerRadii.contains(node.cornerRadius), "\(where_): corner radius \(node.cornerRadius)")
        #expect(node.image == nil, "\(where_): templates carry no image layers")
        if let text = node.text {
            #expect(text.fontFamily == Foundations.fontFamily, "\(where_): font \(text.fontFamily ?? "default")")
            #expect(Foundations.fontWeights.contains(text.fontWeight), "\(where_): weight \(text.fontWeight)")
            #expect(Foundations.fontSizes.contains(text.fontSize), "\(where_): size \(text.fontSize)")
            #expect(text.lineHeight == nil, "\(where_): line height is the font default")
            // Text sits in auto layout, so editing it reflows its parent instead of overlapping neighbors.
            #expect(parent?.layout != nil, "\(where_): text outside auto layout")
            // In a column whose width is set, text keeps a width (filling the column, or a set measure) and wraps
            // instead of growing past the column's edge.
            if let parent, parent.layout?.direction == .vertical, parent.sizing.horizontal != .hug {
                #expect(text.autoResize == .height && node.sizing.horizontal != .hug, "\(where_): text does not wrap")
            }
        }
        if let layout = node.layout {
            let padding = layout.padding
            for value in [layout.spacing, padding.top, padding.right, padding.bottom, padding.left] {
                #expect(Foundations.spacing.contains(value), "\(where_): spacing \(value)")
            }
        }
        for child in node.children { check(child, parent: node) }
    }
    for node in document.nodes { check(node, parent: nil) }
}

@Test func bundledTemplateNamesAreLocalized() throws {
    for name in try templateURLs().map(templateName) {
        for language in AppLanguage.allCases {
            let value = L10n.table(language)[name]
            #expect(value?.isEmpty == false, "\(language.rawValue) has no name for template \(name)")
        }
        #expect(L10n.table(.zhHans)[name] != name, "template \(name) is not translated into Simplified Chinese")
    }
    // A template a person adds without a table entry shows its file name.
    #expect(L10n.string("Brand Kit 2027", language: .zhHans) == "Brand Kit 2027")
}
