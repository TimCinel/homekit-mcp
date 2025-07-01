import HomeKit
@testable import HomeKitMCP
import XCTest

class HTTPMCPServerTests: XCTestCase {
    
    func testMCPRequestDecoding() throws {
        let jsonString = """
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {}
        }
        """
        let jsonData = Data(jsonString.utf8)
        
        let request = try JSONDecoder().decode(MCPRequest.self, from: jsonData)
        
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.id, 1)
        XCTAssertEqual(request.method, "tools/list")
        XCTAssertNotNil(request.params)
    }
    
    func testMCPResponseEncoding() throws {
        let response = MCPResponse(
            jsonrpc: "2.0",
            id: 1,
            result: ["test": AnyEncodable("value")],
            error: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        
        // Should be valid JSON
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? Int, 1)
        XCTAssertNotNil(json["result"])
        XCTAssertNil(json["error"])
    }
    
    func testMCPErrorResponse() throws {
        let response = MCPResponse(
            jsonrpc: "2.0",
            id: 1,
            result: nil,
            error: MCPError(code: -32601, message: "Method not found")
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let error = json["error"] as! [String: Any]
        
        XCTAssertEqual(error["code"] as? Int, -32601)
        XCTAssertEqual(error["message"] as? String, "Method not found")
        XCTAssertNil(json["result"])
    }
    
    func testAnyEncodableWithString() throws {
        let value = AnyEncodable("test string")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as! String
        
        XCTAssertEqual(decoded, "test string")
    }
    
    func testAnyEncodableWithArray() throws {
        let value = AnyEncodable(["item1", "item2"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String]
        
        XCTAssertEqual(decoded, ["item1", "item2"])
    }
    
    func testAnyEncodableWithDictionary() throws {
        let value = AnyEncodable(["key": "value", "number": 42])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(decoded["key"] as? String, "value")
        XCTAssertEqual(decoded["number"] as? Int, 42)
    }
    
    func testToolsListResponseFormat() throws {
        // Mock a tools list response
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
    
    func testInvalidJSONHandling() {
        let invalidJSONString = "{ invalid json }"
        let invalidJSON = Data(invalidJSONString.utf8)
        
        XCTAssertThrowsError(try JSONDecoder().decode(MCPRequest.self, from: invalidJSON)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
}
