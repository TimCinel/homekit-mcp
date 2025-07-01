import Foundation

// MARK: - HTTP Utilities

public struct HTTPRequestParser {
    public static func parseRequestLine(_ httpRequest: String) -> (method: String, path: String, version: String)? {
        let lines = httpRequest.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 3 else { return nil }
        
        return (method: components[0], path: components[1], version: components[2])
    }
    
    public static func extractJSONBody(_ httpRequest: String) -> String? {
        let lines = httpRequest.components(separatedBy: "\r\n")
        guard let bodyStartIndex = lines.firstIndex(of: ""),
              bodyStartIndex + 1 < lines.count else {
            return nil
        }
        
        let bodyLines = Array(lines[(bodyStartIndex + 1)...])
        return bodyLines.joined(separator: "\r\n")
    }
}