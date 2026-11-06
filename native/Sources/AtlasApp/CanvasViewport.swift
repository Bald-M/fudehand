import AppKit
import AtlasCore

/// Counts display-link frames and those whose interval exceeds 25ms; reports once per second.
struct FrameIntervalLog {
    static let hitchThreshold = 0.025
    private var last: CFTimeInterval?
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0

    /// Records one frame timestamp; returns the report line when a second has elapsed.
    mutating func record(_ timestamp: CFTimeInterval) -> String? {
        guard let last else {
            self.last = timestamp
            windowStart = timestamp
            return nil
        }
        self.last = timestamp
        frames += 1
        if timestamp - last > Self.hitchThreshold { hitches += 1 }
        guard timestamp - windowStart >= 1 else { return nil }
        defer { windowStart = timestamp; frames = 0; hitches = 0 }
        return "[frame] hitches=\(hitches) frames=\(frames)"
    }
}

extension AtlasCanvasView {
    static let frameLogEnabled = ProcessInfo.processInfo.environment["UI_ATLAS_FRAME_LOG"] == "1"

    /// Runs the display link only while something needs it, and only in a window.
    func updateDisplayLink() {
        let needed = window != nil && Self.frameLogEnabled
        if needed, activeDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            activeDisplayLink = link
            frameLog = FrameIntervalLog()
        } else if !needed, let link = activeDisplayLink {
            link.invalidate()
            activeDisplayLink = nil
        }
    }

    func stopDisplayLink() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if Self.frameLogEnabled, let line = frameLog.record(link.timestamp) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }
}
