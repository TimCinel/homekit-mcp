import HomeKit
import SwiftUI

@main
struct HomeKitMCPApp: App {
    @StateObject private var server = AppWrapper()
    
    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}

struct ContentView: View {
    @ObservedObject var server: AppWrapper
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HomeKit MCP Server")
                .font(.title)
                .bold()
            
            HStack {
                Text("Status:")
                Text(server.isRunning ? "Running" : "Stopped")
                    .foregroundColor(server.isRunning ? .green : .red)
                    .bold()
            }
            
            if server.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server Details:")
                        .font(.headline)
                    
                    Text("Port: 8080")
                        .font(.body)
                    
                    Text("Available Endpoints:")
                        .font(.subheadline)
                        .bold()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• GET http://localhost:8080/ (Welcome page)")
                        Text("• GET http://localhost:8080/events (SSE stream)")
                        Text("• POST http://localhost:8080/mcp (JSON-RPC)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    Text("Available MCP Tools:")
                        .font(.subheadline)
                        .bold()
                        .padding(.top)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• get_all_accessories - List all HomeKit accessories")
                        Text("• get_all_rooms - List all HomeKit rooms")
                        Text("• set_accessory_room - Move accessory to different room")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            HStack {
                Button(server.isRunning ? "Stop Server" : "Start Server") {
                    server.toggleServer()
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
                
                Button("Quit") {
                    exit(0)
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
        }
        .padding()
    }
}

class AppWrapper: ObservableObject {
    @Published var isRunning = false
    private var httpServer: HTTPMCPServer?
    
    init() {
        startServer()
    }
    
    func startServer() {
        guard !isRunning else { return }
        
        httpServer = HTTPMCPServer()
        isRunning = true
        
        print("HomeKit MCP HTTP Server started on port 8080")
        print("Available endpoints:")
        print("- GET http://localhost:8080/events (Server-Sent Events)")
        print("- POST http://localhost:8080/mcp (MCP JSON-RPC)")
    }
    
    func stopServer() {
        guard isRunning else { return }
        
        httpServer = nil
        isRunning = false
        
        print("HomeKit MCP HTTP Server stopped")
    }
    
    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }
}
