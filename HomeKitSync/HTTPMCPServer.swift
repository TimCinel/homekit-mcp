import Foundation
import HomeKit
import Network

class HTTPMCPServer: NSObject, HMHomeManagerDelegate {
    private let homeManager = HMHomeManager()
    private var isReady = false
    private let port: UInt16 = 8080
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let encoder = JSONEncoder()
    
    override init() {
        super.init()
        print("🚀 [MCP] Initializing HomeKit MCP Server...")
        homeManager.delegate = self
        setupHTTPServer()
    }
    
    private func setupHTTPServer() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            guard let port = NWEndpoint.Port(rawValue: port) else {
                print("Failed to create port \(self.port)")
                return
            }
            listener = try NWListener(using: parameters, on: port)
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("HTTP MCP Server listening on port \(self.port)")
                case .failed(let error):
                    print("HTTP Server failed: \(error)")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { connection in
                self.handleNewConnection(connection)
            }
            
            listener?.start(queue: .main)
        } catch {
            print("Failed to create listener: \(error)")
        }
    }
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        print("🏠 [HomeKit] Homes updated. Found \(manager.homes.count) homes:")
        for home in manager.homes {
            print("   - \(home.name): \(home.accessories.count) accessories, \(home.rooms.count) rooms")
        }
        isReady = true
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("New connection established")
                self.receiveMessage(on: connection)
            case .cancelled:
                self.connections.removeAll { $0 === connection }
            case .failed(let error):
                print("Connection failed: \(error)")
                self.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        
        connection.start(queue: .main)
    }
    
    private func receiveMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error = error {
                print("Receive error: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                self.handleHTTPRequest(data: data, connection: connection)
            }
            
            if !isComplete {
                self.receiveMessage(on: connection)
            }
        }
    }
    
    private func handleHTTPRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendHTTPError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            sendHTTPError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        
        let method = components[0]
        let path = components[1]
        
        print("📥 [HTTP] \(method) \(path)")
        
        switch (method, path) {
        case ("GET", "/events"):
            handleSSEConnection(connection: connection)
        case ("POST", "/mcp"):
            handleMCPRequest(data: data, connection: connection)
        case ("GET", "/mcp"):
            handleMCPDiscovery(connection: connection)
        case ("POST", "/mcp/initialize"):
            handleMCPInitialize(data: data, connection: connection)
        case ("POST", "/mcp/tools/list"):
            handleMCPToolsList(data: data, connection: connection)
        case ("POST", "/mcp/tools/call"):
            handleMCPToolsCall(data: data, connection: connection)
        case ("GET", "/"):
            sendHTTPResponse(connection: connection, body: getWelcomeHTML())
        default:
            print("❌ [HTTP] 404 for \(method) \(path)")
            sendHTTPError(connection: connection, status: 404, message: "Not Found")
        }
    }
    
    private func handleSSEConnection(connection: NWConnection) {
        let headers = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-cache\r
            Connection: keep-alive\r
            Access-Control-Allow-Origin: *\r
            \r
            
            """
        
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("Failed to send SSE headers: \(error)")
                return
            }
            
            // Send initial server info
            self.sendSSEEvent(connection: connection, event: "server-info", data: [
                "name": "homekit-mcp-server",
                "version": "1.0.0",
                "tools": ["get_all_accessories", "get_all_rooms", "set_accessory_room"]
            ])
        })
    }
    
    private func handleMCPDiscovery(connection: NWConnection) {
        let discovery: [String: Any] = [
            "version": "2024-11-05",
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "homekit-mcp-server",
                "version": "1.0.0"
            ]
        ]
        
        do {
            let responseData = try JSONSerialization.data(withJSONObject: discovery)
            sendHTTPResponse(connection: connection, body: responseData)
        } catch {
            sendHTTPError(connection: connection, status: 500, message: "Internal Server Error")
        }
    }
    
    private func handleMCPInitialize(data: Data, connection: NWConnection) {
        guard let jsonData = extractJSONFromHTTP(data: data) else {
            sendHTTPError(connection: connection, status: 400, message: "Invalid request")
            return
        }
        
        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: jsonData)
            let response = handleInitialize(request)
            let responseData = try encoder.encode(response)
            sendHTTPResponse(connection: connection, body: responseData)
        } catch {
            sendHTTPError(connection: connection, status: 400, message: "Invalid MCP request")
        }
    }
    
    private func handleMCPToolsList(data: Data, connection: NWConnection) {
        guard let jsonData = extractJSONFromHTTP(data: data) else {
            sendHTTPError(connection: connection, status: 400, message: "Invalid request")
            return
        }
        
        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: jsonData)
            let response = handleToolsList(request)
            let responseData = try encoder.encode(response)
            sendHTTPResponse(connection: connection, body: responseData)
        } catch {
            sendHTTPError(connection: connection, status: 400, message: "Invalid MCP request")
        }
    }
    
    private func handleMCPToolsCall(data: Data, connection: NWConnection) {
        print("🔧 [MCP] Tool call received")
        
        guard let jsonData = extractJSONFromHTTP(data: data) else {
            print("❌ [MCP] Failed to extract JSON from HTTP request")
            sendHTTPError(connection: connection, status: 400, message: "Invalid request")
            return
        }
        
        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: jsonData)
            print("🔧 [MCP] Decoded request ID: \(request.id ?? -1)")
            
            let response = handleToolCall(request)
            print("📤 [MCP] Generated response for ID: \(response.id ?? -1)")
            
            let responseData = try encoder.encode(response)
            print("✅ [MCP] Sending response (\(responseData.count) bytes)")
            sendHTTPResponse(connection: connection, body: responseData)
        } catch {
            print("❌ [MCP] Error processing tool call: \(error)")
            let errorResponse = MCPResponse(
                jsonrpc: "2.0", 
                id: nil, 
                result: nil, 
                error: MCPError(code: -32603, message: "Internal error: \(error.localizedDescription)")
            )
            
            do {
                let errorData = try encoder.encode(errorResponse)
                sendHTTPResponse(connection: connection, body: errorData)
            } catch {
                sendHTTPError(connection: connection, status: 500, message: "Internal Server Error")
            }
        }
    }
    
    private func handleMCPRequest(data: Data, connection: NWConnection) {
        guard let jsonData = extractJSONFromHTTP(data: data) else {
            sendHTTPError(connection: connection, status: 400, message: "Invalid request")
            return
        }
        
        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: jsonData)
            let response = processMCPRequest(request)
            let responseData = try encoder.encode(response)
            
            sendHTTPResponse(connection: connection, body: responseData)
        } catch {
            sendHTTPError(connection: connection, status: 400, message: "Invalid MCP request: \(error)")
        }
    }
    
    private func extractJSONFromHTTP(data: Data) -> Data? {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let bodyStartIndex = lines.firstIndex(of: ""),
              bodyStartIndex + 1 < lines.count else {
            return nil
        }
        
        let bodyLines = Array(lines[(bodyStartIndex + 1)...])
        let jsonBody = bodyLines.joined(separator: "\r\n")
        
        return jsonBody.data(using: .utf8)
    }
    
    private func processMCPRequest(_ request: MCPRequest) -> MCPResponse {
        switch request.method {
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return handleToolCall(request)
        case "initialize":
            return handleInitialize(request)
        default:
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil, 
                              error: MCPError(code: -32601, message: "Method not found"))
        }
    }
    
    private func handleInitialize(_ request: MCPRequest) -> MCPResponse {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "homekit-mcp-server",
                "version": "1.0.0"
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: [
                            "protocolVersion": AnyEncodable("2024-11-05"),
                            "capabilities": AnyEncodable(["tools": [:]]),
                            "serverInfo": AnyEncodable([
                                "name": "homekit-mcp-server",
                                "version": "1.0.0"
                            ])
                          ], error: nil)
    }
    
    private func handleToolsList(_ request: MCPRequest) -> MCPResponse {
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
                "description": "Move an accessory to a different room using UUIDs",
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
            ],
            [
                "name": "get_accessory_by_name",
                "description": "Find a HomeKit accessory by name",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Name or partial name of the accessory to find"
                        ]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "get_room_by_name",
                "description": "Find a HomeKit room by name",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Name or partial name of the room to find"
                        ]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "set_accessory_room_by_name",
                "description": "Move an accessory to a different room using names",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": [
                            "type": "string",
                            "description": "Name of the accessory to move"
                        ],
                        "room_name": [
                            "type": "string",
                            "description": "Name of the target room"
                        ]
                    ],
                    "required": ["accessory_name", "room_name"]
                ]
            ],
            [
                "name": "rename_accessory",
                "description": "Rename a HomeKit accessory",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": [
                            "type": "string",
                            "description": "Current name of the accessory to rename"
                        ],
                        "new_name": [
                            "type": "string",
                            "description": "New name for the accessory"
                        ]
                    ],
                    "required": ["accessory_name", "new_name"]
                ]
            ],
            [
                "name": "rename_room",
                "description": "Rename a HomeKit room",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "room_name": [
                            "type": "string",
                            "description": "Current name of the room to rename"
                        ],
                        "new_name": [
                            "type": "string",
                            "description": "New name for the room"
                        ]
                    ],
                    "required": ["room_name", "new_name"]
                ]
            ],
            [
                "name": "get_room_accessories",
                "description": "Get all accessories in a specific room",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "room_name": [
                            "type": "string",
                            "description": "Name of the room to get accessories from"
                        ]
                    ],
                    "required": ["room_name"]
                ]
            ],
            [
                "name": "accessory_on",
                "description": "Turn on an accessory (lights, switches) or open covers",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": [
                            "type": "string",
                            "description": "Name of the accessory to turn on"
                        ]
                    ],
                    "required": ["accessory_name"]
                ]
            ],
            [
                "name": "accessory_off",
                "description": "Turn off an accessory (lights, switches) or close covers",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": [
                            "type": "string",
                            "description": "Name of the accessory to turn off"
                        ]
                    ],
                    "required": ["accessory_name"]
                ]
            ],
            [
                "name": "accessory_toggle",
                "description": "Toggle an accessory (lights, switches, covers) between on/off or open/close",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": [
                            "type": "string",
                            "description": "Name of the accessory to toggle"
                        ]
                    ],
                    "required": ["accessory_name"]
                ]
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: ["tools": AnyEncodable(tools)], error: nil)
    }
    
    private func handleToolCall(_ request: MCPRequest) -> MCPResponse {
        guard let params = request.params,
              let toolName = params["name"]?.value as? String,
              let arguments = params["arguments"]?.value as? [String: Any] else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Invalid params"))
        }
        
        switch toolName {
        case "get_all_accessories":
            return handleGetAllAccessories(request)
        case "get_all_rooms":
            return handleGetAllRooms(request)
        case "set_accessory_room":
            return handleSetAccessoryRoom(request, arguments: arguments)
        case "get_accessory_by_name":
            return handleGetAccessoryByName(request, arguments: arguments)
        case "get_room_by_name":
            return handleGetRoomByName(request, arguments: arguments)
        case "set_accessory_room_by_name":
            return handleSetAccessoryRoomByName(request, arguments: arguments)
        case "rename_accessory":
            return handleRenameAccessory(request, arguments: arguments)
        case "rename_room":
            return handleRenameRoom(request, arguments: arguments)
        case "get_room_accessories":
            return handleGetRoomAccessories(request, arguments: arguments)
        case "accessory_on":
            return handleAccessoryOn(request, arguments: arguments)
        case "accessory_off":
            return handleAccessoryOff(request, arguments: arguments)
        case "accessory_toggle":
            return handleAccessoryToggle(request, arguments: arguments)
        default:
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32601, message: "Tool not found"))
        }
    }
    
    private func handleGetAllAccessories(_ request: MCPRequest) -> MCPResponse {
        var accessories: [[String: Any]] = []
        
        for home in homeManager.homes {
            for accessory in home.accessories {
                let categoryName = getCategoryName(for: accessory.category)
                accessories.append([
                    "name": accessory.name,
                    "room": accessory.room?.name ?? "No Room",
                    "uuid": accessory.uniqueIdentifier.uuidString,
                    "home": home.name,
                    "category": categoryName,
                    "reachable": accessory.isReachable,
                    "firmware": getAccessoryFirmware(accessory),
                    "serial_number": getAccessorySerialNumber(accessory)
                ])
            }
        }
        
        let content = [
            [
                "type": "text",
                "text": "Found \(accessories.count) accessories:\n" + 
                       accessories.map { acc in
                           let name = acc["name"] as! String
                           let category = acc["category"] as! String
                           let room = acc["room"] as! String
                           let uuid = acc["uuid"] as! String
                           let firmware = acc["firmware"] as! String
                           let serialNumber = acc["serial_number"] as! String
                           return "• \(name) (\(category)) - Room: \(room), UUID: \(uuid), FW: \(firmware), S/N: \(serialNumber)"
                       }.joined(separator: "\n")
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: [
                            "content": AnyEncodable(content),
                            "_meta": AnyEncodable(["accessories": accessories])
                          ], error: nil)
    }
    
    private func getCategoryName(for category: HMAccessoryCategory) -> String {
        // Use the localized description from HomeKit which gives us human-readable names
        return category.localizedDescription
    }
    
    private func getAccessoryFirmware(_ accessory: HMAccessory) -> String {
        // Look for firmware version in accessory information service
        for service in accessory.services {
            if service.serviceType == HMServiceTypeAccessoryInformation {
                for characteristic in service.characteristics {
                    if characteristic.characteristicType == HMCharacteristicTypeFirmwareVersion {
                        return characteristic.value as? String ?? "Unknown"
                    }
                }
            }
        }
        return "Unknown"
    }
    
    private func getAccessorySerialNumber(_ accessory: HMAccessory) -> String {
        // Look for serial number in accessory information service
        for service in accessory.services {
            if service.serviceType == HMServiceTypeAccessoryInformation {
                for characteristic in service.characteristics {
                    if characteristic.characteristicType == HMCharacteristicTypeSerialNumber {
                        return characteristic.value as? String ?? "Unknown"
                    }
                }
            }
        }
        return "Unknown"
    }
    
    private func handleGetAllRooms(_ request: MCPRequest) -> MCPResponse {
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
        
        let content = [
            [
                "type": "text",
                "text": "Found \(rooms.count) rooms:\n" + 
                       rooms.map { room in
                           "• \(room["name"] as! String) (UUID: \(room["uuid"] as! String))"
                       }.joined(separator: "\n")
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: [
                            "content": AnyEncodable(content),
                            "_meta": AnyEncodable(["rooms": rooms])
                          ], error: nil)
    }
    
    private func handleSetAccessoryRoom(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        print("🔧 [MCP] set_accessory_room called with arguments: \(arguments)")
        
        guard let accessoryUUIDString = arguments["accessory_uuid"] as? String,
              let roomUUIDString = arguments["room_uuid"] as? String,
              let accessoryUUID = UUID(uuidString: accessoryUUIDString),
              let roomUUID = UUID(uuidString: roomUUIDString) else {
            print("❌ [MCP] Invalid UUIDs provided")
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Invalid UUIDs"))
        }
        
        print("🔍 [MCP] Looking for accessory: \(accessoryUUIDString)")
        print("🔍 [MCP] Looking for room: \(roomUUIDString)")
        
        var foundAccessory: HMAccessory?
        var foundRoom: HMRoom?
        var foundHome: HMHome?
        
        for home in homeManager.homes {
            print("🏠 [MCP] Searching in home: \(home.name)")
            if foundAccessory == nil {
                foundAccessory = home.accessories.first { $0.uniqueIdentifier == accessoryUUID }
                if foundAccessory != nil {
                    foundHome = home
                    print("✅ [MCP] Found accessory: \(foundAccessory?.name ?? "unknown") in home: \(home.name)")
                }
            }
            if foundRoom == nil {
                foundRoom = home.rooms.first { $0.uniqueIdentifier == roomUUID }
                if foundRoom != nil {
                    print("✅ [MCP] Found room: \(foundRoom?.name ?? "unknown") in home: \(home.name)")
                }
            }
        }
        
        guard let accessory = foundAccessory,
              let room = foundRoom,
              let home = foundHome else {
            print("❌ [MCP] Could not find accessory or room")
            print("❌ [MCP] Accessory found: \(foundAccessory?.name ?? "nil")")
            print("❌ [MCP] Room found: \(foundRoom?.name ?? "nil")")
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Accessory or room not found"))
        }
        
        print("🔄 [MCP] Moving \(accessory.name) from \(accessory.room?.name ?? "unknown") to \(room.name)")
        
        // Check if accessory is already in target room
        if accessory.room?.uniqueIdentifier == room.uniqueIdentifier {
            let moveResult = "ℹ️ \(accessory.name) is already in \(room.name)"
            print("ℹ️ [MCP] Accessory already in target room")
            
            let content = [["type": "text", "text": moveResult]]
            return MCPResponse(jsonrpc: "2.0", id: request.id, 
                              result: ["content": AnyEncodable(content)], error: nil)
        }
        
        // Use async approach with shorter timeout
        let moveResult: String
        let group = DispatchGroup()
        var asyncResult: String = ""
        var operationCompleted = false
        
        print("🔄 [MCP] Starting HomeKit operation...")
        group.enter()
        
        home.assignAccessory(accessory, to: room) { error in
            defer { 
                if !operationCompleted {
                    operationCompleted = true
                    group.leave() 
                }
            }
            
            if let error = error {
                asyncResult = "❌ Failed to move \(accessory.name) to \(room.name): \(error.localizedDescription)"
                print("❌ [MCP] HomeKit error: \(error.localizedDescription)")
            } else {
                asyncResult = "✅ Successfully moved \(accessory.name) to \(room.name)"
                print("✅ [MCP] Move successful")
            }
        }
        
        // Wait with shorter timeout to prevent hanging Claude Code
        let result = group.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            moveResult = "⏰ Operation timed out after 5 seconds - HomeKit may be busy. Try again later."
            print("⏰ [MCP] Operation timed out after 5 seconds")
            if !operationCompleted {
                operationCompleted = true
                // Don't call group.leave() here as we already timed out
            }
        } else {
            moveResult = asyncResult
        }
        
        let content = [
            [
                "type": "text",
                "text": moveResult
            ]
        ]
        
        print("📤 [MCP] Returning result: \(moveResult)")
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: ["content": AnyEncodable(content)], error: nil)
    }
    
    private func handleGetAccessoryByName(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let name = arguments["name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'name' parameter"))
        }
        
        var foundAccessories: [[String: Any]] = []
        
        for home in homeManager.homes {
            for accessory in home.accessories where accessory.name.lowercased().contains(name.lowercased()) {
                let categoryName = getCategoryName(for: accessory.category)
                foundAccessories.append([
                    "name": accessory.name,
                    "room": accessory.room?.name ?? "No Room",
                    "uuid": accessory.uniqueIdentifier.uuidString,
                    "home": home.name,
                    "category": categoryName,
                    "reachable": accessory.isReachable
                ])
            }
        }
        
        let content = [
            [
                "type": "text",
                "text": foundAccessories.isEmpty 
                    ? "No accessories found matching '\(name)'"
                    : "Found \(foundAccessories.count) accessories matching '\(name)':\n" + 
                      foundAccessories.map { acc in
                          let name = acc["name"] as! String
                          let category = acc["category"] as! String
                          let room = acc["room"] as! String
                          let uuid = acc["uuid"] as! String
                          return "• \(name) (\(category)) - Room: \(room), UUID: \(uuid)"
                      }.joined(separator: "\n")
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: [
                            "content": AnyEncodable(content),
                            "_meta": AnyEncodable(["accessories": foundAccessories])
                          ], error: nil)
    }
    
    private func handleGetRoomByName(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let name = arguments["name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'name' parameter"))
        }
        
        var foundRooms: [[String: Any]] = []
        
        for home in homeManager.homes {
            for room in home.rooms where room.name.lowercased().contains(name.lowercased()) {
                foundRooms.append([
                    "name": room.name,
                    "uuid": room.uniqueIdentifier.uuidString,
                    "home": home.name
                ])
            }
        }
        
        let content = [
            [
                "type": "text",
                "text": foundRooms.isEmpty 
                    ? "No rooms found matching '\(name)'"
                    : "Found \(foundRooms.count) rooms matching '\(name)':\n" + 
                      foundRooms.map { room in
                          "• \(room["name"] as! String) (UUID: \(room["uuid"] as! String))"
                      }.joined(separator: "\n")
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: [
                            "content": AnyEncodable(content),
                            "_meta": AnyEncodable(["rooms": foundRooms])
                          ], error: nil)
    }
    
    private func handleSetAccessoryRoomByName(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryName = arguments["accessory_name"] as? String,
              let roomName = arguments["room_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'accessory_name' or 'room_name' parameter"))
        }
        
        // Find accessory by name
        var foundAccessory: HMAccessory?
        var foundHome: HMHome?
        
        for home in homeManager.homes {
            if let accessory = home.accessories.first(where: { $0.name.lowercased().contains(accessoryName.lowercased()) }) {
                foundAccessory = accessory
                foundHome = home
                break
            }
        }
        
        guard let accessory = foundAccessory, let home = foundHome else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Accessory '\(accessoryName)' not found"))
        }
        
        // Find room by name
        var foundRoom: HMRoom?
        
        for homeItem in homeManager.homes {
            if let room = homeItem.rooms.first(where: { $0.name.lowercased().contains(roomName.lowercased()) }) {
                foundRoom = room
                break
            }
        }
        
        guard let room = foundRoom else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Room '\(roomName)' not found"))
        }
        
        // Check if accessory is already in target room
        if accessory.room?.uniqueIdentifier == room.uniqueIdentifier {
            let result = "ℹ️ \(accessory.name) is already in \(room.name)"
            let content = [["type": "text", "text": result]]
            return MCPResponse(jsonrpc: "2.0", id: request.id, 
                              result: ["content": AnyEncodable(content)], error: nil)
        }
        
        // Move the accessory
        let moveResult: String
        let group = DispatchGroup()
        var asyncResult: String = ""
        var operationCompleted = false
        
        group.enter()
        
        home.assignAccessory(accessory, to: room) { error in
            defer { 
                if !operationCompleted {
                    operationCompleted = true
                    group.leave() 
                }
            }
            
            if let error = error {
                asyncResult = "❌ Failed to move \(accessory.name) to \(room.name): \(error.localizedDescription)"
            } else {
                asyncResult = "✅ Successfully moved \(accessory.name) to \(room.name)"
            }
        }
        
        let result = group.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            moveResult = "⏰ Operation timed out after 5 seconds - HomeKit may be busy. Try again later."
            if !operationCompleted {
                operationCompleted = true
            }
        } else {
            moveResult = asyncResult
        }
        
        let content = [["type": "text", "text": moveResult]]
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: ["content": AnyEncodable(content)], error: nil)
    }
    
    private func handleRenameAccessory(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryName = arguments["accessory_name"] as? String,
              let newName = arguments["new_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'accessory_name' or 'new_name' parameter"))
        }
        
        // Find accessory by name
        var foundAccessory: HMAccessory?
        
        for home in homeManager.homes {
            if let accessory = home.accessories.first(where: { $0.name.lowercased().contains(accessoryName.lowercased()) }) {
                foundAccessory = accessory
                break
            }
        }
        
        guard let accessory = foundAccessory else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Accessory '\(accessoryName)' not found"))
        }
        
        // Rename the accessory
        let renameResult: String
        let group = DispatchGroup()
        var asyncResult: String = ""
        var operationCompleted = false
        
        group.enter()
        
        accessory.updateName(newName) { error in
            defer { 
                if !operationCompleted {
                    operationCompleted = true
                    group.leave() 
                }
            }
            
            if let error = error {
                asyncResult = "❌ Failed to rename '\(accessory.name)' to '\(newName)': \(error.localizedDescription)"
            } else {
                asyncResult = "✅ Successfully renamed '\(accessoryName)' to '\(newName)'"
            }
        }
        
        let result = group.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            renameResult = "⏰ Operation timed out after 5 seconds - HomeKit may be busy. Try again later."
            if !operationCompleted {
                operationCompleted = true
            }
        } else {
            renameResult = asyncResult
        }
        
        let content = [["type": "text", "text": renameResult]]
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: ["content": AnyEncodable(content)], error: nil)
    }
    
    private func handleRenameRoom(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let roomName = arguments["room_name"] as? String,
              let newName = arguments["new_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'room_name' or 'new_name' parameter"))
        }
        
        // Find room by name
        var foundRoom: HMRoom?
        
        for home in homeManager.homes {
            if let room = home.rooms.first(where: { $0.name.lowercased().contains(roomName.lowercased()) }) {
                foundRoom = room
                break
            }
        }
        
        guard let room = foundRoom else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Room '\(roomName)' not found"))
        }
        
        // Rename the room
        let renameResult: String
        let group = DispatchGroup()
        var asyncResult: String = ""
        var operationCompleted = false
        
        group.enter()
        
        room.updateName(newName) { error in
            defer { 
                if !operationCompleted {
                    operationCompleted = true
                    group.leave() 
                }
            }
            
            if let error = error {
                asyncResult = "❌ Failed to rename '\(room.name)' to '\(newName)': \(error.localizedDescription)"
            } else {
                asyncResult = "✅ Successfully renamed '\(roomName)' to '\(newName)'"
            }
        }
        
        let result = group.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            renameResult = "⏰ Operation timed out after 5 seconds - HomeKit may be busy. Try again later."
            if !operationCompleted {
                operationCompleted = true
            }
        } else {
            renameResult = asyncResult
        }
        
        let content = [["type": "text", "text": renameResult]]
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: ["content": AnyEncodable(content)], error: nil)
    }
    
    private func handleGetRoomAccessories(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let roomName = arguments["room_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'room_name' parameter"))
        }
        
        // Find room by name
        var foundRoom: HMRoom?
        var foundHome: HMHome?
        
        for home in homeManager.homes {
            if let room = home.rooms.first(where: { $0.name.lowercased().contains(roomName.lowercased()) }) {
                foundRoom = room
                foundHome = home
                break
            }
        }
        
        guard let room = foundRoom, let home = foundHome else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Room '\(roomName)' not found"))
        }
        
        // Get accessories in this room
        var roomAccessories: [[String: Any]] = []
        
        for accessory in home.accessories where accessory.room?.uniqueIdentifier == room.uniqueIdentifier {
            let categoryName = getCategoryName(for: accessory.category)
            roomAccessories.append([
                "name": accessory.name,
                "uuid": accessory.uniqueIdentifier.uuidString,
                "category": categoryName,
                "reachable": accessory.isReachable,
                "firmware": getAccessoryFirmware(accessory),
                "serial_number": getAccessorySerialNumber(accessory)
            ])
        }
        
        let content = [
            [
                "type": "text",
                "text": roomAccessories.isEmpty 
                    ? "No accessories found in room '\(room.name)'"
                    : "Found \(roomAccessories.count) accessories in '\(room.name)':\n" + 
                      roomAccessories.map { acc in
                          let name = acc["name"] as! String
                          let category = acc["category"] as! String
                          let uuid = acc["uuid"] as! String
                          let reachable = acc["reachable"] as! Bool
                          let firmware = acc["firmware"] as! String
                          let serialNumber = acc["serial_number"] as! String
                          let status = reachable ? "🟢" : "🔴"
                          return "• \(name) (\(category)) \(status) - UUID: \(uuid), FW: \(firmware), S/N: \(serialNumber)"
                      }.joined(separator: "\n")
            ]
        ]
        
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: [
                            "content": AnyEncodable(content),
                            "_meta": AnyEncodable([
                                "room": ["name": room.name, "uuid": room.uniqueIdentifier.uuidString],
                                "accessories": roomAccessories
                            ])
                          ], error: nil)
    }
    
    private func handleAccessoryOn(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryName = arguments["accessory_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'accessory_name' parameter"))
        }
        
        return controlAccessory(request: request, accessoryName: accessoryName, action: .turnOn)
    }
    
    private func handleAccessoryOff(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryName = arguments["accessory_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'accessory_name' parameter"))
        }
        
        return controlAccessory(request: request, accessoryName: accessoryName, action: .turnOff)
    }
    
    private func handleAccessoryToggle(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryName = arguments["accessory_name"] as? String else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32602, message: "Missing 'accessory_name' parameter"))
        }
        
        return controlAccessory(request: request, accessoryName: accessoryName, action: .toggle)
    }
    
    private enum AccessoryAction {
        case turnOn, turnOff, toggle
    }
    
    private func controlAccessory(request: MCPRequest, accessoryName: String, action: AccessoryAction) -> MCPResponse {
        // Find accessory by name
        var foundAccessory: HMAccessory?
        
        for home in homeManager.homes {
            if let accessory = home.accessories.first(where: { $0.name.lowercased().contains(accessoryName.lowercased()) }) {
                foundAccessory = accessory
                break
            }
        }
        
        guard let accessory = foundAccessory else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Accessory '\(accessoryName)' not found"))
        }
        
        // Find controllable characteristics
        var controllableCharacteristics: [HMCharacteristic] = []
        var characteristicType: String = ""
        
        for service in accessory.services {
            // Look for power state characteristic (lights, switches)
            if let powerChar = service.characteristics.first(where: { 
                $0.characteristicType == HMCharacteristicTypePowerState 
            }) {
                controllableCharacteristics.append(powerChar)
                characteristicType = "power"
                break
            }
            
            // Look for brightness characteristic (lights) - indicates dimmable light
            if let brightnessChar = service.characteristics.first(where: { 
                $0.characteristicType == HMCharacteristicTypeBrightness 
            }) {
                // For dimmable lights, use power state for on/off control
                if let powerChar = service.characteristics.first(where: { 
                    $0.characteristicType == HMCharacteristicTypePowerState 
                }) {
                    controllableCharacteristics.append(powerChar)
                    characteristicType = "power"
                    break
                }
            }
            
            // Look for target position characteristic (covers, blinds)
            if let positionChar = service.characteristics.first(where: { 
                $0.characteristicType == HMCharacteristicTypeTargetPosition 
            }) {
                controllableCharacteristics.append(positionChar)
                characteristicType = "position"
                break
            }
            
            // Look for target door state (garage doors)
            if let doorChar = service.characteristics.first(where: { 
                $0.characteristicType == HMCharacteristicTypeTargetDoorState 
            }) {
                controllableCharacteristics.append(doorChar)
                characteristicType = "door"
                break
            }
        }
        
        guard !controllableCharacteristics.isEmpty else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Accessory '\(accessory.name)' has no controllable characteristics"))
        }
        
        let characteristic = controllableCharacteristics[0]
        
        // Determine target value based on action and characteristic type
        var targetValue: Any
        var actionDescription: String
        
        switch (action, characteristicType) {
        case (.turnOn, "power"):
            targetValue = true
            actionDescription = "turn on"
        case (.turnOff, "power"):
            targetValue = false
            actionDescription = "turn off"
        case (.turnOn, "position"):
            targetValue = 100 // Fully open
            actionDescription = "open"
        case (.turnOff, "position"):
            targetValue = 0 // Fully closed
            actionDescription = "close"
        case (.turnOn, "door"):
            targetValue = HMCharacteristicValueDoorState.open.rawValue
            actionDescription = "open"
        case (.turnOff, "door"):
            targetValue = HMCharacteristicValueDoorState.closed.rawValue
            actionDescription = "close"
        case (.toggle, _):
            // For toggle, we need to read current state first
            guard let currentValue = characteristic.value else {
                return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                                  error: MCPError(code: -32603, message: "Cannot read current state of '\(accessory.name)'"))
            }
            
            switch characteristicType {
            case "power":
                let currentBool = currentValue as? Bool ?? false
                targetValue = !currentBool
                actionDescription = currentBool ? "turn off" : "turn on"
            case "position":
                let currentPosition = currentValue as? Int ?? 0
                targetValue = currentPosition > 50 ? 0 : 100
                actionDescription = currentPosition > 50 ? "close" : "open"
            case "door":
                let currentDoor = currentValue as? Int ?? HMCharacteristicValueDoorState.closed.rawValue
                targetValue = currentDoor == HMCharacteristicValueDoorState.closed.rawValue ? 
                    HMCharacteristicValueDoorState.open.rawValue : HMCharacteristicValueDoorState.closed.rawValue
                actionDescription = currentDoor == HMCharacteristicValueDoorState.closed.rawValue ? "open" : "close"
            default:
                return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                                  error: MCPError(code: -32603, message: "Cannot toggle '\(accessory.name)' - unknown characteristic type"))
            }
        default:
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                              error: MCPError(code: -32603, message: "Invalid action for '\(accessory.name)' - unsupported characteristic type"))
        }
        
        // Execute the control action
        let controlResult: String
        let group = DispatchGroup()
        var asyncResult: String = ""
        var operationCompleted = false
        
        group.enter()
        
        characteristic.writeValue(targetValue) { error in
            defer { 
                if !operationCompleted {
                    operationCompleted = true
                    group.leave() 
                }
            }
            
            if let error = error {
                asyncResult = "❌ Failed to \(actionDescription) '\(accessory.name)': \(error.localizedDescription)"
            } else {
                asyncResult = "✅ Successfully \(actionDescription) '\(accessory.name)'"
            }
        }
        
        let result = group.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            controlResult = "⏰ Operation timed out after 5 seconds - HomeKit may be busy. Try again later."
            if !operationCompleted {
                operationCompleted = true
            }
        } else {
            controlResult = asyncResult
        }
        
        let content = [["type": "text", "text": controlResult]]
        return MCPResponse(jsonrpc: "2.0", id: request.id, 
                          result: ["content": AnyEncodable(content)], error: nil)
    }
    
    private func sendSSEEvent(connection: NWConnection, event: String, data: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            let sseMessage = "event: \(event)\ndata: \(jsonString)\n\n"
            
            connection.send(content: sseMessage.data(using: .utf8), completion: .contentProcessed { error in
                if let error = error {
                    print("Failed to send SSE event: \(error)")
                }
            })
        } catch {
            print("Failed to serialize SSE data: \(error)")
        }
    }
    
    private func sendHTTPResponse(connection: NWConnection, body: Data) {
        let headers = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Access-Control-Allow-Origin: *\r
            \r
            
            """
        
        var responseData = Data()
        guard let headerData = headers.data(using: .utf8) else {
            print("Failed to encode HTTP headers")
            connection.cancel()
            return
        }
        responseData.append(headerData)
        responseData.append(body)
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendHTTPResponse(connection: NWConnection, body: String) {
        sendHTTPResponse(connection: connection, body: body.data(using: .utf8) ?? Data())
    }
    
    private func sendHTTPError(connection: NWConnection, status: Int, message: String) {
        let response = """
            HTTP/1.1 \(status) \(message)\r
            Content-Type: text/plain\r
            Content-Length: \(message.count)\r
            Access-Control-Allow-Origin: *\r
            \r
            \(message)
            """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func getWelcomeHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>HomeKit MCP Server</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                .endpoint { background: #f5f5f5; padding: 10px; margin: 10px 0; border-radius: 5px; }
                code { background: #e8e8e8; padding: 2px 4px; border-radius: 3px; }
            </style>
        </head>
        <body>
            <h1>HomeKit MCP Server</h1>
            <p>HTTP-based MCP server for HomeKit integration with Claude Code support</p>
            
            <h2>MCP Transport Endpoints (Claude Code):</h2>
            <div class="endpoint">
                <strong>GET /mcp</strong> - MCP server discovery
            </div>
            <div class="endpoint">
                <strong>POST /mcp/initialize</strong> - Initialize MCP session
            </div>
            <div class="endpoint">
                <strong>POST /mcp/tools/list</strong> - List available tools
            </div>
            <div class="endpoint">
                <strong>POST /mcp/tools/call</strong> - Execute tool
            </div>
            
            <h2>Direct Endpoints:</h2>
            <div class="endpoint">
                <strong>GET /events</strong> - Server-Sent Events stream
            </div>
            <div class="endpoint">
                <strong>POST /mcp</strong> - Direct MCP JSON-RPC requests
            </div>
            
            <h2>Available Tools:</h2>
            <ul>
                <li><code>get_all_accessories</code> - List all HomeKit accessories</li>
                <li><code>get_all_rooms</code> - List all HomeKit rooms</li>
                <li><code>set_accessory_room</code> - Move accessory to different room</li>
            </ul>
            
            <h2>Claude Code Configuration:</h2>
            <pre><code>{
              "mcpServers": {
                "homekit": {
                  "type": "http",
                  "url": "http://localhost:8080/mcp"
                }
              }
            }</code></pre>
        </body>
        </html>
        """
    }
}
