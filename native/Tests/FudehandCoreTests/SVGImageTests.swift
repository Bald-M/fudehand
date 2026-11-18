import Foundation
import Testing
@testable import FudehandCore

private let logo = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="48" height="24"><rect width="48" height="24" fill="#EA4335"/></svg>"##.utf8)

private func imageNode(_ data: Data) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "i", "type": "image", "image": ["data": data.base64EncodedString()]])
}

@Test func acceptsSVGImageData() throws {
    #expect(try imageNode(logo).image?.data == logo)
    let viewBoxOnly = Data(#"<?xml version="1.0"?><svg viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>"#.utf8)
    #expect(try imageNode(viewBoxOnly).image?.data == viewBoxOnly)
}

@Test func rejectsDataThatIsNotPNGJPEGOrSVG() {
    for text in ["hello", #"<svg width="10"><rect>"#, #"<html><body>Hi</body></html>"#, #"<?xml version="1.0"?><note>svg</note>"#] {
        #expect(throws: DesignError("Layer i: image.data must be a base64-encoded PNG, JPEG, or SVG")) { try imageNode(Data(text.utf8)) }
    }
}

@Test func keepsSVGBytesThroughSaveAndOpen() throws {
    var node = DesignNode(id: "i", type: .image, width: 48, height: 24)
    node.image = DesignImage(data: logo, fit: .fit)
    let again = try DesignDocument.decode(try DesignDocument(nodes: [node]).encoded())
    #expect(again.nodes[0].image == DesignImage(data: logo, fit: .fit))
}
