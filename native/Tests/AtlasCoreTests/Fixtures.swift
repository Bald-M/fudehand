import Foundation
import AtlasCore

func sampleCatalog() throws -> Catalog {
    let json = #"""
    {"version":1,"projects":[{"id":"demo","title":"演示","subtitle":"","description":"","author":"原创","sourceUrl":null,"framework":"HTML","tags":[],"enabled":true,"layoutVersion":1,"preview":{"cwd":"examples/demo","command":["pnpm","dev"],"port":4401,"baseUrl":"http://127.0.0.1:4401/demo/"},"frames":[{"id":"mobile","title":"移动端","platform":"mobile","path":"home?view=mobile#top","width":390,"height":844,"x":0,"y":0},{"id":"web","title":"网页端","platform":"web","path":"/?view=web","width":1440,"height":900,"x":470,"y":0}]}]}
    """#
    return try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
}
