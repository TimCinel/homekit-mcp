import XCTest
@testable import HomeKitMCPCore

final class AnyEncodableTests: XCTestCase {
    
    func testStringEncoding() throws {
        let value = AnyEncodable("test string")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as! String
        
        XCTAssertEqual(decoded, "test string")
    }
    
    func testIntEncoding() throws {
        let value = AnyEncodable(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as! Int
        
        XCTAssertEqual(decoded, 42)
    }
    
    func testBoolEncoding() throws {
        let value = AnyEncodable(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as! Bool
        
        XCTAssertEqual(decoded, true)
    }
    
    func testArrayEncoding() throws {
        let value = AnyEncodable(["item1", "item2", "item3"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String]
        
        XCTAssertEqual(decoded, ["item1", "item2", "item3"])
    }
    
    func testDictionaryEncoding() throws {
        let value = AnyEncodable(["key1": "value1", "key2": 42, "key3": true])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(decoded["key1"] as? String, "value1")
        XCTAssertEqual(decoded["key2"] as? Int, 42)
        XCTAssertEqual(decoded["key3"] as? Bool, true)
    }
    
    func testNilEncoding() throws {
        let value = AnyEncodable(NSNull())
        let data = try JSONEncoder().encode(value)
        
        // Should encode as JSON null
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertEqual(jsonString, "null")
    }
}