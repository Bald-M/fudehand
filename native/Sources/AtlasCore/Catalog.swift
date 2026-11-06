import Foundation

public struct Catalog: Codable, Equatable {
    public var version: Int
    public var projects: [Project]

    private enum CodingKeys: String, CodingKey { case version, projects }

    public init(version: Int, projects: [Project]) {
        self.version = version; self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try values.decodeInteger(forKey: .version), projects: try values.decode([Project].self, forKey: .projects))
    }

    public static func load(from root: URL) throws -> Catalog {
        do {
            let data = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            try catalog.validate(root: root)
            return catalog
        } catch let error as CatalogError {
            throw error
        } catch let error as DecodingError {
            let context: DecodingError.Context
            var missing = ""
            switch error {
            case .keyNotFound(let key, let value): context = value; missing = ".\(key.stringValue)"
            case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value): context = value
            @unknown default: throw CatalogError(message: "catalog.json 格式无效")
            }
            let field = context.codingPath.map(\.stringValue).joined(separator: ".") + missing
            throw CatalogError(message: "catalog\(field.isEmpty ? "" : "." + field.trimmingCharacters(in: CharacterSet(charactersIn: "."))) 格式无效或缺少必填字段")
        } catch {
            throw CatalogError(message: "无法读取 catalog.json：\(error.localizedDescription)")
        }
    }

    public func validate(root: URL) throws {
        try requireCatalogValue(version == 1, "catalog.version 必须是 1")
        var ports = Set<Int>()
        func checkPort(_ port: Int, _ field: String) throws {
            try requireCatalogValue((1...65535).contains(port), "\(field) 必须是 1～65535 的整数")
            try requireCatalogValue(ports.insert(port).inserted, "端口 \(port) 重复，请为每个服务设置独立端口")
        }
        var ids = Set<String>()
        for project in projects {
            let name = project.id
            let idRange = name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression)
            try requireCatalogValue(idRange == name.startIndex..<name.endIndex && ids.insert(name).inserted, "作品 id 必须唯一，且仅使用小写字母、数字或连字符")
            try requireCatalogValue(!project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name).title 不能为空")
            try requireCatalogValue(project.layoutVersion > 0, "\(name).layoutVersion 必须是正整数")
            if let source = project.sourceUrl {
                let url = URL(string: source)
                try requireCatalogValue(url?.scheme?.lowercased() == "http" || url?.scheme?.lowercased() == "https", "\(name).sourceUrl 必须是 HTTP/HTTPS 地址或 null")
                try requireCatalogValue(url?.host?.isEmpty == false, "\(name).sourceUrl 必须是 HTTP/HTTPS 地址或 null")
            }
            try checkPort(project.preview.port, "\(name).preview.port")
            _ = try localPreviewURL(project.preview.baseUrl, port: project.preview.port, field: "\(name).preview.baseUrl")
            try checkDirectory(project.preview.cwd, root: root, field: "\(name).preview.cwd")
            try requireCatalogValue(!project.preview.command.isEmpty && project.preview.command.allSatisfy { !$0.isEmpty && !$0.contains("\0") }, "\(name).preview.command 必须是非空参数数组")
            try requireCatalogValue(!project.frames.isEmpty, "\(name) 至少需要一个画框")
            var frameIDs = Set<String>()
            for frame in project.frames {
                let field = "\(name)/\(frame.id)"
                try requireCatalogValue(!frame.id.isEmpty && frameIDs.insert(frame.id).inserted, "\(name) 的画框 id 必须非空且唯一")
                try requireCatalogValue(!frame.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(field).title 不能为空")
                try requireCatalogValue(["mobile", "web", "desktop"].contains(frame.platform), "\(field).platform 必须是 mobile、web 或 desktop")
                try requireCatalogValue(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0, "\(field) 的宽高必须是有限正数")
                try requireCatalogValue(frame.x.isFinite && frame.y.isFinite, "\(field) 的坐标必须是有限数值")
                _ = try frame.previewURL(baseURL: project.preview.baseUrl)
            }
        }
    }
}

public struct Project: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var description: String
    public var author: String
    public var sourceUrl: String?
    public var framework: String
    public var tags: [String]
    public var enabled: Bool
    public var layoutVersion: Int
    public var preview: Preview
    public var frames: [Frame]

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, description, author, sourceUrl, framework, tags, enabled, layoutVersion, preview, frames
    }
}

extension Project {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            subtitle: try values.decode(String.self, forKey: .subtitle),
            description: try values.decode(String.self, forKey: .description),
            author: try values.decode(String.self, forKey: .author),
            sourceUrl: try values.decode(String?.self, forKey: .sourceUrl),
            framework: try values.decode(String.self, forKey: .framework),
            tags: try values.decode([String].self, forKey: .tags),
            enabled: try values.decode(Bool.self, forKey: .enabled),
            layoutVersion: try values.decodeInteger(forKey: .layoutVersion),
            preview: try values.decode(Preview.self, forKey: .preview),
            frames: try values.decode([Frame].self, forKey: .frames)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(subtitle, forKey: .subtitle)
        try values.encode(description, forKey: .description)
        try values.encode(author, forKey: .author)
        // An original study has an explicit null source; the catalog requires this key.
        try values.encode(sourceUrl, forKey: .sourceUrl)
        try values.encode(framework, forKey: .framework)
        try values.encode(tags, forKey: .tags)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(layoutVersion, forKey: .layoutVersion)
        try values.encode(preview, forKey: .preview)
        try values.encode(frames, forKey: .frames)
    }
}

public struct Preview: Codable, Equatable {
    public var cwd: String
    public var command: [String]
    public var port: Int
    public var baseUrl: String
}

extension Preview {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cwd: try values.decode(String.self, forKey: .cwd), command: try values.decode([String].self, forKey: .command),
                  port: try values.decodeInteger(forKey: .port), baseUrl: try values.decode(String.self, forKey: .baseUrl))
    }
}

extension KeyedDecodingContainer {
    /// Foundation reports a fractional value for an Int field without a coding path. Decoding a
    /// number first keeps the path, so Catalog.load can name the field, as the launcher does.
    func decodeInteger(forKey key: Key) throws -> Int {
        let number = try decode(Double.self, forKey: key)
        guard let integer = Int(exactly: number) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(key.stringValue) 必须是整数")
        }
        return integer
    }
}

public struct Frame: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var platform: String
    public var path: String
    public var width: Double
    public var height: Double
    public var x: Double
    public var y: Double

    public func previewURL(baseURL: String) throws -> URL {
        let field = "画框 \(id).path"
        try requireCatalogValue(!path.isEmpty, "\(field) 不能为空")
        let base = try localPreviewURL(baseURL, port: nil, field: "preview.baseUrl")
        // HTTP URL paths treat backslashes as slashes, like the browser URL constructor.
        guard let url = URL(string: path.replacingOccurrences(of: "\\", with: "/"), relativeTo: base)?.absoluteURL else {
            throw CatalogError(message: "\(field) 无法解析")
        }
        try requireCatalogValue(url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased() && (url.port ?? 80) == (base.port ?? 80) && url.user == nil && url.password == nil, "\(field) 必须指向该作品的本地预览服务")
        return url
    }
}

private struct CatalogError: LocalizedError {
    let message: String
    var errorDescription: String? { "配置错误：\(message)" }
}

private func requireCatalogValue(_ condition: Bool, _ message: String) throws {
    if !condition { throw CatalogError(message: message) }
}

private func localPreviewURL(_ value: String, port: Int?, field: String) throws -> URL {
    guard let url = URL(string: value) else { throw CatalogError(message: "\(field) 必须是有效 URL") }
    let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
    try requireCatalogValue(url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost", "::1"].contains(host), "\(field) 只能使用本机 HTTP 地址")
    try requireCatalogValue(url.user == nil && url.password == nil && (port == nil || (url.port ?? 80) == port), "\(field) 的端口必须与 port 一致，且不能包含账号信息")
    return url
}

private func checkDirectory(_ cwd: String, root: URL, field: String) throws {
    try requireCatalogValue(!cwd.isEmpty && !(cwd as NSString).isAbsolutePath && !cwd.contains("\0"), "\(field) 必须是项目内的相对目录")
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let directory = base.appendingPathComponent(cwd).standardizedFileURL.resolvingSymlinksInPath()
    try requireCatalogValue(directory.path == base.path || directory.path.hasPrefix(base.path + "/"), "\(field) 不能离开项目目录")
    var isDirectory: ObjCBool = false
    try requireCatalogValue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue, "\(field) 目录不存在或不是目录：\(cwd)")
}
