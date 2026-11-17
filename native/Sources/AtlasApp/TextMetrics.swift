import AppKit
import AtlasCore
import CoreText

/// 文字的字体、排版与测量；渲染与布局用同一份属性，保证测量结果与绘制一致。
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
        // 空文字也要有一行高度，便于在画布上选中。
        return NSAttributedString(string: text.content.isEmpty ? " " : text.content,
                                  attributes: [.font: font(text), .foregroundColor: color, .paragraphStyle: paragraph])
    }

    static let measure: TextMeasure = { text, maxWidth in
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text))
        let constraint = CGSize(width: maxWidth.map { CGFloat(max($0, 1)) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, nil)
        return Size(width: Double(size.width.rounded(.up)), height: Double(size.height.rounded(.up)))
    }
}

/// 用 CoreText 绘制文字的图层，与 `TextMetrics.measure` 使用同一排版。
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
        // CoreText 以左下角为原点；图层在翻转的几何中时上下颠倒绘制。
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        // 再翻回 CoreText 的坐标系：文字从顶部开始排。
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // 留出余量，避免取整后的宽度让最后一个字换行。
        let path = CGPath(rect: CGRect(x: 0, y: -10_000, width: bounds.width + 0.5, height: bounds.height + 10_000), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        context.restoreGState()
    }
}
