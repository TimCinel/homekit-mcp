import Foundation
import HomeKit

// MARK: - MCP Protocol Models

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: AnyEncodable]?
}

struct MCPResponse: Codable {
    let jsonrpc: String
    let id: Int?
    let result: [String: AnyEncodable]?
    let error: MCPError?
}

struct MCPError: Codable {
    let code: Int
    let message: String
}

struct AnyEncodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        } else if let arrayValue = value as? [Any] {
            try container.encode(arrayValue.map { AnyEncodable($0) })
        } else if let dictValue = value as? [String: Any] {
            try container.encode(dictValue.mapValues { AnyEncodable($0) })
        } else {
            try container.encodeNil()
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let arrayValue = try? container.decode([AnyEncodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyEncodable].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}

// MARK: - HomeKit MCP Server

class HomeKitMCPServer: NSObject, HMHomeManagerDelegate {
    private let homeManager = HMHomeManager()
    private var isReady = false
    
    override init() {
        super.init()
        homeManager.delegate = self
        setupServer()
    }
    
    private func setupServer() {
        // Wait for HomeKit to be ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.startServer()
        }
    }
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        isReady = true
    }
    
    private func startServer() {
        sendServerInfo()
        
        // Main server loop
        while let line = readLine() {
            handleRequest(line)
        }
    }
    
    private func sendServerInfo() {
        let serverInfo: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [
                        "listChanged": true
                    ]
                ],
                "serverInfo": [
                    "name": "homekit-mcp-server",
                    "version": "1.0.0"
                ]
            ]
        ]
        
        sendResponse(serverInfo)
    }
    
    private func handleRequest(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: data)
            
            switch request.method {
            case "tools/list":
                handleToolsList(request)
            case "tools/call":
                handleToolCall(request)
            case "initialize":
                handleInitialize(request)
            default:
                sendError(request.id, code: -32601, message: "Method not found")
            }
        } catch {
            sendError(nil, code: -32700, message: "Parse error")
        }
    }
    
    private func handleInitialize(_ request: MCPRequest) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": request.id ?? 0,
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [:]
                ],
                "serverInfo": [
                    "name": "homekit-mcp-server",
                    "version": "1.0.0"
                ]
            ]
        ]
        
        sendResponse(response)
    }
    
    private func handleToolsList(_ request: MCPRequest) {
        let tools: [[String: Any]] = [
            [
                "name": "get_all_accessories",
                "description": "Get all HomeKit accessories with their names, rooms, and UUIDs",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ],
            [
                "name": "get_all_rooms",
                "description": "Get all HomeKit rooms with their names and UUIDs",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ],
            [
                "name": "set_accessory_room",
                "description": "Move an accessory to a different room",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_uuid": [
                            "type": "string",
                            "description": "UUID of the accessory to move"
                        ],
                        "room_uuid": [
                            "type": "string",
                            "description": "UUID of the target room"
                        ]
                    ],
                    "required": ["accessory_uuid", "room_uuid"]
                ]
            ]
        ]
        
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": request.id ?? 0,
            "result": [
                "tools": tools
            ]
        ]
        
        sendResponse(response)
    }
    
    private func handleToolCall(_ request: MCPRequest) {
        guard let params = request.params,
              let toolName = params["name"]?.value as? String,
              let arguments = params["arguments"]?.value as? [String: Any] else {
            sendError(request.id, code: -32602, message: "Invalid params")
            return
        }
        
        switch toolName {
        case "get_all_accessories":
            handleGetAllAccessories(request)
        case "get_all_rooms":
            handleGetAllRooms(request)
        case "set_accessory_room":
            handleSetAccessoryRoom(request, arguments: arguments)
        default:
            sendError(request.id, code: -32601, message: "Tool not found")
        }
    }
    
    private func handleGetAllAccessories(_ request: MCPRequest) {
        var accessories: [[String: Any]] = []
        
        for home in homeManager.homes {
            for accessory in home.accessories {
                accessories.append([
                    "name": accessory.name,
                    "room": accessory.room?.name ?? "No Room",
                    "uuid": accessory.uniqueIdentifier.uuidString,
                    "home": home.name
                ])
            }
        }
        
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": request.id ?? 0,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "Found \(accessories.count) accessories:\n" + 
                               accessories.map { acc in
                                   let name = acc["name"] as! String
                                   let room = acc["room"] as! String
                                   let uuid = acc["uuid"] as! String
                                   return "• \(name) (Room: \(room), UUID: \(uuid))"
                               }.joined(separator: "\n")
                    ]
                ],
                "_meta": [
                    "accessories": accessories
                ]
            ]
        ]
        
        sendResponse(response)
    }
    
    private func handleGetAllRooms(_ request: MCPRequest) {
        var rooms: [[String: Any]] = []
        
        for home in homeManager.homes {
            for room in home.rooms {
                rooms.append([
                    "name": room.name,
                    "uuid": room.uniqueIdentifier.uuidString,
                    "home": home.name
                ])
            }
        }
        
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": request.id ?? 0,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "Found \(rooms.count) rooms:\n" + 
                               rooms.map { room in
                                   "• \(room["name"] as! String) (UUID: \(room["uuid"] as! String))"
                               }.joined(separator: "\n")
                    ]
                ],
                "_meta": [
                    "rooms": rooms
                ]
            ]
        ]
        
        sendResponse(response)
    }
    
    private func handleSetAccessoryRoom(_ request: MCPRequest, arguments: [String: Any]) {
        guard let accessoryUUIDString = arguments["accessory_uuid"] as? String,
              let roomUUIDString = arguments["room_uuid"] as? String,
              let accessoryUUID = UUID(uuidString: accessoryUUIDString),
              let roomUUID = UUID(uuidString: roomUUIDString) else {
            sendError(request.id, code: -32602, message: "Invalid UUIDs")
            return
        }
        
        // Find the accessory and room
        var foundAccessory: HMAccessory?
        var foundRoom: HMRoom?
        var foundHome: HMHome?
        
        for home in homeManager.homes {
            if foundAccessory == nil {
                foundAccessory = home.accessories.first { $0.uniqueIdentifier == accessoryUUID }
                if foundAccessory != nil {
                    foundHome = home
                }
            }
            if foundRoom == nil {
                foundRoom = home.rooms.first { $0.uniqueIdentifier == roomUUID }
            }
        }
        
        guard let accessory = foundAccessory,
              let room = foundRoom,
              let home = foundHome else {
            sendError(request.id, code: -32603, message: "Accessory or room not found")
            return
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var moveResult: String = ""
        
        home.assignAccessory(accessory, to: room) { error in
            if let error = error {
                moveResult = "❌ Failed to move \(accessory.name) to \(room.name): \(error.localizedDescription)"
            } else {
                moveResult = "✅ Successfully moved \(accessory.name) to \(room.name)"
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": request.id ?? 0,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": moveResult
                    ]
                ]
            ]
        ]
        
        sendResponse(response)
    }
    
    private func sendError(_ id: Int?, code: Int, message: String) {
        let error: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        
        sendResponse(error)
    }
    
    private func sendResponse(_ response: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [])
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
                fflush(stdout)
            }
        } catch {
            print("Error encoding response: \(error)")
        }
    }
}

// MARK: - Original stdio-based server (kept for reference)
