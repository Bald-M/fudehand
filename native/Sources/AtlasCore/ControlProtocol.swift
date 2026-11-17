import Foundation

/// 控制通道的命令：外部进程经本地 Unix socket 读取和编辑正在运行的 App 中的设计文档。
public enum ControlCommand: Equatable, Sendable {
    case getState
    case getDocument
    case getNode(String)
    case createNode(parent: String?, index: Int?, node: JSONObject)
    case updateNode(String, changes: JSONObject)
    case deleteNodes([String])
    case moveNode(String, parent: String?, index: Int?)
    case select([String])
    case undo
    case redo
    case newDocument(discard: Bool)
    case openDocument(String, discard: Bool)
    case saveDocument(String?)
    case focusNode(String)
    case fitAll
    case zoom(Double)
    case nodeSnapshot(String, scale: Double)
}

/// 原样携带的 JSON 对象（图层定义或字段补丁），由 `DesignJSON` 校验。
public struct JSONObject: Equatable, @unchecked Sendable {
    public let value: [String: Any]
    public init(_ value: [String: Any]) { self.value = value }
    public static func == (a: JSONObject, b: JSONObject) -> Bool { NSDictionary(dictionary: a.value).isEqual(to: b.value) }
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

/// 行分隔 JSON：请求 `{"id":1,"command":"focus_node","args":{"id":"home"}}`，
/// 响应 `{"id":1,"ok":true,"result":…}` 或 `{"id":1,"ok":false,"error":"…"}`。
public enum ControlProtocol {
    public static func parse(_ line: Data) -> Result<ControlRequest, ControlFailure> {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .failure(ControlFailure(id: nil, message: "Request is not valid JSON"))
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
        guard let name = object["command"] else { throw Message(text: "Missing argument: command") }
        guard let name = name as? String else { throw Message(text: "Invalid argument type: command") }
        let args: [String: Any]
        switch object["args"] {
        case nil, is NSNull: args = [:]
        case let value as [String: Any]: args = value
        default: throw Message(text: "Invalid argument type: args")
        }
        func string(_ key: String) throws -> String {
            guard let value = args[key] else { throw Message(text: "Missing argument: \(key)") }
            guard let text = value as? String, !text.isEmpty else { throw Message(text: "Invalid argument type: \(key)") }
            return text
        }
        func jsonObject(_ key: String) throws -> JSONObject {
            guard let value = args[key] else { throw Message(text: "Missing argument: \(key)") }
            guard let dictionary = value as? [String: Any] else { throw Message(text: "Invalid argument type: \(key)") }
            return JSONObject(dictionary)
        }
        func optionalString(_ key: String) throws -> String? {
            switch args[key] {
            case nil, is NSNull: return nil
            default: return try string(key)
            }
        }
        func optionalIndex(_ key: String) throws -> Int? {
            switch args[key] {
            case nil, is NSNull: return nil
            case let value:
                guard let index = integer(value), index >= 0 else { throw Message(text: "Invalid argument type: \(key)") }
                return index
            }
        }
        func strings(_ key: String) throws -> [String] {
            guard let value = args[key] else { throw Message(text: "Missing argument: \(key)") }
            guard let list = value as? [Any], list.allSatisfy({ ($0 as? String)?.isEmpty == false }) else {
                throw Message(text: "Invalid argument type: \(key)")
            }
            return list.map { $0 as! String }
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = args[key], !(value is NSNull) else { return false }
            guard let number = value as? NSNumber, isBool(number) else { throw Message(text: "Invalid argument type: \(key)") }
            return number.boolValue
        }
        func positive(_ key: String, default fallback: Double? = nil) throws -> Double {
            guard let value = args[key], !(value is NSNull) else {
                if let fallback { return fallback }
                throw Message(text: "Missing argument: \(key)")
            }
            guard let number = value as? NSNumber, !isBool(number), number.doubleValue.isFinite, number.doubleValue > 0 else {
                throw Message(text: "Invalid argument type: \(key)")
            }
            return number.doubleValue
        }
        switch name {
        case "get_state": return .getState
        case "get_document": return .getDocument
        case "get_node": return .getNode(try string("id"))
        case "create_node": return .createNode(parent: try optionalString("parent"), index: try optionalIndex("index"), node: try jsonObject("node"))
        case "update_node": return .updateNode(try string("id"), changes: try jsonObject("changes"))
        case "delete_nodes":
            let ids = try strings("ids")
            guard !ids.isEmpty else { throw Message(text: "Invalid argument type: ids") }
            return .deleteNodes(ids)
        case "move_node": return .moveNode(try string("id"), parent: try optionalString("parent"), index: try optionalIndex("index"))
        case "select": return .select(try strings("ids"))
        case "undo": return .undo
        case "redo": return .redo
        case "new_document": return .newDocument(discard: try flag("discard"))
        case "open_document": return .openDocument(try string("path"), discard: try flag("discard"))
        case "save_document": return .saveDocument(try optionalString("path"))
        case "focus_node": return .focusNode(try string("id"))
        case "fit_all": return .fitAll
        case "zoom": return .zoom(try positive("scale"))
        case "node_snapshot":
            let scale = try positive("scale", default: 2)
            guard scale <= 4 else { throw Message(text: "Invalid argument type: scale") }
            return .nodeSnapshot(try string("id"), scale: scale)
        default: throw Message(text: "Unknown command: \(name)")
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
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false,"error":"Response could not be encoded"}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
