import Foundation

/// What makes an image layer a version snapshot: the frame it was taken of, when, and an optional note. The picture itself is
/// the image layer's data, a read-only render of the frame at that moment (ADR 0010).
public struct VersionSnapshot: Equatable, Sendable {
    /// The id of the frame the snapshot was taken of; the frame may since have been deleted.
    public var frame: String
    /// Whole seconds, so the value survives a round trip through the project file unchanged.
    public var createdAt: Date
    public var note: String

    public init(frame: String, createdAt: Date, note: String = "") {
        self.frame = frame
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.note = note
    }

    /// The space between a frame and the snapshot placed beside it, and between successive snapshots.
    public static let gap = 40.0
    /// The pixel scale a snapshot is rendered at.
    public static let scale = 2.0
    /// The longest side of a snapshot's picture in pixels, the same cap as bitmaps on the canvas; a larger frame renders at a lower scale.
    public static let maximumPixels = 8_192.0

    /// `createdAt` as written in the project file and returned to the Agent: ISO 8601 in UTC, e.g. `2026-11-20T09:30:00Z`.
    public var timestamp: String { Self.formatter.string(from: createdAt) }

    static func date(_ text: String) -> Date? { formatter.date(from: text) }

    private static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// The top-level image layer holding a new snapshot of `frame`: the frame's size, placed beside it (see `besidePosition`).
    /// Nil when the frame is not in the document.
    public static func layer(id: String, of frame: DesignNode, png: Data, in document: DesignDocument,
                             note: String = "", at date: Date = Date()) -> DesignNode? {
        guard let position = besidePosition(of: frame.id, in: document) else { return nil }
        var node = DesignNode(id: id, type: .image, name: L("%@ Snapshot", frame.name), x: position.x, y: position.y,
                              width: frame.width, height: frame.height)
        node.image = DesignImage(data: png, fit: .stretch)
        node.versionSnapshot = VersionSnapshot(frame: frame.id, createdAt: date, note: note)
        return node
    }

    /// Where a snapshot of `frame` goes beside it on the canvas: to the right of the frame's top-level layer (so a nested frame's
    /// snapshot does not cover its screen) and of the other snapshots of it (all but `excluding`), top-aligned with the frame. Nil when
    /// the frame is not in the document.
    public static func besidePosition(of frame: String, excluding: String? = nil, in document: DesignDocument) -> Point? {
        guard let rect = document.worldRect(frame), let top = document.ancestry(of: frame).first, let screen = document.worldRect(top)
        else { return nil }
        let right = document.versionSnapshots(of: frame).filter { $0.id != excluding }
            .compactMap { document.worldRect($0.id) }.map(\.maxX).reduce(screen.maxX, max)
        return Point(x: right + gap, y: rect.y)
    }
}

extension DesignDocument {
    /// The version snapshots in the document, in layer order; only those taken of `frame` when it is given.
    public func versionSnapshots(of frame: String? = nil) -> [DesignNode] {
        var result: [DesignNode] = []
        forEach { node in
            if let snapshot = node.versionSnapshot, frame == nil || snapshot.frame == frame { result.append(node) }
        }
        return result
    }
}
