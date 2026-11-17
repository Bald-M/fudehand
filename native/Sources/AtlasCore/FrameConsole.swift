import Foundation

/// 画框网页的一条控制台记录。`source` 为 console（console.*）、exception（未捕获错误）或 atlas（界面图鉴自己的分界记录）。
public struct ConsoleEntry: Equatable, Sendable {
    public let level: String
    public let source: String
    public let message: String
    public let time: Date

    /// 控制通道的 JSON 形式；time 为毫秒时间戳。
    public var json: [String: Any] {
        ["level": level, "source": source, "message": message, "time": (time.timeIntervalSince1970 * 1000).rounded()]
    }
}

/// 每个画框最近的控制台记录，超出容量时丢弃最早的。存在原生侧，网页重载后仍保留。
public struct FrameConsole: Sendable {
    public let capacity: Int
    public let maximumLength: Int
    public private(set) var dropped = 0
    private var entries: [ConsoleEntry] = []

    public init(capacity: Int = 200, maximumLength: Int = 2000) {
        self.capacity = capacity
        self.maximumLength = maximumLength
    }

    public mutating func append(level: String, source: String, message: String, time: Date = Date()) {
        let text = message.count > maximumLength ? String(message.prefix(maximumLength)) + "…" : message
        entries.append(ConsoleEntry(level: level, source: source, message: text, time: time))
        if entries.count > capacity {
            dropped += entries.count - capacity
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 最近的 `limit` 条，按时间先后排列。
    public func recent(_ limit: Int) -> [ConsoleEntry] {
        Array(entries.suffix(max(0, limit)))
    }
}
