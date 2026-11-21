import Foundation

/// The Node.js that runs the MCP server and the chat panel's Agent harness. Node is not shipped with the App; it must be installed on the Mac.
public enum NodeRuntime {
    /// The oldest supported version, as in `engines.node` of package.json.
    public static let minimum = [22, 12, 0]
    public static let minimumText = "22.12"

    /// Parses `node --version` output such as "v22.12.0".
    public static func version(_ output: String) -> [Int]? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("v") else { return nil }
        let parts = text.dropFirst().split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    public static func isSupported(_ version: [Int]) -> Bool { !version.lexicographicallyPrecedes(minimum) }

    /// The first candidate whose `node --version` output (nil when it could not run) is supported; otherwise the first one that ran, as too old.
    public static func pick(_ candidates: [(path: String, output: String?)]) -> NodeStatus {
        let versioned = candidates.compactMap { candidate in candidate.output.flatMap(version).map { (candidate.path, $0) } }
        let text = { (version: [Int]) in version.map(String.init).joined(separator: ".") }
        if let found = versioned.first(where: { isSupported($0.1) }) { return .found(path: found.0, version: text(found.1)) }
        if let old = versioned.first { return .tooOld(path: old.0, version: text(old.1)) }
        return .missing
    }
}

public enum NodeStatus: Equatable, Sendable {
    case found(path: String, version: String)
    /// Node was found, but older than `NodeRuntime.minimum`.
    case tooOld(path: String, version: String)
    case missing

    public var path: String? {
        if case .found(let path, _) = self { return path }
        return nil
    }
}

/// The PATH the App searches for Node and the Agent CLIs. An App opened from Finder inherits only a minimal PATH, so this adds the PATH
/// recorded at build time (source builds only), the login shell's PATH, and the usual install locations of Homebrew, the Node installer,
/// nvm, Volta, and the Claude Code installer.
public enum ToolSearchPath {
    static let marker = "__FUDEHAND_PATH__"

    /// The command the login shell runs to print its PATH; the marker separates it from anything the profile prints.
    public static let shellArguments = ["-l", "-c", "printf '\\n\(marker)%s\\n' \"$PATH\""]

    public static func loginPath(fromShellOutput output: String) -> String? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// `nvmVersions` are the directory names under `~/.nvm/versions/node`.
    public static func compose(recorded: String?, login: String?, inherited: String?, home: String, nvmVersions: [String]) -> String {
        let nvm = nvmVersions.compactMap { name in NodeRuntime.version(name).map { (name, $0) } }
            .sorted { $1.1.lexicographicallyPrecedes($0.1) }
            .map { "\(home)/.nvm/versions/node/\($0.0)/bin" }
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.volta/bin", "\(home)/.npm-global/bin"]
            + nvm + ["/usr/bin", "/bin"]
        var seen = Set<String>()
        return ([recorded, login, inherited].compactMap { $0 }.flatMap { $0.split(separator: ":").map(String.init) } + common)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
}

/// The Node scripts and their production dependencies that a built App carries in `Contents/Resources/Tools` (see scripts/native-build.mjs).
/// The App copies them to a fixed place outside its bundle, so Agent registrations keep working when the App is moved or updated.
public enum BundledTools {
    /// A file holding an id unique to each build.
    public static let buildMarker = "build-id"

    /// Copies `source` to `target` unless `target` already holds the same build; a different build is replaced as a whole.
    public static func install(from source: URL, to target: URL, files: FileManager = .default) throws {
        let build = try? Data(contentsOf: source.appendingPathComponent(buildMarker))
        if build != nil, build == (try? Data(contentsOf: target.appendingPathComponent(buildMarker))) { return }
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)-\(UUID().uuidString)")
        try files.copyItem(at: source, to: staging)
        do {
            if files.fileExists(atPath: target.path) {
                _ = try files.replaceItemAt(target, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: target)
            }
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }
}
