import Testing
import FudehandCore

@Test func gridCellsMapToMainAndCrossAxisByDirection() {
    // Rows run top to bottom, columns left to right; a horizontal layout's main axis is the columns.
    let horizontal = AlignmentGrid.choosing(row: 2, column: 1, in: AutoLayout(direction: .horizontal))
    #expect(horizontal.align == .center && horizontal.crossAlign == .end)
    let vertical = AlignmentGrid.choosing(row: 2, column: 1, in: AutoLayout(direction: .vertical))
    #expect(vertical.align == .end && vertical.crossAlign == .center)
}

@Test func gridHighlightsTheCellOfTheCurrentAlignment() {
    let layout = AutoLayout(direction: .horizontal, align: .end, crossAlign: .center)
    let selected = (0..<3).flatMap { row in (0..<3).map { (row, $0) } }.filter { AlignmentGrid.isSelected(row: $0.0, column: $0.1, in: layout) }
    #expect(selected.map { [$0.0, $0.1] } == [[1, 2]])
}

@Test func spaceBetweenHoldsTheMainAxisAndAGridClickSetsOnlyTheCrossAxis() {
    let on = AlignmentGrid.settingSpaceBetween(true, in: AutoLayout(direction: .vertical, align: .center, crossAlign: .start))
    #expect(on.align == .spaceBetween)
    let clicked = AlignmentGrid.choosing(row: 0, column: 2, in: on)
    #expect(clicked.align == .spaceBetween && clicked.crossAlign == .end)
    // The whole main-axis line of the cross alignment is highlighted: a vertical layout's column.
    #expect(AlignmentGrid.isSelected(row: 0, column: 2, in: clicked) && AlignmentGrid.isSelected(row: 2, column: 2, in: clicked))
    #expect(!AlignmentGrid.isSelected(row: 0, column: 0, in: clicked))
    #expect(AlignmentGrid.settingSpaceBetween(false, in: clicked).align == .start)
}

@Test func stretchHoldsTheCrossAxisAndAGridClickSetsOnlyTheMainAxis() {
    let on = AlignmentGrid.settingStretch(true, in: AutoLayout(direction: .horizontal, align: .start, crossAlign: .center))
    #expect(on.crossAlign == .stretch)
    let clicked = AlignmentGrid.choosing(row: 0, column: 2, in: on)
    #expect(clicked.align == .end && clicked.crossAlign == .stretch)
    #expect(AlignmentGrid.isSelected(row: 0, column: 2, in: clicked) && AlignmentGrid.isSelected(row: 2, column: 2, in: clicked))
    #expect(AlignmentGrid.settingStretch(false, in: clicked).crossAlign == .start)
}

@Test func gridIsUnavailableWhenBothAxesAreHeld() {
    let both = AutoLayout(direction: .horizontal, align: .spaceBetween, crossAlign: .stretch)
    #expect(!AlignmentGrid.isAvailable(both))
    #expect(AlignmentGrid.choosing(row: 1, column: 1, in: both) == both)
    #expect(AlignmentGrid.isAvailable(AutoLayout(align: .spaceBetween)))
}

@Test func hexInputKeepsTheAlphaUnlessItIsTyped() throws {
    let current = DesignColor(r: 1, g: 1, b: 1, a: 0.5)
    #expect(HexInput.text(current) == "FFFFFF")
    #expect(HexInput.committedColor(text: "ff0000", current: current) == DesignColor(r: 1, g: 0, b: 0, a: 0.5))
    #expect(HexInput.committedColor(text: " #00FF00 ", current: current) == DesignColor(r: 0, g: 1, b: 0, a: 0.5))
    let typed = try DesignColor(hex: "#0000FF80")
    #expect(HexInput.committedColor(text: "0000FF80", current: current) == typed)
    #expect(HexInput.committedColor(text: "FFFFFF", current: current) == nil)
    #expect(HexInput.committedColor(text: "xyz", current: current) == nil)
    #expect(HexInput.committedColor(text: "FFF", current: current) == nil)
}

@Test func percentInputShowsAndCommitsAFraction() {
    #expect(NumberInput.formatPercent(1) == "100%")
    #expect(NumberInput.formatPercent(0.125) == "12.5%")
    #expect(NumberInput.committedPercent(text: "50", current: 1) == 0.5)
    #expect(NumberInput.committedPercent(text: "50 %", current: 1) == 0.5)
    #expect(NumberInput.committedPercent(text: "100%", current: 1) == nil)
    #expect(NumberInput.committedPercent(text: "140", current: 0.5) == 1)
    #expect(NumberInput.committedPercent(text: "-3", current: 0.5) == 0)
    #expect(NumberInput.committedPercent(text: "half", current: 0.5) == nil)
}

@Test func numberInputClampsToAMaximum() {
    #expect(NumberInput.committedValue(text: "12", current: 3, minimum: 0, maximum: 10) == 10)
    #expect(NumberInput.committedValue(text: "12", current: 10, minimum: 0, maximum: 10) == nil)
}
