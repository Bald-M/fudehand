import Foundation

/// The files of a layer exported as HTML: `index.html` and its assets, by path relative to the export directory.
public struct DesignHTMLExport: Equatable, Sendable {
    public var html: String
    /// Relative path → bytes, including `index.html`.
    public var files: [String: Data]
    /// Layer id → relative path of the asset file an image or icon layer uses.
    public var assets: [String: String]
}

/// Turns a laid-out layer (usually a frame) into an HTML page with one CSS class per layer, as a reference for implementing the
/// design in front-end code. Auto layout becomes flexbox; layers in a frame without auto layout or in a group are placed absolutely.
/// Images are written as their own files; icons as SVG (PNG for SF Symbols, which the App rasterizes) drawn through a CSS mask
/// tinted with the icon color, as the canvas does. Effects become CSS as ADR 0012 lays out; noise, textures, shaders, and the
/// glyph-shaped effects CSS cannot draw are noted in an HTML comment before the element. Hidden layers, hidden effects, and
/// prototype settings are left out.
public enum DesignHTML {
    public typealias IconArtwork = (String) -> (data: Data, ext: String)?

    /// Artwork of a bundled icon library; nil for SF Symbols, which only the App can draw.
    public static func bundledIcon(_ name: String) -> (data: Data, ext: String)? { IconCatalog.shared.svg(name).map { ($0, "svg") } }

    /// `lineHeight` gives a text's font's own line height in points, which `text.lineHeight` multiplies on the canvas (unlike
    /// CSS, whose unitless line-height multiplies the font size); without it, the multiple is written unitless.
    public static func export(_ node: DesignNode, iconArtwork: @escaping IconArtwork = bundledIcon,
                              lineHeight: @escaping (DesignText) -> Double? = { _ in nil }) throws -> DesignHTMLExport {
        var writer = Writer(iconArtwork: iconArtwork, naturalLineHeight: lineHeight)
        let body = try writer.element(node, context: .root, depth: 1)
        let html = """
        <!doctype html>
        <!-- Exported from Fudehand as a reference for implementing this design; not production code. -->
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(node.name))</title>
        <style>
        * { box-sizing: border-box; margin: 0; }
        \(writer.rules.joined(separator: "\n"))
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
        var files = writer.files
        files["index.html"] = Data(html.utf8)
        return DesignHTMLExport(html: html, files: files, assets: writer.assets)
    }

    /// Where an element sits: the exported layer itself, in an auto layout parent's flow, or placed absolutely.
    enum Context {
        case root
        case flow(AutoLayout)
        case absolute
    }

    struct Writer {
        let iconArtwork: IconArtwork
        let naturalLineHeight: (DesignText) -> Double?
        var rules: [String] = []
        var files: [String: Data] = [:]
        var assets: [String: String] = [:]
        var usedClasses: Set<String> = []
        var iconPaths: [String: String] = [:]
        var usedIconFiles: Set<String> = []

        mutating func element(_ node: DesignNode, context: Context, depth: Int) throws -> String {
            let indent = String(repeating: "  ", count: depth - 1)
            let name = uniqueClass(node)
            // Reserved before the children are written, so a parent's rule comes before its children's.
            let ruleIndex = rules.count
            rules.append("")
            var css = position(node, context: context)
            css += size(node, context: context)
            css += appearance(node)
            let (effectCSS, notes) = effects(node)
            css += effectCSS
            let open = #"class="\#(name)" data-layer-id="\#(escape(node.id))""#
            let tag: String
            switch node.type {
            case .text:
                css += node.text.map(textStyle) ?? []
                tag = "\(indent)<div \(open)>\(escape(node.text?.content ?? ""))</div>"
            case .image:
                let path = "assets/\(name).\(Self.imageExtension(node.image?.data ?? Data()))"
                files[path] = node.image?.data
                assets[node.id] = path
                css.append("object-fit: \(Self.objectFit(node.image?.fit ?? .fill))")
                tag = #"\#(indent)<img \#(open) src="\#(path)" alt="\#(escape(node.name))">"#
            case .icon:
                let icon = node.icon ?? DesignIcon(name: "")
                let path = try iconPath(icon.name)
                assets[node.id] = path
                if case .flow = context { css.insert("position: relative", at: 0) }
                // The glyph is a pseudo-element, so the layer's own fill and stroke are not clipped to its shape.
                let glyph = ["content: \"\"", "position: absolute", "inset: 0", "background-color: \(Self.color(icon.color))",
                             "mask: url(\(path)) center / contain no-repeat", "-webkit-mask: url(\(path)) center / contain no-repeat"]
                rules.insert(".\(name)::before { \(glyph.map { $0 + ";" }.joined(separator: " ")) }", at: ruleIndex + 1)
                tag = #"\#(indent)<span \#(open) role="img" aria-label="\#(escape(node.name))"></span>"#
            case .frame, .group, .rectangle, .ellipse:
                if let layout = node.layout, node.type == .frame { css += flex(layout) }
                let childContext: Context = node.type == .frame ? node.layout.map(Context.flow) ?? .absolute : .absolute
                let children = try node.children.filter(\.visible).map { try element($0, context: childContext, depth: depth + 1) }
                tag = children.isEmpty ? "\(indent)<div \(open)></div>"
                    : "\(indent)<div \(open)>\n\(children.joined(separator: "\n"))\n\(indent)</div>"
            }
            rules[ruleIndex] = ".\(name) { \(css.map { $0 + ";" }.joined(separator: " ")) }"
            return notes.map { "\(indent)<!-- \($0) -->\n" }.joined() + tag
        }

        func position(_ node: DesignNode, context: Context) -> [String] {
            switch context {
            case .root: return ["position: relative"]
            case .absolute: return ["position: absolute", "left: \(Self.px(node.x))", "top: \(Self.px(node.y))"]
            case .flow: return node.type.hasChildren ? ["position: relative"] : []
            }
        }

        func size(_ node: DesignNode, context: Context) -> [String] {
            var css: [String] = []
            var keepWidth = true, keepHeight = true
            if case .flow = context, node.type == .group { css.append("flex-shrink: 0") }
            if case .flow(let layout) = context, node.type != .group {
                let horizontal = layout.direction == .horizontal
                let primary = horizontal ? node.sizing.horizontal : node.sizing.vertical
                let cross = horizontal ? node.sizing.vertical : node.sizing.horizontal
                if primary == .fill {
                    css += ["flex: 1 1 0", horizontal ? "min-width: 0" : "min-height: 0"]
                    if horizontal { keepWidth = false } else { keepHeight = false }
                } else {
                    // Auto layout never shrinks a child that does not fill; it overflows instead.
                    css.append("flex-shrink: 0")
                }
                if cross == .fill || layout.crossAlign == .stretch {
                    if cross == .fill { css.append("align-self: stretch") }
                    if horizontal { keepHeight = false } else { keepWidth = false }
                }
            }
            if let text = node.text {
                if text.autoResize == .widthAndHeight { keepWidth = false }
                if text.autoResize != .none { keepHeight = false }
            } else if node.type == .frame, node.layout != nil {
                if node.sizing.horizontal == .hug { keepWidth = false }
                if node.sizing.vertical == .hug { keepHeight = false }
            }
            if case .root = context { keepWidth = keepWidth || node.text == nil; keepHeight = keepHeight || node.text == nil }
            if keepWidth { css.append("width: \(Self.px(node.width))") }
            if keepHeight { css.append("height: \(Self.px(node.height))") }
            return css
        }

        func appearance(_ node: DesignNode) -> [String] {
            var css: [String] = []
            // Glass tints are drawn over the fill, so they are background layers above it, the topmost first.
            let tints = node.effects.filter { $0.visible && $0.type == .glass }.reversed().map { effect -> String in
                let tint = Self.color(effect.color)
                return "linear-gradient(\(tint), \(tint))"
            }
            let layers = tints + (node.fill.map { [Self.color($0)] } ?? [])
            if !layers.isEmpty { css.append("background: \(layers.joined(separator: ", "))") }
            if node.type == .ellipse { css.append("border-radius: 50%") }
            else if node.type.hasCornerRadius, node.cornerRadius > 0 { css.append("border-radius: \(Self.px(node.cornerRadius))") }
            // The canvas draws strokes inside the bounds and above the children, which an inset outline matches without moving them.
            if let stroke = node.stroke, stroke.width > 0 {
                css += ["outline: \(Self.px(stroke.width)) solid \(Self.color(stroke.color))", "outline-offset: -\(Self.px(stroke.width))"]
            }
            if node.opacity < 1 { css.append("opacity: \(Self.number(node.opacity))") }
            if node.type == .image || (node.type == .frame && node.clipsContent) { css.append("overflow: hidden") }
            return css
        }

        /// The CSS for a layer's visible effects, and a note for each one CSS cannot draw. Box shadows and background layers list
        /// the topmost first, the reverse of the effects list. Shadow blur in CSS is twice the standard deviation, as
        /// `DesignEffect.radius` is, so it is written unchanged; `blur()` takes the standard deviation, so it is halved.
        func effects(_ node: DesignNode) -> (css: [String], notes: [String]) {
            let glyphs = node.type == .text || node.type == .icon
            var boxShadows: [String] = [], textShadows: [String] = [], dropShadows: [String] = [], blurs: [String] = []
            var backdrops: [String] = [], notes: [String] = [], css: [String] = []
            var transform: String?, perspective: [String] = []
            func shadow(_ effect: DesignEffect, spread: Bool) -> String {
                let parts = [effect.x, effect.y, effect.radius] + (spread ? [effect.spread] : [])
                return (parts.map(Self.px) + [Self.color(effect.color)]).joined(separator: " ")
            }
            func note(_ effect: DesignEffect, _ details: [String]) {
                notes.append("\(effect.type.rawValue) effect: \(details.joined(separator: ", "))")
            }
            for effect in node.effects where effect.visible {
                switch effect.type {
                case .dropShadow:
                    if node.type == .text { textShadows.insert(shadow(effect, spread: false), at: 0) }
                    else if node.type == .icon { dropShadows.append("drop-shadow(\(shadow(effect, spread: false)))") }
                    else { boxShadows.insert(shadow(effect, spread: true), at: 0) }
                case .innerShadow:
                    if glyphs {
                        note(effect, ["color \(Self.color(effect.color))", "x \(Self.number(effect.x))", "y \(Self.number(effect.y))",
                                      "radius \(Self.number(effect.radius))"])
                    } else {
                        boxShadows.insert("inset " + shadow(effect, spread: true), at: 0)
                    }
                case .layerBlur:
                    blurs.append("blur(\(Self.px(effect.radius / 2)))")
                case .backgroundBlur:
                    if glyphs { note(effect, ["radius \(Self.number(effect.radius))"]) }
                    else { backdrops.append("blur(\(Self.px(effect.radius / 2)))") }
                case .glass:
                    backdrops.append("saturate(\(Self.number(effect.saturation))) blur(\(Self.px(effect.radius / 2)))")
                    // The canvas draws a light line just inside the top edge.
                    if effect.highlight > 0 {
                        boxShadows.insert("inset 0 1px 0 rgba(255, 255, 255, \(Self.number(effect.highlight)))", at: 0)
                    }
                case .transform3D:
                    transform = "rotateX(\(Self.number(effect.rotateX))deg) rotateY(\(Self.number(effect.rotateY))deg) translateZ(\(Self.px(effect.translateZ)))"
                case .perspective:
                    perspective = ["perspective: \(Self.px(effect.distance))",
                                   "perspective-origin: \(Self.number(effect.originX * 100))% \(Self.number(effect.originY * 100))%"]
                case .noise:
                    note(effect, ["color \(Self.color(effect.color))", "size \(Self.number(effect.size))",
                                  "density \(Self.number(effect.density))", "seed \(effect.seed)"])
                case .texture:
                    note(effect, ["\(Self.imageExtension(effect.texture ?? Data())) image", "size \(Self.number(effect.size))",
                                  "opacity \(Self.number(effect.opacity))", "blend \(effect.blend.rawValue)"])
                case .shader:
                    let params = effect.shaderParams.sorted { $0.key < $1.key }.map { name, value -> String in
                        switch value {
                        case .number(let number): return "\(name) \(Self.number(number))"
                        case .color(let color): return "\(name) \(Self.color(color))"
                        }
                    }
                    note(effect, [effect.shader] + params + ["opacity \(Self.number(effect.opacity))", "blend \(effect.blend.rawValue)"])
                }
            }
            if !boxShadows.isEmpty { css.append("box-shadow: \(boxShadows.joined(separator: ", "))") }
            if !textShadows.isEmpty { css.append("text-shadow: \(textShadows.joined(separator: ", "))") }
            // Shadows first, so a layer blur also blurs them, as on the canvas.
            if !(dropShadows + blurs).isEmpty { css.append("filter: \((dropShadows + blurs).joined(separator: " "))") }
            if !backdrops.isEmpty { css.append("backdrop-filter: \(backdrops.joined(separator: " "))") }
            if let transform { css.append("transform: \(transform)") }
            return (css + perspective, notes)
        }

        func flex(_ layout: AutoLayout) -> [String] {
            let padding = layout.padding
            let justify: String
            switch layout.align {
            case .start: justify = "flex-start"
            case .center: justify = "center"
            case .end: justify = "flex-end"
            case .spaceBetween: justify = "space-between"
            }
            let items: String
            switch layout.crossAlign {
            case .start: items = "flex-start"
            case .center: items = "center"
            case .end: items = "flex-end"
            case .stretch: items = "stretch"
            }
            let edges = [padding.top, padding.right, padding.bottom, padding.left]
            var css = ["display: flex", "flex-direction: \(layout.direction == .horizontal ? "row" : "column")"]
            if layout.spacing != 0 { css.append("gap: \(Self.px(layout.spacing))") }
            if edges.contains(where: { $0 != 0 }) { css.append("padding: \(edges.map(Self.px).joined(separator: " "))") }
            return css + ["justify-content: \(justify)", "align-items: \(items)"]
        }

        func textStyle(_ text: DesignText) -> [String] {
            let system = "-apple-system, BlinkMacSystemFont, sans-serif"
            // Quotes, backslashes, angle brackets, and control characters could end the CSS string or the style element.
            let safe = text.fontFamily.map { String($0.unicodeScalars.filter { !"\"\\<>".unicodeScalars.contains($0) && $0.properties.generalCategory != .control }) }
            let family = safe.map { "\"\($0)\", \(system)" } ?? system
            return ["font-family: \(family)", "font-size: \(Self.px(text.fontSize))", "font-weight: \(text.fontWeight)",
                    "line-height: \(lineHeight(text))", "color: \(Self.color(text.color))",
                    "text-align: \(text.align.rawValue)", "white-space: \(text.autoResize == .widthAndHeight ? "pre" : "pre-wrap")"]
        }

        func lineHeight(_ text: DesignText) -> String {
            guard let multiple = text.lineHeight else { return "normal" }
            return naturalLineHeight(text).map { Self.px($0 * multiple) } ?? Self.number(multiple)
        }

        mutating func iconPath(_ name: String) throws -> String {
            if let path = iconPaths[name] { return path }
            guard let artwork = iconArtwork(name) else { throw DesignError("No artwork for icon \(name)") }
            var base = "assets/icons/\(slug(name))", counter = 2
            while usedIconFiles.contains(base) { base = "assets/icons/\(slug(name))-\(counter)"; counter += 1 }
            usedIconFiles.insert(base)
            let path = "\(base).\(artwork.ext)"
            files[path] = artwork.data
            iconPaths[name] = path
            return path
        }

        mutating func uniqueClass(_ node: DesignNode) -> String {
            var base = slug(node.name)
            if base.isEmpty { base = node.type.rawValue }
            if base.first?.isNumber == true { base = "layer-" + base }
            var name = base, counter = 2
            while usedClasses.contains(name) { name = "\(base)-\(counter)"; counter += 1 }
            usedClasses.insert(name)
            return name
        }

        func slug(_ text: String) -> String {
            text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.joined(separator: "-")
        }

        static func imageExtension(_ data: Data) -> String {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
            return "svg"
        }

        static func objectFit(_ fit: ImageFit) -> String {
            switch fit {
            case .fill: return "cover"
            case .fit: return "contain"
            case .stretch: return "fill"
            }
        }

        static func color(_ color: DesignColor) -> String {
            let hex = color.hex
            guard hex.count == 9 else { return hex }
            func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            return "rgba(\(byte(color.r)), \(byte(color.g)), \(byte(color.b)), \(number((Double(byte(color.a)) / 255 * 1000).rounded() / 1000)))"
        }

        static func px(_ value: Double) -> String { value == 0 ? "0" : "\(number(value))px" }

        static func number(_ value: Double) -> String {
            let rounded = (value * 1000).rounded() / 1000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
