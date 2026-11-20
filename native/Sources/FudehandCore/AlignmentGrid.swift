import Foundation

/// The properties panel's 3×3 auto layout alignment grid. Rows run top to bottom and columns left to right; a cell sets
/// the main-axis `align` and the cross-axis `crossAlign` together. *Space between* holds the main axis and *Stretch* the
/// cross axis: while one is on, a cell click sets only the other axis, and with both on the grid is unavailable.
public enum AlignmentGrid {
    private static let mainPositions: [LayoutAlign] = [.start, .center, .end]
    private static let crossPositions: [LayoutCrossAlign] = [.start, .center, .end]

    /// The (main, cross) indices of a cell for the layout's direction.
    private static func axes(row: Int, column: Int, _ direction: LayoutDirection) -> (main: Int, cross: Int) {
        direction == .horizontal ? (column, row) : (row, column)
    }

    public static func isAvailable(_ layout: AutoLayout) -> Bool {
        layout.align != .spaceBetween || layout.crossAlign != .stretch
    }

    /// Whether the cell is highlighted: it matches every axis that is not held, so a held axis highlights a whole line.
    public static func isSelected(row: Int, column: Int, in layout: AutoLayout) -> Bool {
        let (main, cross) = axes(row: row, column: column, layout.direction)
        let mainMatches = layout.align == .spaceBetween || mainPositions[main] == layout.align
        let crossMatches = layout.crossAlign == .stretch || crossPositions[cross] == layout.crossAlign
        return mainMatches && crossMatches
    }

    /// The layout after clicking the cell.
    public static func choosing(row: Int, column: Int, in layout: AutoLayout) -> AutoLayout {
        let (main, cross) = axes(row: row, column: column, layout.direction)
        var next = layout
        if layout.align != .spaceBetween { next.align = mainPositions[main] }
        if layout.crossAlign != .stretch { next.crossAlign = crossPositions[cross] }
        return next
    }

    /// Turning *Space between* off returns the main axis to start.
    public static func settingSpaceBetween(_ on: Bool, in layout: AutoLayout) -> AutoLayout {
        var next = layout
        next.align = on ? .spaceBetween : .start
        return next
    }

    /// Turning *Stretch* off returns the cross axis to start.
    public static func settingStretch(_ on: Bool, in layout: AutoLayout) -> AutoLayout {
        var next = layout
        next.crossAlign = on ? .stretch : .start
        return next
    }
}

/// Rules for the properties panel's color fields: the hex shows six digits and the alpha is a separate opacity field.
public enum HexInput {
    public static func text(_ color: DesignColor) -> String { String(color.hex.dropFirst().prefix(6)) }

    /// The color to commit for typed `text`, or nil when it is not a color or changes nothing. Six digits keep the current
    /// alpha; eight digits set it too. A leading `#` is optional.
    public static func committedColor(text: String, current: DesignColor) -> DesignColor? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard var color = try? DesignColor(hex: "#" + digits) else { return nil }
        if digits.count == 6 { color.a = current.a }
        return color.hex == current.hex ? nil : color
    }
}
