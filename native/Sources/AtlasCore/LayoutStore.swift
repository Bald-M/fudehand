import Foundation
import CoreFoundation

public struct Layout: Codable, Equatable {
    public var layoutVersion: Int
    public var viewport: Viewport
    public var positions: [String: Point]

    public init(layoutVersion: Int, viewport: Viewport, positions: [String: Point]) {
        self.layoutVersion = layoutVersion
        self.viewport = viewport
        self.positions = positions
    }
}

public final class LayoutStore {
    private let defaults: UserDefaults
    private let namespace: String

    public init(defaults: UserDefaults, namespace: String) {
        self.defaults = defaults
        self.namespace = namespace
    }

    public static func defaultPositions(_ project: Project) -> [String: Point] {
        Dictionary(uniqueKeysWithValues: project.frames.map { ($0.id, Point(x: $0.x, y: $0.y)) })
    }

    public func load(project: Project) -> Layout? {
        guard let data = defaults.data(forKey: key(project)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              number(raw["layoutVersion"]) == Double(project.layoutVersion),
              let view = raw["viewport"] as? [String: Any],
              let x = number(view["x"]), let y = number(view["y"]),
              let scale = number(view["scale"]),
              (CanvasGeometry.minScale...CanvasGeometry.maxScale).contains(scale),
              let saved = raw["positions"] as? [String: Any] else { return nil }
        var positions = Self.defaultPositions(project)
        for frame in project.frames {
            guard let value = saved[frame.id] else { continue }
            guard let point = value as? [String: Any],
                  let px = number(point["x"]), let py = number(point["y"]) else { return nil }
            positions[frame.id] = Point(x: px, y: py)
        }
        return Layout(layoutVersion: project.layoutVersion,
                      viewport: Viewport(x: x, y: y, scale: scale), positions: positions)
    }

    private func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    public func save(_ layout: Layout, project: Project) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: key(project))
    }

    public func clear(project: Project) { defaults.removeObject(forKey: key(project)) }
    private func key(_ project: Project) -> String { namespace + ".layout." + project.id }
}
