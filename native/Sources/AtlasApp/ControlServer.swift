import AtlasCore
import Darwin
import Foundation

/// 控制命令执行失败时的中文消息，原样返回给调用方。
struct ControlCommandError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 控制通道：只对当前用户开放的 Unix domain socket，不监听任何网络地址。
/// 每个连接按行读取请求，命令在主线程执行，响应按请求顺序写回。
final class ControlServer: @unchecked Sendable {
    typealias Handler = @MainActor (ControlCommand) async throws -> Any

    static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["UI_ATLAS_CONTROL_SOCKET"], !path.isEmpty { return path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/界面图鉴/control.sock").path
    }

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "界面图鉴.control")
    private var source: DispatchSourceRead?
    private static let maximumLine = 1 << 20
    /// 每个连接占用一个阻塞线程，因此限制并发连接数，并在空闲 60 秒后断开。
    static let maximumConnections = 8
    private let lock = NSLock()
    private var clients = Set<Int32>()
    private var stopped = false

    init(path: String = ControlServer.defaultPath(), handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        var address = try Self.address(path)
        // 只清理崩溃残留的 socket；另一个实例仍在监听时不抢占，也不删除普通文件。
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFSOCK else { throw ControlCommandError("控制通道路径已被其他文件占用：\(path)") }
            if Self.isLive(&address) { throw ControlCommandError("另一个界面图鉴已在监听控制通道") }
            unlink(path)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ControlCommandError("无法创建控制通道：\(String(cString: strerror(errno)))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            // 绑定失败时文件不属于本进程，不能删除。
            let message = String(cString: strerror(errno))
            close(listener)
            throw ControlCommandError("无法监听控制通道：\(message)")
        }
        guard chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(listener)
            unlink(path)
            throw ControlCommandError("无法监听控制通道：\(message)")
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener) }
        source.setCancelHandler { close(listener) }
        self.source = source
        source.resume()
    }

    /// 停止监听并断开已有连接，之后的请求一律拒绝。
    func stop() {
        lock.lock()
        stopped = true
        clients.forEach { shutdown($0, SHUT_RDWR) }
        lock.unlock()
        guard let source else { return }
        self.source = nil
        source.cancel()
        unlink(path)
    }

    deinit { stop() }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                // 例如文件描述符耗尽：暂停一秒，避免可读事件反复触发而空转。
                source?.suspend()
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.source?.resume() }
                return
            }
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            // accept() inherits O_NONBLOCK from the listener; each connection is served with blocking I/O.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var idle = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            let accepted = !stopped && clients.count < Self.maximumConnections
            if accepted { clients.insert(client) }
            lock.unlock()
            guard accepted else {
                _ = Self.write(ControlProtocol.failure(id: nil, message: "连接过多，请稍后再试"), to: client)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { close(client); return }
                self.serve(client)
            }
        }
    }

    /// 阻塞读取一个连接，直到对方关闭。每行一个请求。
    private func serve(_ client: Int32) {
        defer {
            lock.lock()
            clients.remove(client)
            lock.unlock()
            close(client)
        }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) { continue }
                guard Self.write(respond(to: Data(line)), to: client) else { return }
            }
            if pending.count > Self.maximumLine {
                _ = Self.write(ControlProtocol.failure(id: nil, message: "请求过长"), to: client)
                return
            }
        }
    }

    private func respond(to line: Data) -> Data {
        let request: ControlRequest
        switch ControlProtocol.parse(line) {
        case .failure(let failure): return ControlProtocol.failure(id: failure.id, message: failure.message)
        case .success(let parsed): request = parsed
        }
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        if isStopped { return ControlProtocol.failure(id: request.id, message: "界面图鉴正在退出") }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let handler = handler
        Task { @MainActor in
            do { box.data = ControlProtocol.success(id: request.id, result: try await handler(request.command)) }
            catch { box.data = ControlProtocol.failure(id: request.id, message: error.localizedDescription) }
            done.signal()
        }
        done.wait()
        return box.data
    }

    private static func write(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(client, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ControlCommandError("控制通道路径过长：\(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func isLive(_ address: inout sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(probe) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
}

private final class ResponseBox: @unchecked Sendable {
    var data = Data()
}
