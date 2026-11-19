import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

@MainActor private func iconNode(_ name: String, color: String = "#FF0000", width: Double = 24, height: Double = 24) throws -> DesignNode {
    var node = DesignNode(id: "i", type: .icon, width: width, height: height)
    node.icon = DesignIcon(name: name, color: try DesignColor(hex: color))
    return node
}

/// RGBA bytes of a CGImage, rows top to bottom.
private struct Pixels {
    let width: Int, height: Int, bytes: [UInt8]
    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }
    subscript(x: Int, y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 4]) }
    func columnIsClear(_ x: Int) -> Bool { (0..<height).allSatisfy { self[x, $0][3] == 0 } }
    var hasOpaque: Bool { stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] == 255 } }
    var hasInk: Bool { stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 } }
}

@MainActor private func raster(_ node: DesignNode, scale: CGFloat = 1) throws -> (IconLayer, Pixels) {
    let renderer = DesignRenderer()
    renderer.contentsScale = scale
    renderer.sync([node])
    let layer = try #require(renderer.layer(for: node.id) as? IconLayer)
    return (layer, Pixels(layer.contents as! CGImage))
}

@Test @MainActor func iconRasterIsAspectFitAndCentered() throws {
    let (_, pixels) = try raster(try iconNode("material-outlined/home", width: 48, height: 24))
    #expect(pixels.width == 48 && pixels.height == 24)
    for x in [0, 5, 11, 36, 42, 47] { #expect(pixels.columnIsClear(x), "column \(x)") }
    #expect(!pixels.columnIsClear(24))
}

@Test @MainActor func iconIsTintedWithColor() throws {
    let (_, pixels) = try raster(try iconNode("material-outlined/home", color: "#FF0000"), scale: 2)
    // The roof outline crosses the center column near the top.
    #expect(pixels[24, 8] == [255, 0, 0, 255])
}

@Test @MainActor func colorChangeReRasterizes() throws {
    let renderer = DesignRenderer()
    var node = try iconNode("material-outlined/home", color: "#FF0000")
    renderer.sync([node])
    let layer = try #require(renderer.layer(for: "i"))
    let red = layer.contents as! CGImage
    node.icon?.color = try DesignColor(hex: "#0000FF")
    renderer.sync([node])
    #expect(layer.contents as! CGImage !== red)
    #expect(Pixels(layer.contents as! CGImage)[24, 8] == [0, 0, 255, 255])
}

@Test @MainActor func zoomInRerasterizesSharp() throws {
    let renderer = DesignRenderer()
    renderer.contentsScale = 1
    renderer.sync([try iconNode("lucide/house")])
    let layer = try #require(renderer.layer(for: "i"))
    #expect((layer.contents as! CGImage).width == 24)
    renderer.contentsScale = 16
    #expect((layer.contents as! CGImage).width == 384)
}

@Test @MainActor func iconsFromEveryBundledLibraryDraw() throws {
    for name in ["material-outlined/home", "material-rounded/home.fill", "material-sharp/search", "weui/success", "lucide/house"] {
        let (layer, pixels) = try raster(try iconNode(name))
        #expect(!layer.isPlaceholder && pixels.hasOpaque, "\(name)")
    }
}

@Test @MainActor func sfSymbolRenders() throws {
    let (layer, pixels) = try raster(try iconNode("sf/house.fill"), scale: 2)
    #expect(!layer.isPlaceholder && pixels.hasOpaque)
}

@Test @MainActor func unknownIconIsPlaceholder() throws {
    for name in ["sf/not.a.real.symbol", "lucide/not-a-real-icon"] {
        let (layer, pixels) = try raster(try iconNode(name))
        #expect(layer.isPlaceholder && pixels.hasInk, "\(name)")
    }
}

@Test @MainActor func snapshotShowsIconUpright() throws {
    let image = try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(try iconNode("material-outlined/home"), scale: 2)))
    let pixels = Pixels(try #require(image.cgImage))
    #expect(pixels.width == 48 && pixels.height == 48)
    // The roof's peak is at the top center and the door opening at the bottom center; a flipped raster swaps them.
    #expect(pixels[24, 8] == [255, 0, 0, 255])
    #expect(pixels[24, 39][3] == 0)
}

@Test @MainActor func systemSymbolsComeFromTheSystem() {
    #expect(SystemSymbols.exists("house.fill"))
    #expect(!SystemSymbols.exists("not.a.real.symbol"))
    #expect(SystemSymbols.names().contains("house.fill"))
    _ = FudehandStore(defaults: UserDefaults(suiteName: "icon-tests-\(UUID().uuidString)")!)
    #expect(IconCatalog.shared.exists("sf/house.fill"))
    #expect(IconCatalog.shared.search("house.fill", library: .sf).first == "sf/house.fill")
}

@Test @MainActor func sfSymbolsKeepAnOpticalMarginLikeBundledIcons() throws {
    // A 24 × 24 layer: SF Symbols are drawn at a point size for the layer, not stretched edge to edge.
    let (_, minus) = try raster(try iconNode("sf/minus"), scale: 1)
    #expect(minus.columnIsClear(0) && minus.columnIsClear(23))
    let (_, chevron) = try raster(try iconNode("sf/chevron.right"), scale: 1)
    let inked = (0..<24).filter { y in (0..<24).contains { chevron[$0, y][3] > 0 } }
    #expect(inked.count < 20, "chevron spans \(inked.count) rows")
    #expect(!inked.isEmpty)
}

@Test @MainActor func systemSymbolKeywordsComeFromTheSystem() {
    #expect(SystemSymbols.tags()["magnifyingglass"]?.contains("search") == true)
}
