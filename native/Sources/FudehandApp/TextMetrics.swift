import AppKit
import FudehandCore
import CoreText

/// The font, typesetting, and measurement of text; rendering and layout use the same attributes, so measurements match what is drawn.
enum TextMetrics {
    static func weight(_ value: Int) -> NSFont.Weight {
        switch value {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    static func font(_ text: DesignText) -> NSFont {
        let size = CGFloat(text.fontSize)
        let fontWeight = weight(text.fontWeight)
        if let family = text.fontFamily {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: fontWeight]])
            if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family { return font }
        }
        return .systemFont(ofSize: size, weight: fontWeight)
    }

    /// The font's own line height, which `lineHeightMultiple` multiplies.
    static func naturalLineHeight(_ text: DesignText) -> Double? {
        Double(NSLayoutManager().defaultLineHeight(for: font(text)))
    }

    static func attributed(_ text: DesignText) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.align == .center ? .center : text.align == .right ? .right : .left
        paragraph.lineBreakMode = .byWordWrapping
        if let lineHeight = text.lineHeight { paragraph.lineHeightMultiple = CGFloat(lineHeight) }
        let color = NSColor(srgbRed: text.color.r, green: text.color.g, blue: text.color.b, alpha: text.color.a)
        // Empty text still needs one line of height so it can be selected on the canvas.
        return NSAttributedString(string: text.content.isEmpty ? " " : text.content,
                                  attributes: [.font: font(text), .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private struct MeasureKey: Hashable { let text: DesignText; let maxWidth: Double? }
    /// Layout measures all text again after every edit; the same text and width reuse the result directly. Used on the main thread only.
    nonisolated(unsafe) private static var cache: [MeasureKey: Size] = [:]
    /// Large enough for every text of a document of tens of thousands of layers, so laying it out again finds them all (#248).
    static let maximumCached = 50_000
    /// Measurements not found in the cache, for tests.
    nonisolated(unsafe) private(set) static var misses = 0

    /// Forgets the measurements, which no longer hold once the available fonts change.
    static func resetCache() { cache.removeAll(keepingCapacity: true) }

    static let measure: TextMeasure = { text, maxWidth in
        let key = MeasureKey(text: text, maxWidth: maxWidth)
        if let hit = cache[key] { return hit }
        misses += 1
        let size = uncachedMeasure(attributed(text), maxWidth)
        store(key, size)
        return size
    }

    private static func store(_ key: MeasureKey, _ size: Size) {
        if cache.count >= maximumCached { cache.removeAll(keepingCapacity: true) }
        cache[key] = size
    }

    /// Measures what laying out `nodes` asks for first (see `DesignLayout.textRequests`), spread over the CPU cores, so
    /// opening a document with thousands of distinct texts does not measure them one at a time on the main thread (#248).
    /// The attributed strings are made here, on the main thread; CoreText sizes them in parallel.
    @MainActor static func prewarm(_ nodes: [DesignNode]) {
        let requests = DesignLayout.textRequests(nodes).filter { cache[MeasureKey(text: $0.text, maxWidth: $0.width)] == nil }
        guard !requests.isEmpty else { return }
        let strings = requests.map { attributed($0.text) }
        var sizes = [(natural: Size?, height: Size?)](repeating: (nil, nil), count: requests.count)
        sizes.withUnsafeMutableBufferPointer { sizes in
            nonisolated(unsafe) let sizes = sizes
            DispatchQueue.concurrentPerform(iterations: requests.count) { index in
                let request = requests[index], string = strings[index]
                let natural = request.width == nil ? uncachedMeasure(string, nil) : nil
                let height = request.height ? uncachedMeasure(string, natural?.width ?? request.width) : nil
                sizes[index] = (natural, height)
            }
        }
        for (request, size) in zip(requests, sizes) {
            if let natural = size.natural { store(MeasureKey(text: request.text, maxWidth: nil), natural) }
            if let height = size.height {
                store(MeasureKey(text: request.text, maxWidth: size.natural?.width ?? request.width), height)
            }
        }
    }

    private static func uncachedMeasure(_ string: NSAttributedString, _ maxWidth: Double?) -> Size {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let constraint = CGSize(width: maxWidth.map { CGFloat(max($0, 1)) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, nil)
        return Size(width: Double(size.width.rounded(.up)), height: Double(size.height.rounded(.up)))
    }
}

/// A layer that draws text with CoreText, using the same typesetting as `TextMetrics.measure`.
final class TextLayer: CALayer {
    var attributed = NSAttributedString() { didSet { setNeedsDisplay() } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        attributed = (layer as? TextLayer)?.attributed ?? NSAttributedString()
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(in context: CGContext) {
        context.saveGState()
        // CoreText typesets with a bottom-left origin and y pointing up; a vertically flipped context (a layer with flipped geometry) is flipped back first.
        if context.ctm.d < 0 {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Leave a margin so the rounded width does not make the last character wrap.
        let path = CGPath(rect: CGRect(x: 0, y: bounds.height - 10_000, width: bounds.width + 0.5, height: 10_000), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        context.restoreGState()
    }
}
