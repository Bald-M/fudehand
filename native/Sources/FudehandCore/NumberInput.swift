import Foundation

/// Rules for the properties panel's number fields: how a value is displayed and what typed text commits.
public enum NumberInput {
    /// Whole numbers are shown without decimals, everything else with one decimal place.
    public static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// The value to commit when a field showing `current` is submitted with `text`, or nil when there
    /// is nothing to commit: the text is not a finite number, or it does not change the value.
    public static func committedValue(text: String, current: Double, minimum: Double? = nil, maximum: Double? = nil) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // The displayed text is rounded, so text left as displayed must not round the stored value.
        guard trimmed != format(current), let number = Double(trimmed), number.isFinite else { return nil }
        let limit = DesignJSON.maximumMagnitude
        let clamped = min(maximum ?? limit, max(minimum ?? -limit, number))
        return clamped == current ? nil : clamped
    }

    /// Whether a field's `text` holds something the person typed, rather than `value` as the field displays it. A field that
    /// is not a draft follows outside changes to its value even while focused, so leaving it never commits a stale value.
    public static func isDraft(_ text: String, showing value: Double, percent: Bool = false) -> Bool {
        text != (percent ? formatPercent(value) : format(value))
    }

    /// A 0–1 fraction shown as a percentage, such as an opacity.
    public static func formatPercent(_ fraction: Double) -> String { format(fraction * 100) + "%" }

    /// The 0–1 fraction to commit for typed percentage `text` (the `%` is optional), with the rules of `committedValue`.
    public static func committedPercent(text: String, current: Double) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { trimmed.removeLast() }
        return committedValue(text: trimmed, current: current * 100, minimum: 0, maximum: 100).map { $0 / 100 }
    }
}
