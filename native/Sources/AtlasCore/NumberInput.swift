import Foundation

/// Rules for the properties panel's number fields: how a value is displayed and what typed text commits.
public enum NumberInput {
    /// Whole numbers are shown without decimals, everything else with one decimal place.
    public static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// The value to commit when a field showing `current` is submitted with `text`, or nil when there
    /// is nothing to commit: the text is not a finite number, or it does not change the value.
    public static func committedValue(text: String, current: Double, minimum: Double? = nil) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // The displayed text is rounded, so text left as displayed must not round the stored value.
        guard trimmed != format(current), let number = Double(trimmed), number.isFinite else { return nil }
        let limit = DesignJSON.maximumMagnitude
        let clamped = min(limit, max(minimum ?? -limit, number))
        return clamped == current ? nil : clamped
    }
}
