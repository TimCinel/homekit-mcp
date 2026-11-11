import Foundation
import CoreFoundation

/// Production framing shared by the Catalyst app and the dependency-free test target.
public struct MCPLineBuffer {
    public static let maximumBytes = 65536
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard newline <= Self.maximumBytes else { throw MCPWireError.invalidFrame }
            let line = Data(buffer[..<newline])
            guard !line.isEmpty, String(data: line, encoding: .utf8) != nil else {
                throw MCPWireError.invalidFrame
            }
            lines.append(line)
            buffer.removeSubrange(...newline)
        }
        guard buffer.count <= Self.maximumBytes else { throw MCPWireError.invalidFrame }
        return lines
    }
    public var hasPartialMessage: Bool { !buffer.isEmpty }
}

public enum MCPWireError: Error { case invalidFrame }

public enum MCPID: Hashable {
    case string(String)
    case integer(Int64)
    var json: Any {
        switch self { case .string(let value): return value; case .integer(let value): return value }
    }
    static func parse(_ value: Any?) -> MCPID? {
        if let value = value as? String, value.utf8.count <= 256 { return .string(value) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !String(cString: number.objCType).contains("f"),
              !String(cString: number.objCType).contains("d"),
              let integer = Int64(number.stringValue) else { return nil }
        return .integer(integer)
    }
}

public struct MCPToolCall {
    public let name: String
    public let arguments: [String: Any]
}

/// Stateless MCP 2026-07-28 request semantics; connection state tracks only in-flight IDs.
/// Invoke on one serial queue (the app uses the main queue). Never trust clientInfo as identity.
public final class ModernMCPRouter {
    public static let version = "2026-07-28"
    public typealias Completion = ([String: Any]) -> Void
    public typealias Executor = (MCPToolCall, @escaping Completion) -> Void
    private let tools: [[String: Any]]
    private let execute: Executor
    private var pending: [MCPID: UUID] = [:]
    private var closed = false
    public init(tools: [[String: Any]], execute: @escaping Executor) {
        self.tools = tools
        self.execute = execute
    }
    public var hasPendingRequests: Bool { !pending.isEmpty }
    public func close() { closed = true; pending.removeAll() }
    public func handle(_ data: Data, emit: @escaping (Data) -> Void) {
        guard !closed else { return }
        func error(_ id: MCPID?, _ code: Int, _ message: String, _ extra: [String: Any]? = nil) {
            var detail: [String: Any] = ["code": code, "message": message]
            if let extra = extra { detail["data"] = extra }
            var reply: [String: Any] = ["jsonrpc": "2.0", "error": detail]
            if let id = id { reply["id"] = id.json }
            if let bytes = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) { emit(bytes) }
        }
        guard data.count <= MCPLineBuffer.maximumBytes, Self.boundedJSON(data),
              let text = String(data: data, encoding: .utf8), !text.hasPrefix("\u{FEFF}"),
              let raw = try? JSONSerialization.jsonObject(with: data) else {
            error(nil, -32700, "Parse error"); return
        }
        guard Self.uniqueKeys(data) else { error(nil, -32700, "Duplicate JSON object key"); return }
        guard let request = raw as? [String: Any] else { error(nil, -32600, "Invalid Request"); return }
        let id = MCPID.parse(request["id"])
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String, !method.isEmpty,
              request["params"] == nil || request["params"] is [String: Any],
              request["id"] == nil || id != nil else {
            error(id, -32600, "Invalid Request"); return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        // Notifications never receive responses, including malformed/unknown notifications.
        guard let id = id else {
            if method == "notifications/cancelled", let target = MCPID.parse(params["requestId"]) {
                pending.removeValue(forKey: target)
            }
            return
        }
        guard pending[id] == nil else {
            // Do not permit duplicate IDs to replace a previous completion/cancellation token.
            pending.removeValue(forKey: id)
            error(id, -32600, "Request ID already in flight"); return
        }
        if method == "initialize" {
            error(id, -32601, "This server supports MCP 2026-07-28; use server/discover and per-request metadata"); return
        }
        guard let meta = params["_meta"] as? [String: Any],
              let version = meta["io.modelcontextprotocol/protocolVersion"] as? String,
              meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
            error(id, -32602, "Required per-request MCP metadata missing"); return
        }
        guard version == Self.version else {
            error(id, -32022, "Unsupported protocol version", ["supported": [Self.version], "requested": version]); return
        }
        func result(_ body: [String: Any]) {
            var body = body
            body["resultType"] = "complete"
            body["_meta"] = ["io.modelcontextprotocol/serverInfo": ["name": "homekit-mcp", "version": "2.0.0"]]
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": id.json, "result": body]
            if let bytes = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]), bytes.count <= 1048576 {
                emit(bytes)
            } else { error(id, -32603, "Response unavailable or too large") }
        }
        switch method {
        case "server/discover":
            result(["supportedVersions": [Self.version], "capabilities": ["tools": [:]], "instructions": "Read-only local HomeKit inventory; writes unsupported."])
        case "ping": result([:])
        case "tools/list":
            guard params["cursor"] == nil else { error(id, -32602, "Invalid cursor"); return }
            result(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String,
                  let tool = tools.first(where: { $0["name"] as? String == name }),
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                error(id, -32602, "Unknown tool or invalid arguments"); return
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any],
                  Set(args.keys).isSubset(of: Set(properties.keys)),
                  (schema["required"] as? [String] ?? []).allSatisfy({ args[$0] != nil }),
                  args.allSatisfy({ key, value in
                      guard let definition = properties[key] as? [String: Any] else { return false }
                      if definition["type"] as? String == "string" { return value is String }
                      return false
                  }) else { error(id, -32602, "Invalid tool arguments"); return }
            guard pending.count < 8 else { error(id, -32603, "Too many requests in flight"); return }
            let token = UUID()
            pending[id] = token
            execute(MCPToolCall(name: name, arguments: args)) { [weak self] body in
                guard let self = self, !self.closed, self.pending[id] == token else { return }
                self.pending.removeValue(forKey: id)
                result(body)
            }
        case "initialize":
            error(id, -32601, "This server supports MCP 2026-07-28; use server/discover and per-request metadata")
        default: error(id, -32601, "Method not found")
        }
    }
    // Foundation rejects malformed JSON but accepts duplicate keys; reject ambiguous objects.
    private static func uniqueKeys(_ data: Data) -> Bool {
        struct Scope { var keys: Set<String>?; var expectingKey = true }
        let bytes = Array(data)
        var stack: [Scope] = [], index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    let value = bytes[index]
                    if escaped { escaped = false }
                    else if value == 92 { escaped = true }
                    else if value == 34 { break }
                    index += 1
                }
                if let scope = stack.last, scope.keys != nil, scope.expectingKey {
                    guard index < bytes.count,
                          let key = try? JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: [.fragmentsAllowed]) as? String,
                          !scope.keys!.contains(key) else { return false }
                    stack[stack.count - 1].keys!.insert(key)
                }
            } else if byte == 123 { stack.append(Scope(keys: [])) }
            else if byte == 91 { stack.append(Scope(keys: nil)) }
            else if byte == 125 || byte == 93 { if !stack.isEmpty { stack.removeLast() } }
            else if byte == 58, !stack.isEmpty { stack[stack.count - 1].expectingKey = false }
            else if byte == 44, !stack.isEmpty { stack[stack.count - 1].expectingKey = true }
            index += 1
        }
        return true
    }

    // Bound nesting before Foundation parses attacker-controlled JSON.
    private static func boundedJSON(_ data: Data) -> Bool {
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 32 { return false } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0 && !quoted
    }
}
