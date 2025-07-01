import XCTest
@testable import HomeKitMCPCore

final class HTTPHelpersTests: XCTestCase {
    
    func testHTTPRequestLineParsing() {
        let httpRequest = "POST /mcp/tools/call HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"test\":\"data\"}"
        let result = HTTPRequestParser.parseRequestLine(httpRequest)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.method, "POST")
        XCTAssertEqual(result?.path, "/mcp/tools/call")
        XCTAssertEqual(result?.version, "HTTP/1.1")
    }
    
    func testInvalidHTTPRequestLine() {
        let invalidRequest = "INVALID REQUEST"
        let result = HTTPRequestParser.parseRequestLine(invalidRequest)
        
        XCTAssertNil(result)
    }
    
    func testJSONBodyExtraction() {
        let httpRequest = """
        POST /mcp/tools/call HTTP/1.1\r
        Content-Type: application/json\r
        Content-Length: 25\r
        \r
        {"jsonrpc":"2.0","id":1}
        """
        
        let jsonBody = HTTPRequestParser.extractJSONBody(httpRequest)
        
        XCTAssertNotNil(jsonBody)
        XCTAssertEqual(jsonBody, "{\"jsonrpc\":\"2.0\",\"id\":1}")
    }
    
    func testJSONBodyExtractionWithoutBody() {
        let httpRequest = "GET /mcp HTTP/1.1\r\nContent-Type: application/json"
        let jsonBody = HTTPRequestParser.extractJSONBody(httpRequest)
        
        XCTAssertNil(jsonBody)
    }
    
    func testJSONBodyExtractionMultilineBody() {
        let httpRequest = """
        POST /mcp HTTP/1.1\r
        Content-Type: application/json\r
        \r
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "tools/list"
        }
        """
        
        let jsonBody = HTTPRequestParser.extractJSONBody(httpRequest)
        
        XCTAssertNotNil(jsonBody)
        XCTAssertTrue(jsonBody!.contains("\"jsonrpc\": \"2.0\""))
        XCTAssertTrue(jsonBody!.contains("\"method\": \"tools/list\""))
    }
}