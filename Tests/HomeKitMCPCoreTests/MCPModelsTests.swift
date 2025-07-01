import XCTest
@testable import HomeKitMCPCore

final class MCPModelsTests: XCTestCase {
    
    func testMCPRequestDecoding() throws {
        let jsonString = """
        {
            "jsonrpc": "2.0",
            "id": 123,
            "method": "tools/call",
            "params": {
                "name": "get_all_rooms",
                "arguments": {}
            }
        }
        """
        
        let data = jsonString.data(using: .utf8)!
        let request = try JSONDecoder().decode(MCPRequest.self, from: data)
        
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.id, 123)
        XCTAssertEqual(request.method, "tools/call")
        XCTAssertNotNil(request.params)
        
        let params = request.params!
        XCTAssertEqual(params["name"]?.value as? String, "get_all_rooms")
    }
    
    func testMCPResponseEncoding() throws {
        let response = MCPResponse(
            jsonrpc: "2.0",
            id: 456,
            result: ["status": AnyEncodable("ok")],
            error: nil
        )
        
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? Int, 456)
        XCTAssertNotNil(json["result"])
        XCTAssertNil(json["error"])
    }
    
    func testMCPErrorHandling() throws {
        let error = MCPError(code: -32601, message: "Method not found")
        let response = MCPResponse(jsonrpc: "2.0", id: 1, result: nil, error: error)
        
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let errorDict = json["error"] as! [String: Any]
        
        XCTAssertEqual(errorDict["code"] as? Int, -32601)
        XCTAssertEqual(errorDict["message"] as? String, "Method not found")
    }
    
    func testJSONRPCToolsListFormat() throws {
        let tools = [
            [
                "name": "get_all_accessories",
                "description": "Get all HomeKit accessories",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
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
        
        XCTAssertEqual(toolsArray.count, 1)
        XCTAssertEqual(toolsArray[0]["name"] as? String, "get_all_accessories")
    }
}