/// The grain pattern of a noise effect: a square of `side` × `side` cells, repeated across the layer from its top-left corner,
/// one cell per grain of the effect's size. Each cell comes from a hash of the seed and the cell's position, so the same
/// effect draws the same grains on the canvas, in snapshots, after reopening the file, and on another Mac.
public enum NoiseTile {
    public static let side = 256

    /// The cells row by row from the top: 0 where there is no grain, otherwise the grain's strength from 1 to 255, which
    /// scales the effect color's alpha. A cell has a grain when its hash falls below `density`, so a denser tile keeps the
    /// grains of a sparser one with the same seed.
    public static func cells(density: Double, seed: Int) -> [UInt8] {
        var cells = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let hash = mix(UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(y * side + x))
                // The top 32 bits decide whether there is a grain, the bottom 8 how strong it is (at least a quarter).
                let chance = Double(hash >> 32) / Double(UInt64(1) << 32)
                guard chance < density else { continue }
                cells[y * side + x] = UInt8(64 + (hash & 0xFF) * 191 / 255)
            }
        }
        return cells
    }

    /// SplitMix64's finalizer: spreads every input bit over the whole output.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
