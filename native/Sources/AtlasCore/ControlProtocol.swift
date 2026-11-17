import Foundation

/// 控制通道的命令：外部进程经本地 Unix socket 操作正在运行的 App。
public enum ControlCommand: Equatable, Sendable {
    case getState
    case selectProject(String)
    case focusFrame(String)
    case fitAll
    case zoom(Double)
    case reset
    case restartPreview
    case frameSnapshot(String)
    case frameConsole(String, limit: Int)
    case frameRead(String)
    case frameInteract(String, FrameAction)
}

/// 画框内的基础交互，只作用于该画框已加载的本机预览页面。
public enum FrameAction: Equatable, Sendable {
    case click(selector: String)
    case fill(selector: String, value: String)
    /// 给了 selector 时把元素滚动到可见区域，否则按 deltaX、deltaY 滚动页面。
    case scroll(selector: String?, deltaX: Double, deltaY: Double)
}

/// 请求 id 原样回传，便于调用方匹配响应。
public enum ControlID: Equatable, Sendable {
    case int(Int)
    case string(String)

    var json: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }
}

public struct ControlRequest: Equatable, Sendable {
    public let id: ControlID?
    public let command: ControlCommand
}

public struct ControlFailure: Error, Equatable, Sendable {
    public let id: ControlID?
    public let message: String

    public init(id: ControlID?, message: String) {
        self.id = id; self.message = message
    }
}

/// 行分隔 JSON：请求 `{"id":1,"command":"focus_frame","args":{"frame":"mobile"}}`，
/// 响应 `{"id":1,"ok":true,"result":…}` 或 `{"id":1,"ok":false,"error":"…"}`。
public enum ControlProtocol {
    public static func parse(_ line: Data) -> Result<ControlRequest, ControlFailure> {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .failure(ControlFailure(id: nil, message: "请求不是有效 JSON"))
        }
        let id: ControlID? = (object["id"] as? String).map(ControlID.string) ?? integer(object["id"]).map(ControlID.int)
        do {
            return .success(ControlRequest(id: id, command: try command(object)))
        } catch let message as Message {
            return .failure(ControlFailure(id: id, message: message.text))
        } catch {
            return .failure(ControlFailure(id: id, message: "\(error)"))
        }
    }

    public static func success(id: ControlID?, result: Any) -> Data {
        line(["id": id?.json ?? NSNull(), "ok": true, "result": result])
    }

    public static func failure(id: ControlID?, message: String) -> Data {
        line(["id": id?.json ?? NSNull(), "ok": false, "error": message])
    }

    private struct Message: Error { let text: String }

    private static func command(_ object: [String: Any]) throws -> ControlCommand {
        guard let name = object["command"] else { throw Message(text: "缺少参数：command") }
        guard let name = name as? String else { throw Message(text: "参数类型错误：command") }
        let args: [String: Any]
        switch object["args"] {
        case nil, is NSNull: args = [:]
        case let value as [String: Any]: args = value
        default: throw Message(text: "参数类型错误：args")
        }
        func string(_ key: String) throws -> String {
            guard let value = args[key] else { throw Message(text: "缺少参数：\(key)") }
            guard let text = value as? String, !text.isEmpty else { throw Message(text: "参数类型错误：\(key)") }
            return text
        }
        switch name {
        case "get_state": return .getState
        case "select_project": return .selectProject(try string("project"))
        case "focus_frame": return .focusFrame(try string("frame"))
        case "fit_all": return .fitAll
        case "zoom":
            guard let value = args["scale"] else { throw Message(text: "缺少参数：scale") }
            guard let number = value as? NSNumber, !isBool(number), number.doubleValue.isFinite, number.doubleValue > 0 else {
                throw Message(text: "参数类型错误：scale")
            }
            return .zoom(number.doubleValue)
        case "reset": return .reset
        case "restart_preview": return .restartPreview
        case "frame_snapshot": return .frameSnapshot(try string("frame"))
        case "frame_console":
            let frame = try string("frame")
            guard let value = args["limit"] else { return .frameConsole(frame, limit: 50) }
            guard let limit = integer(value), (1...200).contains(limit) else { throw Message(text: "参数类型错误：limit") }
            return .frameConsole(frame, limit: limit)
        case "frame_read": return .frameRead(try string("frame"))
        case "frame_interact":
            let frame = try string("frame")
            let action = try string("action")
            switch action {
            case "click": return .frameInteract(frame, .click(selector: try string("selector")))
            case "fill":
                let selector = try string("selector")
                guard let value = args["value"] else { throw Message(text: "缺少参数：value") }
                guard let text = value as? String else { throw Message(text: "参数类型错误：value") }
                return .frameInteract(frame, .fill(selector: selector, value: text))
            case "scroll":
                func delta(_ key: String) throws -> Double? {
                    guard let value = args[key] else { return nil }
                    guard let number = value as? NSNumber, !isBool(number), number.doubleValue.isFinite else {
                        throw Message(text: "参数类型错误：\(key)")
                    }
                    return number.doubleValue
                }
                let selector = args["selector"] == nil ? nil : try string("selector")
                let deltaX = try delta("deltaX"), deltaY = try delta("deltaY")
                guard selector != nil || deltaX != nil || deltaY != nil else {
                    throw Message(text: "缺少参数：selector 或 deltaX、deltaY")
                }
                return .frameInteract(frame, .scroll(selector: selector, deltaX: deltaX ?? 0, deltaY: deltaY ?? 0))
            default: throw Message(text: "不支持的操作：\(action)")
            }
        default: throw Message(text: "未知命令：\(name)")
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func line(_ object: [String: Any]) -> Data {
        // JSONSerialization escapes newlines inside strings, so each response stays on one line.
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false,"error":"响应无法编码"}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
