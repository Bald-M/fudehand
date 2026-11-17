import Darwin
import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

private func temporarySocketPath() -> String {
    // sockaddr_un 的路径上限约 104 字节，临时目录可能太长。
    "/tmp/uia-\(UUID().uuidString.prefix(8)).sock"
}

private func connectSocket(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
    return fd
}

/// 以普通客户端身份发送若干行，读回同样数量的响应行。
private func exchange(_ path: String, _ lines: [String]) async throws -> [[String: Any]] {
    let raw = try await Task.detached { () throws -> String in
        let fd = try connectSocket(path)
        defer { close(fd) }
        let payload = Array(lines.map { $0 + "\n" }.joined().utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return readLines(fd, count: lines.count)
    }.value
    return try raw.split(separator: "\n").map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
}

private func readLines(_ fd: Int32, count expected: Int) -> String {
    var received = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var newlines = 0
    while newlines < expected {
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { break }
        received += chunk[0..<count]
        newlines += chunk[0..<count].filter { $0 == UInt8(ascii: "\n") }.count
    }
    return String(decoding: received, as: UTF8.self)
}

/// 模拟崩溃留下的 socket 文件：监听后关闭，但不删除文件。
private func leaveStaleSocket(_ path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    listen(fd, 1)
    close(fd)
}

@Test func controlServerAnswersOverAPrivateSocketAndReplacesAStaleFile() async throws {
    let path = temporarySocketPath()
    leaveStaleSocket(path)
    #expect(FileManager.default.fileExists(atPath: path))
    let server = ControlServer(path: path) { command in
        if case .focusFrame(let id) = command { throw ControlCommandError("当前作品没有画框：\(id)") }
        return ["handled": "\(command)"]
    }
    try server.start()
    defer { server.stop() }
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let responses = try await exchange(path, [
        #"{"id":1,"command":"get_state"}"#,
        #"{"id":2,"command":"focus_frame","args":{"frame":"x"}}"#,
        "oops",
    ])
    #expect(responses.count == 3)
    #expect(responses[0]["id"] as? Int == 1)
    #expect(responses[0]["ok"] as? Bool == true)
    #expect((responses[0]["result"] as? [String: Any])?["handled"] as? String == "getState")
    #expect(responses[1]["error"] as? String == "当前作品没有画框：x")
    #expect(responses[2]["error"] as? String == "请求不是有效 JSON")
}

@Test func controlServerRefusesToStealALiveSocketAndRemovesItsFileOnStop() throws {
    let path = temporarySocketPath()
    let first = ControlServer(path: path) { _ in [:] }
    try first.start()
    let second = ControlServer(path: path) { _ in [:] }
    #expect(throws: ControlCommandError.self) { try second.start() }
    #expect(FileManager.default.fileExists(atPath: path))
    first.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func controlSocketPathDefaultsToApplicationSupport() {
    let path = ControlServer.defaultPath(environment: [:])
    #expect(path.hasSuffix("/Library/Application Support/ui-atlas/control.sock"))
    #expect(ControlServer.defaultPath(environment: ["UI_ATLAS_CONTROL_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
}

@Test func controlServerWritesLargeResponsesCompletely() async throws {
    let path = temporarySocketPath()
    let payload = String(repeating: "a", count: 4 << 20)
    let server = ControlServer(path: path) { _ in ["data": payload] }
    try server.start()
    defer { server.stop() }
    let responses = try await exchange(path, [#"{"id":1,"command":"frame_snapshot","args":{"frame":"x"}}"#])
    #expect((responses.first?["result"] as? [String: Any])?["data"] as? String == payload)
}

@Test func controlServerKeepsANonSocketFileAtItsPath() throws {
    let path = temporarySocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
    defer { unlink(path) }
    let server = ControlServer(path: path) { _ in [:] }
    #expect(throws: ControlCommandError.self) { try server.start() }
    #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
}

@Test func controlServerClosesOpenConnectionsOnStop() async throws {
    let path = temporarySocketPath()
    let server = ControlServer(path: path) { _ in [:] }
    try server.start()
    let fd = try connectSocket(path)
    defer { close(fd) }
    // 等连接被接受后再停止。
    _ = try await exchange(path, [#"{"id":1,"command":"get_state"}"#])
    try await Task.sleep(nanoseconds: 50_000_000)
    server.stop()
    let reply = await Task.detached { () -> String in
        let request = Array(#"{"id":2,"command":"restart_preview"}"#.utf8) + [UInt8(ascii: "\n")]
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return readLines(fd, count: 1)
    }.value
    #expect(reply.isEmpty)
}

@Test func controlServerRefusesConnectionsBeyondTheLimit() async throws {
    let path = temporarySocketPath()
    let server = ControlServer(path: path) { _ in [:] }
    try server.start()
    defer { server.stop() }
    var idle: [Int32] = []
    defer { idle.forEach { close($0) } }
    for _ in 0..<ControlServer.maximumConnections { idle.append(try connectSocket(path)) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let responses = try await exchange(path, [#"{"id":1,"command":"get_state"}"#])
    #expect(responses.first?["error"] as? String == "连接过多，请稍后再试")
}
