public enum ScrollTarget: Equatable { case page, canvas }

public enum ScrollPhase: Equatable { case discrete, began, changed, ended, momentum, momentumEnded }

/// Decides per gesture whether scroll events go to the active web page or the canvas.
/// Scrolling pans the canvas; only the page modifier (⌥) over the active page scrolls the page.
/// The target is chosen when a gesture begins and kept until its momentum ends, so content
/// sliding under the pointer or a modifier change mid-gesture cannot switch it.
public struct ScrollRouter {
    public private(set) var locked: ScrollTarget?
    public init() {}

    public mutating func route(phase: ScrollPhase, overActivePage: Bool, pageModifier: Bool, zoomModifier: Bool) -> ScrollTarget {
        if zoomModifier { return .canvas }
        let fresh: ScrollTarget = overActivePage && pageModifier ? .page : .canvas
        switch phase {
        case .discrete:
            locked = nil
            return fresh
        case .began:
            locked = fresh
            return fresh
        case .changed, .ended, .momentum:
            return locked ?? fresh
        case .momentumEnded:
            let target = locked ?? fresh
            locked = nil
            return target
        }
    }
}
