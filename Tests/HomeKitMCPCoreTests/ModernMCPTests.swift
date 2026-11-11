import XCTest
@testable import HomeKitMCPCore

final class ModernMCPTests: XCTestCase {
    private let tool: [String: Any] = ["name": "inventory", "inputSchema": ["type": "object", "properties": [:]]]
    private func request(_ method: String = "tools/call", id: Any = "r1", args: [String: Any] = [:], version: String = ModernMCPRouter.version) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": ["name": "inventory", "arguments": args, "_meta": ["io.modelcontextprotocol/protocolVersion": version, "io.modelcontextprotocol/clientCapabilities": [:]]]]
    }
    private func send(_ value: Any, router: ModernMCPRouter? = nil) throws -> [[String: Any]] {
        let router = router ?? ModernMCPRouter(tools: [tool]) { _, done in done(["content": []]) }
        var replies: [[String: Any]] = []
        router.handle(try JSONSerialization.data(withJSONObject: value)) { bytes in
            replies.append((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:])
        }
        return replies
    }
    private func code(_ result: [[String: Any]]) -> Int? { (result.first?["error"] as? [String: Any])?["code"] as? Int }
    func testDiscoverAndResultMetadata() throws {
        let replies = try send(request("server/discover"))
        XCTAssertEqual(replies.first?["id"] as? String, "r1")
        let result = try XCTUnwrap(replies.first?["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertNotNil(result["_meta"])
    }
    func testUnknownVersionGivesSupportedList() throws {
        let replies = try send(request(version: "1900-01-01"))
        XCTAssertEqual(code(replies), -32022)
        let data = (replies[0]["error"] as? [String: Any])?["data"] as? [String: Any]
        XCTAssertEqual(data?["supported"] as? [String], ["2026-07-28"])
    }
    func testRequiresVersionAndCapabilitiesPerRequest() throws {
        for meta: [String: Any] in [[:], ["io.modelcontextprotocol/protocolVersion": "2026-07-28"], ["io.modelcontextprotocol/clientCapabilities": [:]]] {
            var value = request(); value["params"] = ["_meta": meta]
            XCTAssertEqual(code(try send(value)), -32602)
        }
    }
    func testStringAndIntegerIDsIncludingZero() throws {
        for id: Any in ["hello", 0, -5, Int64.max] {
            XCTAssertNotNil(try send(request("ping", id: id)).first?["result"])
        }
    }
    func testBooleanFractionNullIDsRejected() throws {
        for id: Any in [true, 1.25, NSNull()] { XCTAssertEqual(code(try send(request(id: id))), -32600) }
    }
    func testNotificationNeverRepliesOrExecutes() throws {
        var calls = 0
        let router = ModernMCPRouter(tools: [tool]) { _, _ in calls += 1 }
        var value = request(); value.removeValue(forKey: "id")
        XCTAssertTrue(try send(value, router: router).isEmpty)
        XCTAssertEqual(calls, 0)
    }
    func testNoBatchSupport() throws { XCTAssertEqual(code(try send([request()])), -32600) }
    func testInvalidJsonAndDeepInputAreBounded() {
        let router = ModernMCPRouter(tools: [tool]) { _, _ in XCTFail("must not execute") }
        for data in [Data("{".utf8), Data((String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)).utf8), Data([0xff])] {
            var result: [String: Any] = [:]
            router.handle(data) { result = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
            XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? Int, -32700)
        }
    }
    func testUnknownOrWriteToolCannotExecute() throws {
        var calls = 0
        let router = ModernMCPRouter(tools: [tool]) { _, _ in calls += 1 }
        var value = request(); var params = value["params"] as! [String: Any]
        params["name"] = "accessory_on"; value["params"] = params
        XCTAssertEqual(code(try send(value, router: router)), -32602)
        XCTAssertEqual(calls, 0)
    }
    func testExtraArgumentsCannotExecute() throws {
        let router = ModernMCPRouter(tools: [tool]) { _, _ in XCTFail("must not execute") }
        XCTAssertEqual(code(try send(request(args: ["shell": "ignored"]), router: router)), -32602)
    }
    func testCancelledCompletionSuppressedAndIDReuseSafe() throws {
        var callbacks: [ModernMCPRouter.Completion] = []
        let router = ModernMCPRouter(tools: [tool]) { _, done in callbacks.append(done) }
        var replies = 0
        let bytes = try JSONSerialization.data(withJSONObject: request())
        router.handle(bytes) { _ in replies += 1 }
        router.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "r1"]])) { _ in XCTFail("notification reply") }
        router.handle(bytes) { _ in replies += 1 }
        callbacks[0](["content": []]); XCTAssertEqual(replies, 0)
        callbacks[1](["content": []]); XCTAssertEqual(replies, 1)
    }
    func testClosedConnectionSuppressesCompletion() throws {
        var callback: ModernMCPRouter.Completion?
        let router = ModernMCPRouter(tools: [tool]) { _, done in callback = done }
        router.handle(try JSONSerialization.data(withJSONObject: request())) { _ in XCTFail("closed response") }
        router.close(); callback?(["content": []])
    }
    func testOutstandingRequestsBounded() throws {
        let router = ModernMCPRouter(tools: [tool]) { _, _ in }
        for index in 0..<8 { XCTAssertTrue(try send(request(id: index), router: router).isEmpty) }
        XCTAssertEqual(code(try send(request(id: 9), router: router)), -32603)
    }
    func testDuplicateInFlightIDDoesNotExecuteAgain() throws {
        var calls = 0
        let router = ModernMCPRouter(tools: [tool]) { _, _ in calls += 1 }
        XCTAssertTrue(try send(request(), router: router).isEmpty)
        XCTAssertEqual(code(try send(request(), router: router)), -32600)
        XCTAssertEqual(calls, 1)
    }
    func testUnsupportedLegacyHandshakeIsExplicit() throws {
        XCTAssertEqual(code(try send(request("initialize"))), -32601)
    }
    func testOmittedEmptyArgumentsAccepted() throws {
        var value = request(); var params = value["params"] as! [String: Any]
        params.removeValue(forKey: "arguments"); value["params"] = params
        XCTAssertNotNil(try send(value).first?["result"])
    }
    func testDuplicateEscapedKeysRejected() {
        let router = ModernMCPRouter(tools: [tool]) { _, _ in XCTFail("duplicate keys must not execute") }
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"x":1,"\u0078":2}}}"#.utf8)
        var reply: [String: Any] = [:]
        router.handle(raw) { reply = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
    func testLegacyInitializeWithoutMetadataExplainsUpgrade() throws {
        let replies = try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        XCTAssertEqual(code(replies), -32601)
        XCTAssertTrue(((replies[0]["error"] as? [String: Any])?["message"] as? String ?? "").contains("2026-07-28"))
    }
    func testOversizedResponseIsBounded() throws {
        let router = ModernMCPRouter(tools: [tool]) { _, done in done(["content": String(repeating: "x", count: 1048577)]) }
        XCTAssertEqual(code(try send(request(), router: router)), -32603)
    }
    func testMultipleFramesAndFragmentation() throws {
        var buffer = MCPLineBuffer()
        XCTAssertTrue(try buffer.append(Data("{\"a\":".utf8)).isEmpty)
        XCTAssertEqual(try buffer.append(Data("1}\n{}\n".utf8)).count, 2)
        XCTAssertFalse(buffer.hasPartialMessage)
    }
    func testFramingLimitsAndInvalidUTF8() throws {
        var buffer = MCPLineBuffer()
        XCTAssertTrue(try buffer.append(Data(repeating: 32, count: MCPLineBuffer.maximumBytes)).isEmpty)
        XCTAssertThrowsError(try buffer.append(Data([32])))
        var invalid = MCPLineBuffer()
        XCTAssertThrowsError(try invalid.append(Data([255, 10])))
        var empty = MCPLineBuffer()
        XCTAssertThrowsError(try empty.append(Data([10])))
    }
}
