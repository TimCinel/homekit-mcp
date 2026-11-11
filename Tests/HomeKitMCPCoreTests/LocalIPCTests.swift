#if os(macOS)
import XCTest
import Darwin
@testable import HomeKitMCPCore

final class LocalIPCTests: XCTestCase {
    private func directory() -> String { "/tmp/homekit-test-" + UUID().uuidString.prefix(8) }
    private func connect(_ directory: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = (directory + "/s").utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { target in path.withUnsafeBytes { target.copyBytes(from: $0) } }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0 else { Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
    private func factory() -> ModernMCPRouter {
        ModernMCPRouter(tools: []) { _, done in done(["content": []]) }
    }
    private func stopped(_ host: MCPLocalServer) {
        let done = expectation(description: "stopped")
        host.stop { done.fulfill() }
        wait(for: [done], timeout: 3)
    }
    func testOwnerPermissionsAndCompetingInstanceRejected() throws {
        let path = directory()
        let host = try MCPLocalServer(directory: path, factory: factory)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(path + "/s", &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertThrowsError(try MCPLocalServer(directory: path, factory: factory))
        stopped(host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/s"))
    }
    func testUnsafeDirectoryAndSymlinkRejected() throws {
        let path = directory()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try MCPLocalServer(directory: path, factory: factory))
        let link = path + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertThrowsError(try MCPLocalServer(directory: link, factory: factory))
    }
    func testRestartInsideStopCompletionReleasesLockFirst() throws {
        let path = directory(), done = expectation(description: "restart")
        let host = try MCPLocalServer(directory: path, factory: factory)
        var restarted: MCPLocalServer?
        host.stop {
            do { restarted = try MCPLocalServer(directory: path, factory: self.factory) }
            catch { XCTFail("restart failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(restarted?.isRunning ?? false)
        if let restarted = restarted { stopped(restarted) }
        try? FileManager.default.removeItem(atPath: path)
    }
    func testFragmentedProductionRequestAndStringID() throws {
        let path = directory(), done = expectation(description: "response")
        let host = try MCPLocalServer(directory: path, factory: factory)
        let fd = try connect(path)
        DispatchQueue.global().async {
            defer { Darwin.close(fd); done.fulfill() }
            let line = Data("{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n".utf8)
            for byte in line { var byte = byte; _ = Darwin.send(fd, &byte, 1, 0) }
            var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.recv(fd, &bytes, bytes.count, 0)
                if count <= 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
            XCTAssertEqual(object?["id"] as? String, "x")
            XCTAssertNotNil(object?["result"])
        }
        wait(for: [done], timeout: 4)
        stopped(host); try? FileManager.default.removeItem(atPath: path)
    }
    func testAbsoluteDeadlineClosesAnIdleEstablishedConnection() throws {
        let path = directory(), done = expectation(description: "deadline")
        let host = try MCPLocalServer(directory: path, lifetime: 0.15, factory: factory)
        let fd = try connect(path)
        DispatchQueue.global().async {
            defer { Darwin.close(fd); done.fulfill() }
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(fd, &byte, 1, 0), 0)
        }
        wait(for: [done], timeout: 2)
        stopped(host); try? FileManager.default.removeItem(atPath: path)
    }
    func testStopClosesAnEstablishedConnection() throws {
        let path = directory(), done = expectation(description: "closed")
        let host = try MCPLocalServer(directory: path, factory: factory)
        let fd = try connect(path)
        // Ensure the accept event has run before testing teardown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { host.stop() }
        DispatchQueue.global().async {
            defer { Darwin.close(fd); done.fulfill() }
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(fd, &byte, 1, 0), 0)
        }
        wait(for: [done], timeout: 2)
        // Drain the asynchronous listener cancel completion before removing test files.
        let drained = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        try? FileManager.default.removeItem(atPath: path)
    }
}
#endif
