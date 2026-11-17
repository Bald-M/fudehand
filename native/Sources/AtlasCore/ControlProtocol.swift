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
