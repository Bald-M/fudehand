/// What a pointer press on a layers-panel row does. Rows act on press rather than on a tap, so selecting
/// never waits for the double-click interval.
public enum LayerRowPress: Equatable {
    case select(Set<String>)
    case rename

    /// ⌘ adds to or removes from the selection, Shift adds to it, a plain press selects one layer;
    /// the second press of a plain double-click renames.
    public static func resolve(id: String, selection: Set<String>, clickCount: Int,
                               command: Bool = false, shift: Bool = false) -> LayerRowPress {
        if command { return .select(selection.symmetricDifference([id])) }
        if shift { return .select(selection.union([id])) }
        return clickCount == 2 ? .rename : .select([id])
    }
}
