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

    static let measure: TextMeasure = { text, maxWidth in
        let key = MeasureKey(text: text, maxWidth: maxWidth)
        if let hit = cache[key] { return hit }
        let size = uncachedMeasure(text, maxWidth)
        if cache.count >= 5000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = size
        return size
    }

    private static func uncachedMeasure(_ text: DesignText, _ maxWidth: Double?) -> Size {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text))
        let constraint = CGSize(width: maxWidth.map { CGFloat(max($0, 1)) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, nil)
        return Size(width: Double(size.width.rounded(.up)), height: Double(size.height.rounded(.up)))
    }
}

/// A layer that draws text with CoreText, using the same typesetting as `TextMetrics.measure`.
final class TextLayer: CALayer {
    var attributed = NSAttributedString() { didSet { setNeedsDisplay() } }
    /// An offscreen snapshot draws the whole layer tree into a vertically flipped bitmap, which turns the text bitmap upside down with it; it is drawn reversed in advance when snapshotting.
    var invertedForSnapshot = false { didSet { setNeedsDisplay() } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        attributed = (layer as? TextLayer)?.attributed ?? NSAttributedString()
        invertedForSnapshot = (layer as? TextLayer)?.invertedForSnapshot ?? false
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(in context: CGContext) {
        context.saveGState()
        // CoreText typesets with a bottom-left origin and y pointing up; a vertically flipped context (a layer with flipped geometry, the flipped bitmap used for snapshots) is flipped back first.
        if (context.ctm.d < 0) != invertedForSnapshot {
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
