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
                    
                    Text("Local socket; MCP 2026-07-28; read-only")
                        .font(.body)
                    
                    Text("Available Endpoints:")
                        .font(.subheadline)
                        .bold()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local socket; SSH client available")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    Text("Available MCP Tools:")
                        .font(.subheadline)
                        .bold()
                        .padding(.top)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Group {
                                Text("• get_all_accessories - List all HomeKit accessories")
                                Text("• get_all_rooms - List all HomeKit rooms")
                                Text("• Writes disabled in this security preview")
                            }

                        }
                    }
                    .frame(maxHeight: 120)
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
                .disabled(server.isStopping)
                
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
    @Published var isStopping = false
    private var httpServer: HTTPMCPServer?
    
    init() {} // Explicit owner action starts HomeKit access and the IPC listener.
    
    func startServer() {
        guard !isRunning, !isStopping else { return }
        
        httpServer = HTTPMCPServer()
        isRunning = httpServer?.isRunning ?? false
        
    }
    
    func stopServer() {
        guard isRunning else { return }
        
        isStopping = true
        isRunning = false
        httpServer?.stop { [weak self] in
            self?.httpServer = nil
            self?.isStopping = false
        }
    }
    
    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }
}
