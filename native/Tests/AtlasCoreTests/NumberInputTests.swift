import Testing
import AtlasCore

@Test func numberInputLeftAsDisplayedCommitsNothing() {
    // The field shows one decimal place; blurring it untouched must not round the stored value (#57).
    #expect(NumberInput.format(123.4567) == "123.5")
    #expect(NumberInput.committedValue(text: "123.5", current: 123.4567) == nil)
    #expect(NumberInput.committedValue(text: " 123.5 ", current: 123.4567) == nil)
    #expect(NumberInput.committedValue(text: "40", current: 40) == nil)
    #expect(NumberInput.committedValue(text: "40.0", current: 40) == nil)
}

@Test func numberInputCommitsATypedValueWithinLimits() {
    #expect(NumberInput.committedValue(text: "123.4", current: 123.4567) == 123.4)
    #expect(NumberInput.committedValue(text: "124", current: 123.4567) == 124)
    #expect(NumberInput.committedValue(text: "-5", current: 3, minimum: 0) == 0)
    #expect(NumberInput.committedValue(text: "-5", current: 0, minimum: 0) == nil)
    #expect(NumberInput.committedValue(text: "5000000", current: 3) == DesignJSON.maximumMagnitude)
    #expect(NumberInput.committedValue(text: "-5000000", current: 3) == -DesignJSON.maximumMagnitude)
}

@Test func numberInputIgnoresTextThatIsNotAFiniteNumber() {
    #expect(NumberInput.committedValue(text: "", current: 3) == nil)
    #expect(NumberInput.committedValue(text: "abc", current: 3) == nil)
    #expect(NumberInput.committedValue(text: "inf", current: 3) == nil)
    #expect(NumberInput.committedValue(text: "nan", current: 3) == nil)
}
