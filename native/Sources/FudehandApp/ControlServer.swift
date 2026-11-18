import FudehandCore
import Darwin
import Foundation

/// The message of a failed control command, returned to the caller as is.
struct ControlCommandError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The control channel: a Unix domain socket open only to the current user, listening on no network address.
/// Each connection reads requests line by line, commands run on the main thread, and responses are written back in request order.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @MainActor (ControlCommand) async throws -> Any

    static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["FUDEHAND_CONTROL_SOCKET"], !path.isEmpty { return path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/fudehand/control.sock").path
    }

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "fudehand.control")
    private var source: DispatchSourceRead?
    /// Longest accepted request line. An image travels as base64 inside the request, so this allows about 24 MB of image files.
    static let maximumLine = 32 << 20
    static let tooLargeMessage = "Request is too large: a request, including images embedded as base64, is limited to \(maximumLine >> 20) MB (about \((maximumLine * 3 / 4) >> 20) MB of image files)"
    /// Each connection occupies one blocking thread, so the number of concurrent connections is limited and a connection is dropped after 60 seconds idle.
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
        // Only clean up a socket left behind by a crash; do not take over while another instance is still listening, and do not delete regular files.
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFSOCK else { throw ControlCommandError("Control channel path is taken by another file: \(path)") }
            if Self.isLive(&address) { throw ControlCommandError("Another Fudehand is already listening on the control channel") }
            unlink(path)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ControlCommandError("Could not create the control channel: \(String(cString: strerror(errno)))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            // When binding fails the file does not belong to this process and must not be deleted.
            let message = String(cString: strerror(errno))
            close(listener)
            throw ControlCommandError("Could not listen on the control channel: \(message)")
        }
        guard chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(listener)
            unlink(path)
            throw ControlCommandError("Could not listen on the control channel: \(message)")
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener) }
        source.setCancelHandler { close(listener) }
        self.source = source
        source.resume()
    }

    /// Stops listening and drops existing connections; every later request is rejected.
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
                // For example, file descriptors are exhausted: pause for a second so the readable event does not fire repeatedly in a busy loop.
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
                _ = Self.write(ControlProtocol.failure(id: nil, message: "Too many connections; try again later"), to: client)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { close(client); return }
                self.serve(client)
            }
        }
    }

    /// Reads one connection, blocking, until the peer closes it. One request per line.
    private func serve(_ client: Int32) {
        defer {
            lock.lock()
            clients.remove(client)
            lock.unlock()
            close(client)
        }
        var line = Data()
        // Once a line passes the limit its bytes are dropped up to the newline, then the request is refused.
        var oversized = false
        var oversizedID: ControlID?
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            // Only the newly read bytes are searched for a newline, and each byte is copied into `line` once.
            var start = 0
            while start < count {
                let newline = chunk[start..<count].firstIndex(of: UInt8(ascii: "\n"))
                if !oversized {
                    line.append(contentsOf: chunk[start..<(newline ?? count)])
                    if line.count > Self.maximumLine {
                        oversized = true
                        oversizedID = ControlProtocol.leadingID(line.prefix(256))
                        line = Data()
                    }
                }
                guard let newline else { break }
                start = newline + 1
                let response: Data?
                if oversized {
                    response = ControlProtocol.failure(id: oversizedID, message: Self.tooLargeMessage)
                    oversized = false
                } else if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) {
                    response = nil
                } else {
                    response = respond(to: line)
                }
                line = Data()
                if let response, !Self.write(response, to: client) { return }
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
        if isStopped { return ControlProtocol.failure(id: request.id, message: "Fudehand is quitting") }
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
        guard bytes.count < capacity else { throw ControlCommandError("Control channel path is too long: \(path)") }
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
