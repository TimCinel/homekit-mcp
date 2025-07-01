import XCTest
@testable import HomeKitMCPCore

final class ToolValidationTests: XCTestCase {
    
    func testToolsListResponseStructure() throws {
        // Mock a complete tools list response with all 12 tools
        let tools = [
            createToolDefinition(name: "get_all_accessories", description: "Get all HomeKit accessories", parameters: []),
            createToolDefinition(name: "get_all_rooms", description: "Get all HomeKit rooms", parameters: []),
            createToolDefinition(name: "set_accessory_room", description: "Move accessory by UUID", parameters: ["accessory_uuid", "room_uuid"]),
            createToolDefinition(name: "get_accessory_by_name", description: "Find accessory by name", parameters: ["name"]),
            createToolDefinition(name: "get_room_by_name", description: "Find room by name", parameters: ["name"]),
            createToolDefinition(name: "set_accessory_room_by_name", description: "Move accessory by name", parameters: ["accessory_name", "room_name"]),
            createToolDefinition(name: "rename_accessory", description: "Rename accessory", parameters: ["accessory_name", "new_name"]),
            createToolDefinition(name: "rename_room", description: "Rename room", parameters: ["room_name", "new_name"]),
            createToolDefinition(name: "get_room_accessories", description: "Get room accessories", parameters: ["room_name"]),
            createToolDefinition(name: "accessory_on", description: "Turn on accessory", parameters: ["accessory_name"]),
            createToolDefinition(name: "accessory_off", description: "Turn off accessory", parameters: ["accessory_name"]),
            createToolDefinition(name: "accessory_toggle", description: "Toggle accessory", parameters: ["accessory_name"])
        ]
        
        let response = MCPResponse(
            jsonrpc: "2.0",
            id: 1,
            result: ["tools": AnyEncodable(tools)],
            error: nil
        )
        
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let result = json["result"] as! [String: Any]
        let toolsArray = result["tools"] as! [[String: Any]]
        
        XCTAssertEqual(toolsArray.count, 12, "Should have exactly 12 tools")
        
        // Verify all expected tools are present
        let toolNames = toolsArray.compactMap { $0["name"] as? String }
        let expectedTools = ["get_all_accessories", "get_all_rooms", "set_accessory_room", 
                           "get_accessory_by_name", "get_room_by_name", "set_accessory_room_by_name",
                           "rename_accessory", "rename_room", "get_room_accessories",
                           "accessory_on", "accessory_off", "accessory_toggle"]
        
        for expectedTool in expectedTools {
            XCTAssertTrue(toolNames.contains(expectedTool), "Missing tool: \(expectedTool)")
        }
    }
    
    func testControlToolRequests() throws {
        // Test accessory_on request structure
        let onRequest = createToolCallRequest(toolName: "accessory_on", arguments: ["accessory_name": "Living Room Light"])
        let onData = try JSONEncoder().encode(onRequest)
        let decodedOnRequest = try JSONDecoder().decode(MCPRequest.self, from: onData)
        
        XCTAssertEqual(decodedOnRequest.method, "tools/call")
        XCTAssertEqual(decodedOnRequest.params?["name"]?.value as? String, "accessory_on")
        
        let onArgs = decodedOnRequest.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(onArgs?["accessory_name"] as? String, "Living Room Light")
        
        // Test accessory_off request structure
        let offRequest = createToolCallRequest(toolName: "accessory_off", arguments: ["accessory_name": "Bedroom Fan"])
        let offData = try JSONEncoder().encode(offRequest)
        let decodedOffRequest = try JSONDecoder().decode(MCPRequest.self, from: offData)
        
        XCTAssertEqual(decodedOffRequest.params?["name"]?.value as? String, "accessory_off")
        
        // Test accessory_toggle request structure
        let toggleRequest = createToolCallRequest(toolName: "accessory_toggle", arguments: ["accessory_name": "Kitchen Light"])
        let toggleData = try JSONEncoder().encode(toggleRequest)
        let decodedToggleRequest = try JSONDecoder().decode(MCPRequest.self, from: toggleData)
        
        XCTAssertEqual(decodedToggleRequest.params?["name"]?.value as? String, "accessory_toggle")
    }
    
    func testRoomManagementRequests() throws {
        // Test rename_room request
        let renameRequest = createToolCallRequest(toolName: "rename_room", arguments: ["room_name": "Office", "new_name": "Work Room"])
        let renameData = try JSONEncoder().encode(renameRequest)
        let decodedRename = try JSONDecoder().decode(MCPRequest.self, from: renameData)
        
        let renameArgs = decodedRename.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(renameArgs?["room_name"] as? String, "Office")
        XCTAssertEqual(renameArgs?["new_name"] as? String, "Work Room")
        
        // Test get_room_accessories request
        let roomAccessoriesRequest = createToolCallRequest(toolName: "get_room_accessories", arguments: ["room_name": "Living Room"])
        let roomAccessoriesData = try JSONEncoder().encode(roomAccessoriesRequest)
        let decodedRoomAccessories = try JSONDecoder().decode(MCPRequest.self, from: roomAccessoriesData)
        
        let roomArgs = decodedRoomAccessories.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(roomArgs?["room_name"] as? String, "Living Room")
    }
    
    func testSearchToolRequests() throws {
        // Test get_accessory_by_name
        let accessorySearchRequest = createToolCallRequest(toolName: "get_accessory_by_name", arguments: ["name": "lamp"])
        let accessoryData = try JSONEncoder().encode(accessorySearchRequest)
        let decodedAccessory = try JSONDecoder().decode(MCPRequest.self, from: accessoryData)
        
        let accessoryArgs = decodedAccessory.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(accessoryArgs?["name"] as? String, "lamp")
        
        // Test get_room_by_name
        let roomSearchRequest = createToolCallRequest(toolName: "get_room_by_name", arguments: ["name": "bed"])
        let roomData = try JSONEncoder().encode(roomSearchRequest)
        let decodedRoom = try JSONDecoder().decode(MCPRequest.self, from: roomData)
        
        let roomArgs = decodedRoom.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(roomArgs?["name"] as? String, "bed")
    }
    
    func testMoveAccessoryRequests() throws {
        // Test UUID-based move
        let uuidMoveRequest = createToolCallRequest(
            toolName: "set_accessory_room", 
            arguments: ["accessory_uuid": "123e4567-e89b-12d3-a456-426614174000", "room_uuid": "987fcdeb-51a2-43d7-8f9e-123456789012"]
        )
        let uuidData = try JSONEncoder().encode(uuidMoveRequest)
        let decodedUuid = try JSONDecoder().decode(MCPRequest.self, from: uuidData)
        
        let uuidArgs = decodedUuid.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(uuidArgs?["accessory_uuid"] as? String, "123e4567-e89b-12d3-a456-426614174000")
        XCTAssertEqual(uuidArgs?["room_uuid"] as? String, "987fcdeb-51a2-43d7-8f9e-123456789012")
        
        // Test name-based move
        let nameMoveRequest = createToolCallRequest(
            toolName: "set_accessory_room_by_name", 
            arguments: ["accessory_name": "Desk Lamp", "room_name": "Office"]
        )
        let nameData = try JSONEncoder().encode(nameMoveRequest)
        let decodedName = try JSONDecoder().decode(MCPRequest.self, from: nameData)
        
        let nameArgs = decodedName.params?["arguments"]?.value as? [String: Any]
        XCTAssertEqual(nameArgs?["accessory_name"] as? String, "Desk Lamp")
        XCTAssertEqual(nameArgs?["room_name"] as? String, "Office")
    }
    
    func testErrorResponseStructure() throws {
        // Test error response for missing parameters
        let errorResponse = MCPResponse(
            jsonrpc: "2.0",
            id: 1,
            result: nil,
            error: MCPError(code: -32602, message: "Missing 'accessory_name' parameter")
        )
        
        let data = try JSONEncoder().encode(errorResponse)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let error = json["error"] as! [String: Any]
        
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "Missing 'accessory_name' parameter")
        XCTAssertNil(json["result"])
    }
    
    // Helper functions
    private func createToolDefinition(name: String, description: String, parameters: [String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        for param in parameters {
            properties[param] = [
                "type": "string",
                "description": "Parameter \(param)"
            ]
        }
        
        return [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": parameters
            ]
        ]
    }
    
    private func createToolCallRequest(toolName: String, arguments: [String: Any]) -> MCPRequest {
        return MCPRequest(
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: [
                "name": AnyEncodable(toolName),
                "arguments": AnyEncodable(arguments)
            ]
        )
    }
}