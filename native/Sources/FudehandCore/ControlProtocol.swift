import Foundation

/// Control-channel commands: an external process reads and edits the design document in the running App over a local Unix socket.
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
    case listFonts
    case importFont(String)
    case searchIcons(query: String, library: IconLibrary?, limit: Int)
    case showLaunchWindow
    case listRecents
    case openRecent(String, discard: Bool)
    case removeRecent(String)
    case clearRecents
    case listTemplates
    case newDocumentFromTemplate(String, discard: Bool)
}

/// A JSON object carried as is (a layer definition or a field patch), validated by `DesignJSON`.
public struct JSONObject: Equatable, @unchecked Sendable {
    public let value: [String: Any]
    public init(_ value: [String: Any]) { self.value = value }
    public static func == (a: JSONObject, b: JSONObject) -> Bool { NSDictionary(dictionary: a.value).isEqual(to: b.value) }
}

/// The request id is echoed back as is, so the caller can match the response.
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

/// Line-delimited JSON: request `{"id":1,"command":"focus_node","args":{"id":"home"}}`,
/// response `{"id":1,"ok":true,"result":…}` or `{"id":1,"ok":false,"error":"…"}`.
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

    /// The id of a request whose line was cut short, readable only when `id` is the first key (as the Node client writes it).
    public static func leadingID(_ head: Data) -> ControlID? {
        let text = String(decoding: head, as: UTF8.self)
        let pattern = #"^\s*\{\s*"id"\s*:\s*(-?\d+|"(?:[^"\\]|\\.)*")\s*,"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              let literal = text[range].range(of: #"(-?\d+|"(?:[^"\\]|\\.)*")\s*,$"#, options: .regularExpression),
              let value = try? JSONSerialization.jsonObject(with: Data(text[literal].dropLast().utf8), options: .fragmentsAllowed)
        else { return nil }
        return (value as? String).map(ControlID.string) ?? integer(value).map(ControlID.int)
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
        case "list_fonts": return .listFonts
        case "import_font": return .importFont(try string("path"))
        case "search_icons":
            var library: IconLibrary?
            if let name = try optionalString("library") {
                guard let value = IconLibrary(rawValue: name) else {
                    throw Message(text: "library must be one of \(IconLibrary.allCases.map(\.rawValue).joined(separator: ", ")); got \(name)")
                }
                library = value
            }
            let limit = try positive("limit", default: 50)
            guard limit <= 200, limit == limit.rounded() else { throw Message(text: "Invalid argument type: limit") }
            return .searchIcons(query: try string("query"), library: library, limit: Int(limit))
        case "show_launch_window": return .showLaunchWindow
        case "list_recents": return .listRecents
        case "open_recent": return .openRecent(try string("path"), discard: try flag("discard"))
        case "remove_recent": return .removeRecent(try string("path"))
        case "clear_recents": return .clearRecents
        case "list_templates": return .listTemplates
        case "new_document_from_template": return .newDocumentFromTemplate(try string("name"), discard: try flag("discard"))
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
