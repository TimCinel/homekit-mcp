import Foundation
import HomeKit

class HomeKitManager: NSObject, ObservableObject, HMHomeManagerDelegate {
    private let homeManager = HMHomeManager()
    var outputHandler: ((String) -> Void)?
    
    override init() {
        super.init()
        homeManager.delegate = self
    }
    
    func start() {
        print("Starting HomeKit manager...")
        outputHandler?("Starting HomeKit manager...")
    }
    
    func refresh() {
        homeManagerDidUpdateHomes(homeManager)
    }
    
    // MARK: - HMHomeManagerDelegate
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        print("HomeKit homes updated")
        let message = getHomesAndContent()
        outputHandler?(message)
    }
    
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        print("Home added: \(home.name)")
        outputHandler?("Home added: \(home.name)")
    }
    
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        print("Home removed: \(home.name)")
        outputHandler?("Home removed: \(home.name)")
    }
    
    // MARK: - Listing Functions
    
    func getHomesAndContent() -> String {
        var output = ""
        
        guard !homeManager.homes.isEmpty else {
            return "No homes found"
        }
        
        for home in homeManager.homes {
            output += "\n🏠 Home: \(home.name)\n"
            output += "   UUID: \(home.uniqueIdentifier)\n"
            
            output += getRooms(for: home)
            output += getAccessories(for: home)
        }
        
        return output
    }
    
    func getRooms(for home: HMHome) -> String {
        var output = "\n  📍 Rooms (\(home.rooms.count)):\n"
        for room in home.rooms {
            output += "    • \(room.name) (UUID: \(room.uniqueIdentifier))\n"
        }
        return output
    }
    
    func getAccessories(for home: HMHome) -> String {
        var output = "\n  🔌 Accessories (\(home.accessories.count)):\n"
        for accessory in home.accessories {
            let roomName = accessory.room?.name ?? "No Room"
            output += "    • \(accessory.name)\n"
            output += "      Room: \(roomName)\n"
            output += "      UUID: \(accessory.uniqueIdentifier)\n"
            output += "      Reachable: \(accessory.isReachable)\n"
            
            // List services
            for service in accessory.services {
                output += "      Service: \(service.serviceType) - \(service.name ?? "Unnamed")\n"
            }
            output += "\n"
        }
        return output
    }
    
    // MARK: - Room Management Functions
    
    func moveAccessory(_ accessory: HMAccessory, to room: HMRoom, completion: @escaping (String) -> Void) {
        guard let home = homeManager.homes.first(where: { $0.accessories.contains(accessory) }) else {
            completion("❌ Could not find home for accessory \(accessory.name)")
            return
        }
        
        home.assignAccessory(accessory, to: room) { error in
            if let error = error {
                completion("❌ Failed to move \(accessory.name) to \(room.name): \(error.localizedDescription)")
            } else {
                completion("✅ Successfully moved \(accessory.name) to \(room.name)")
            }
        }
    }
    
    func findAccessory(named name: String) -> HMAccessory? {
        for home in homeManager.homes {
            for accessory in home.accessories where accessory.name.lowercased().contains(name.lowercased()) {
                return accessory
            }
        }
        return nil
    }
    
    func findRoom(named name: String) -> HMRoom? {
        for home in homeManager.homes {
            for room in home.rooms where room.name.lowercased().contains(name.lowercased()) {
                return room
            }
        }
        return nil
    }
    
    // MARK: - Bulk Operations
    
    func moveAccessoriesMatching(pattern: String, to roomName: String) -> String {
        guard let targetRoom = findRoom(named: roomName) else {
            return "❌ Room '\(roomName)' not found"
        }
        
        let matchingAccessories = homeManager.homes.flatMap { $0.accessories }
            .filter { $0.name.lowercased().contains(pattern.lowercased()) }
        
        var output = "Moving \(matchingAccessories.count) accessories matching '\(pattern)' to '\(roomName)'\n\n"
        
        for accessory in matchingAccessories {
            moveAccessory(accessory, to: targetRoom) { result in
                DispatchQueue.main.async {
                    self.outputHandler?(self.outputHandler == nil ? result : self.getHomesAndContent())
                }
            }
        }
        
        return output
    }
}
