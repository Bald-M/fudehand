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
    case focusNodes([String])
    case fitAll
    case zoom(Double)
    case nodeSnapshot(String, scale: Double)
    case listFonts
    case importFont(String)
    case searchIcons(query: String, library: IconLibrary?, limit: Int)
    /// Opens the prototype window from `frame` (a top-level frame), or, when nil, where Play Prototype starts.
    case playPrototype(frame: String?)
    case getPrototypePlayback
    case closePrototype
    case showLaunchWindow
    case listRecents
    case openRecent(String, discard: Bool)
    case removeRecent(String)
    case clearRecents
    case listTemplates
    case newDocumentFromTemplate(String, discard: Bool)
    // Chat panel conversations. A nil conversation means the selected one.
    case listConversations
    case getConversation(UUID?)
    case openConversation(UUID)
    case newConversation
    case closeConversation(UUID)
    case deleteConversation(UUID)
    case clearConversation(UUID?)
    /// `context` holds layer ids; `mode` switches the conversation first, nil keeps its mode.
    case sendMessage(UUID?, text: String, context: [String], mode: ChatMode?)
    /// A nil mode leaves plan or goal mode.
    case setMode(UUID?, mode: ChatMode?)
    /// Confirms the plan made in plan mode, as Run Plan does.
    case runPlan(UUID?, context: [String])
    case stopReply(UUID?)
    case regenerateReply(UUID?)
    case editLastMessage(UUID?, text: String, context: [String])
    /// A nil answer skips the question.
    case answerQuestion(UUID?, answer: String?)
    case compactConversation(UUID?)
    case getInterface
    case updateInterface(language: AppLanguage?, appearance: Appearance?)
    case getModels
    case updateModelProvider(String, model: String?, baseUrl: String?, use: Bool)
    case listModels(String, baseUrl: String?)
    case setAPIKey(String, key: String)
    case deleteAPIKey(String)
    case getConnectors
    case setConnector(AgentConnector, connected: Bool)
    case setView(ViewChange)
}

/// The inspector's tabs: the properties panel, the prototype settings, and the chat panel.
public enum InspectorTab: String, CaseIterable, Sendable { case design, prototype, chat }

/// A change to the editor view, outside the design document: the canvas tool, the inspector, and which layers the layers panel collapses.
/// A nil field is left as it is.
public struct ViewChange: Equatable, Sendable {
    public var tool: CanvasTool?
    public var inspector: Bool?
    public var inspectorTab: InspectorTab?
    public var expand: [String]
    public var collapse: [String]

    public init(tool: CanvasTool? = nil, inspector: Bool? = nil, inspectorTab: InspectorTab? = nil, expand: [String] = [], collapse: [String] = []) {
        self.tool = tool; self.inspector = inspector; self.inspectorTab = inspectorTab; self.expand = expand; self.collapse = collapse
    }
}

/// The App's appearance setting; raw values are what is saved.
public enum Appearance: String, CaseIterable, Sendable {
    case system, light, dark
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
    /// The chat panel conversation whose Agent sent the request; nil for any other caller.
    public let caller: UUID?
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
/// A request from the in-App Agent also carries `"caller"`, the id of its conversation, so a command cannot stop, delete, or
/// reconfigure the conversation that sent it.
public enum ControlProtocol {
    public static func parse(_ line: Data) -> Result<ControlRequest, ControlFailure> {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .failure(ControlFailure(id: nil, message: "Request is not valid JSON"))
        }
        let id: ControlID? = (object["id"] as? String).map(ControlID.string) ?? integer(object["id"]).map(ControlID.int)
        do {
            var caller: UUID?
            if let value = object["caller"], !(value is NSNull) {
                guard let text = value as? String, let uuid = UUID(uuidString: text) else { throw Message(text: "Invalid argument type: caller") }
                caller = uuid
            }
            return .success(ControlRequest(id: id, command: try command(object), caller: caller))
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
        func conversation(_ key: String = "id") throws -> UUID {
            guard let uuid = UUID(uuidString: try string(key)) else { throw Message(text: "Invalid argument type: \(key)") }
            return uuid
        }
        func optionalConversation() throws -> UUID? {
            switch args["id"] {
            case nil, is NSNull: return nil
            default: return try conversation()
            }
        }
        func layerIDs() throws -> [String] {
            switch args["context"] {
            case nil, is NSNull: return []
            default: return try strings("context")
            }
        }
        func message() throws -> String {
            let text = try string("text")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Message(text: "Invalid argument type: text") }
            return text
        }
        func chatMode(allowingNone: Bool) throws -> ChatMode? {
            let name = try string("mode")
            if allowingNone, name == "none" { return nil }
            guard let mode = ChatMode(rawValue: name) else {
                throw Message(text: "mode must be one of plan, goal\(allowingNone ? ", none" : ""); got \(name)")
            }
            return mode
        }
        /// A string that may be empty (an empty model or base URL means the default); nil when absent.
        func optionalText(_ key: String) throws -> String? {
            switch args[key] {
            case nil, is NSNull: return nil
            case let text as String: return text
            default: throw Message(text: "Invalid argument type: \(key)")
            }
        }
        func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
            guard let name = try optionalString(key) else { return nil }
            guard let value = T(rawValue: name) else {
                throw Message(text: "\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")); got \(name)")
            }
            return value
        }
        func required<T>(_ key: String, _ value: T?) throws -> T {
            guard let value else { throw Message(text: "Missing argument: \(key)") }
            return value
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
        case "focus_node":
            switch (args["id"], args["ids"]) {
            case (nil, nil): throw Message(text: "Missing argument: id or ids")
            case (_?, _?): throw Message(text: "Pass either id or ids, not both")
            case (_?, nil): return .focusNodes([try string("id")])
            case (nil, _?):
                let ids = try strings("ids")
                guard !ids.isEmpty else { throw Message(text: "Invalid argument type: ids") }
                return .focusNodes(ids)
            }
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
        case "play": return .playPrototype(frame: try optionalString("frame"))
        case "get_playback": return .getPrototypePlayback
        case "close": return .closePrototype
        case "show_launch_window": return .showLaunchWindow
        case "list_recents": return .listRecents
        case "open_recent": return .openRecent(try string("path"), discard: try flag("discard"))
        case "remove_recent": return .removeRecent(try string("path"))
        case "clear_recents": return .clearRecents
        case "list_templates": return .listTemplates
        case "new_document_from_template": return .newDocumentFromTemplate(try string("name"), discard: try flag("discard"))
        case "list_conversations": return .listConversations
        case "get_conversation": return .getConversation(try optionalConversation())
        case "open_conversation": return .openConversation(try conversation())
        case "new_conversation": return .newConversation
        case "close_conversation": return .closeConversation(try conversation())
        case "delete_conversation": return .deleteConversation(try conversation())
        case "clear_conversation": return .clearConversation(try optionalConversation())
        case "send_message":
            let mode = args["mode"] == nil || args["mode"] is NSNull ? nil : try chatMode(allowingNone: false)
            return .sendMessage(try optionalConversation(), text: try message(), context: try layerIDs(), mode: mode)
        case "set_mode": return .setMode(try optionalConversation(), mode: try chatMode(allowingNone: true))
        case "run_plan": return .runPlan(try optionalConversation(), context: try layerIDs())
        case "stop_reply": return .stopReply(try optionalConversation())
        case "regenerate_reply": return .regenerateReply(try optionalConversation())
        case "edit_last_message": return .editLastMessage(try optionalConversation(), text: try message(), context: try layerIDs())
        case "answer_question":
            let skip = try flag("skip")
            let text = args["text"] == nil || args["text"] is NSNull ? nil : try message()
            guard skip != (text != nil) else { throw Message(text: "Provide either text or skip: true") }
            return .answerQuestion(try optionalConversation(), answer: text)
        case "compact_conversation": return .compactConversation(try optionalConversation())
        case "get_interface": return .getInterface
        case "update_interface":
            let language = try choice("language", AppLanguage.self), appearance = try choice("appearance", Appearance.self)
            guard language != nil || appearance != nil else { throw Message(text: "Provide language, appearance, or both") }
            return .updateInterface(language: language, appearance: appearance)
        case "get_models": return .getModels
        case "update_model_provider":
            let provider = try string("provider")
            let model = try optionalText("model"), baseUrl = try optionalText("baseUrl"), use = try flag("use")
            guard model != nil || baseUrl != nil || use else { throw Message(text: "Provide model, baseUrl, or use") }
            return .updateModelProvider(provider, model: model, baseUrl: baseUrl, use: use)
        case "list_models": return .listModels(try string("provider"), baseUrl: try optionalText("baseUrl"))
        case "set_api_key":
            // The message never repeats the value: it may be a key.
            guard let key = args["key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Message(text: args["key"] == nil ? "Missing argument: key" : "Invalid argument type: key")
            }
            return .setAPIKey(try string("provider"), key: key.trimmingCharacters(in: .whitespacesAndNewlines))
        case "delete_api_key": return .deleteAPIKey(try string("provider"))
        case "get_connectors": return .getConnectors
        case "set_connector":
            let connector = try required("connector", try choice("connector", AgentConnector.self))
            guard args["connected"] != nil, !(args["connected"] is NSNull) else { throw Message(text: "Missing argument: connected") }
            return .setConnector(connector, connected: try flag("connected"))
        case "set_view":
            func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
                guard let name = try optionalString(key) else { return nil }
                guard let value = T(rawValue: name) else {
                    throw Message(text: "\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")); got \(name)")
                }
                return value
            }
            var change = ViewChange(tool: try choice("tool", CanvasTool.self), inspectorTab: try choice("inspectorTab", InspectorTab.self))
            if args["inspector"] != nil, !(args["inspector"] is NSNull) { change.inspector = try flag("inspector") }
            if args["expand"] != nil { change.expand = try strings("expand") }
            if args["collapse"] != nil { change.collapse = try strings("collapse") }
            guard change != ViewChange() else { throw Message(text: "Nothing to change: pass tool, inspector, inspectorTab, expand, or collapse") }
            if let both = change.expand.first(where: change.collapse.contains) {
                throw Message(text: "A layer cannot be both expanded and collapsed: \(both)")
            }
            return .setView(change)
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
