#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Darwin
// File-permission authenticated IPC. No TCP listener, password, or bearer token.
final class LocalConnection {
    enum State { case ready, cancelled, failed(Error) }
    enum Completion { case contentProcessed((Error?) -> Void) }
    var stateUpdateHandler: ((State) -> Void)?
    private let fd: Int32
    private let worker = DispatchQueue(label: "homekit-mcp.ipc.connection")
    private let lock = NSLock()
    private var cancelled = false
    init(_ fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(queue: DispatchQueue) { queue.async { [weak self] in self?.stateUpdateHandler?(.ready) } }
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Bool?, Bool, Error?) -> Void) {
        worker.async {
            guard !self.isCancelled else { return }
            var bytes = [UInt8](repeating: 0, count: maximumLength)
            let count = Darwin.recv(self.fd, &bytes, bytes.count, 0)
            let result = count > 0 ? Data(bytes.prefix(count)) : nil
            let error: Error? = count < 0 ? NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) : nil
            DispatchQueue.main.async {
                guard !self.isCancelled else { return }
                completion(result, nil, count <= 0, error)
            }
        }
    }
    func send(content: Data?, completion: Completion) {
        worker.async {
            var failure: Error?
            if !self.isCancelled, let content = content {
                content.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count, !self.isCancelled {
                        let count = Darwin.send(self.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else {
                            failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); break
                        }
                        offset += count
                    }
                }
            }
            DispatchQueue.main.async {
                if case .contentProcessed(let callback) = completion { callback(failure) }
            }
        }
    }
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        // Keep fd allocated until the serial worker finishes its active syscall.
        Darwin.shutdown(fd, SHUT_RDWR)
        lock.unlock()
        worker.async { Darwin.close(self.fd) }
        DispatchQueue.main.async { [weak self] in self?.stateUpdateHandler?(.cancelled) }
    }
}

final class LocalListener {
    private let fd: Int32
    private let lockFD: Int32
    private let socketPath: String
    private var socketInode: ino_t = 0
    private var source: DispatchSourceRead?
    private var stopped = false
    private var onStopped: (() -> Void)?
    var newConnectionHandler: ((LocalConnection) -> Void)?
    init(directory: String? = nil) throws {
        let parent = directory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".homekit-mcp").path
        func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if Darwin.mkdir(parent, 0o700) != 0, errno != EEXIST { throw failure() }
        var st = stat()
        guard lstat(parent, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == geteuid(), (st.st_mode & 0o777) == 0o700 else {
            throw NSError(domain: "LocalIPC", code: 1)
        }
        socketPath = parent + "/s"
        lockFD = Darwin.open(parent + "/server.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw failure() }
        guard fstat(lockFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == geteuid(), (st.st_mode & 0o777) == 0o600,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); throw NSError(domain: "LocalIPC", code: 2)
        }
        if lstat(socketPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == geteuid() else {
                Darwin.close(lockFD); throw NSError(domain: "LocalIPC", code: 3)
            }
            guard unlink(socketPath) == 0 else { Darwin.close(lockFD); throw failure() }
        } else if errno != ENOENT { Darwin.close(lockFD); throw failure() }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Darwin.close(lockFD); throw failure() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); Darwin.close(lockFD); throw NSError(domain: "LocalIPC", code: 4)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            pathBytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0,
              Darwin.listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd); unlink(socketPath); Darwin.close(lockFD); throw failure()
        }
        guard lstat(socketPath, &st) == 0 else {
            Darwin.close(fd); unlink(socketPath); Darwin.close(lockFD); throw failure()
        }
        socketInode = st.st_ino
    }
    func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        read.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Limit accept work per main-queue event.
            for _ in 0..<16 {
                let accepted = Darwin.accept(self.fd, nil, nil)
                if accepted < 0 { break }
                guard fcntl(accepted, F_SETFL, 0) == 0 else { Darwin.close(accepted); continue }
                var peerUID = uid_t(), peerGID = gid_t()
                guard getpeereid(accepted, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                    Darwin.close(accepted); continue
                }
                if let handler = self.newConnectionHandler { handler(LocalConnection(accepted)) }
                else { Darwin.close(accepted) }
            }
        }
        let listenerFD = fd, heldLock = lockFD, path = socketPath, inode = socketInode
        read.setCancelHandler { [weak self] in
            Darwin.close(listenerFD)
            var st = stat()
            if lstat(path, &st) == 0, st.st_ino == inode,
               (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == geteuid() { unlink(path) }
            Darwin.close(heldLock)
            self?.onStopped?()
            self?.onStopped = nil
        }
        source = read
        read.resume()
    }
    func cancel(completion: (() -> Void)? = nil) {
        guard !stopped else { return }
        stopped = true
        onStopped = completion
        newConnectionHandler = nil
        source?.cancel()
        source = nil
    }
    deinit { cancel() }
}


/// Production connection limits, deadlines and framing; tested without loading HomeKit.
final class MCPLocalServer {
    private var listener: LocalListener?
    private var connections: [ObjectIdentifier: LocalConnection] = [:]
    private var routers: [ObjectIdentifier: ModernMCPRouter] = [:]
    private let factory: () -> ModernMCPRouter
    private let lifetime: Double
    private(set) var isRunning = false
    init(directory: String? = nil, lifetime: Double = 45, factory: @escaping () -> ModernMCPRouter) throws {
        self.factory = factory
        self.lifetime = lifetime
        let listener = try LocalListener(directory: directory)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.isRunning else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start()
        isRunning = true
    }
    func stop(completion: @escaping () -> Void = {}) {
        isRunning = false
        for router in routers.values { router.close() }
        routers.removeAll()
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active { connection.cancel() }
        guard let listener = listener else { completion(); return }
        listener.cancel { [weak self, listener] in
            _ = listener
            self?.listener = nil
            completion()
        }
    }
    private func accept(_ connection: LocalConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        routers[key] = factory()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready: self.receive(connection, buffer: MCPLineBuffer())
            case .cancelled, .failed:
                self.routers.removeValue(forKey: key)?.close()
                self.connections.removeValue(forKey: key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak connection] in connection?.cancel() }
        connection.start(queue: .main)
    }
    private func receive(_ connection: LocalConnection, buffer: MCPLineBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, eof, error in
            guard let self = self, self.isRunning, error == nil else { connection.cancel(); return }
            var buffer = buffer
            do {
                let lines = try buffer.append(data ?? Data())
                guard lines.count <= 1, !(lines.count == 1 && buffer.hasPartialMessage) else {
                    connection.cancel(); return
                }
                if let line = lines.first {
                    let key = ObjectIdentifier(connection)
                    guard let router = self.routers[key] else { connection.cancel(); return }
                    var replied = false
                    router.handle(line) { [weak self, weak connection] response in
                        guard let self = self, self.isRunning, let connection = connection,
                              self.connections[key] === connection else { return }
                        replied = true
                        connection.send(content: response + Data([10]), completion: .contentProcessed { _ in connection.cancel() })
                    }
                    if !replied, !router.hasPendingRequests { connection.cancel() }
                } else if eof { connection.cancel() }
                else { self.receive(connection, buffer: buffer) }
            } catch { connection.cancel() }
        }
    }
    deinit { stop() }
}
#endif
