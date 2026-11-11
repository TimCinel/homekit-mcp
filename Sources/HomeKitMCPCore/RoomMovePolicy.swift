import Foundation

/// Imported Home Assistant data only. HomeKit snapshots and rollback receipts stay on the Mac.
public struct HARoomAssignments: Codable {
    public let schemaVersion: Int
    public let items: [HARoomAssignment]
    public init(items: [HARoomAssignment]) { schemaVersion = 2; self.items = items }
}
public struct HARoomAssignment: Codable {
    public let sourceID: String
    public let names: [String]
    public let targetRoom: String
    public init(names: [String], targetRoom: String, sourceID: String? = nil) { self.names = names; self.targetRoom = targetRoom; self.sourceID = sourceID ?? names.sorted().joined(separator: "|") }
}
public struct RoomMoveScope: Codable, Equatable {
    public let home: UUID
    public let accessory: UUID
    public let originalRoom: UUID
    public let destinationName: String
    public let destinationRoom: UUID?
    public let expires: Date
    public init(home: UUID, accessory: UUID, originalRoom: UUID, destinationName: String, expires: Date, destinationRoom: UUID? = nil) {
        self.home = home; self.accessory = accessory; self.originalRoom = originalRoom
        self.destinationName = destinationName; self.expires = expires; self.destinationRoom = destinationRoom
    }
    public func permits(home: UUID, accessory: UUID, currentRoom: UUID, destinationName: String, now: Date, observedDestination: UUID? = nil) -> Bool {
        destinationRoom == observedDestination && now < expires && self.home == home && self.accessory == accessory && originalRoom == currentRoom && self.destinationName == destinationName
    }
}
public enum RoomMovePolicy {
    private static let generic: Set<String> = ["power", "on", "off", "name", "switch", "light", "lightbulb", "fan", "tv", "television", "speaker", "input", "inputsource", "information", "accessoryinformation", "smartrgbtwbulb", "smartbulb", "outlet"]
    public static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
    public static func usable(_ value: String) -> Bool {
        let key = normalize(value)
        return !key.isEmpty && !generic.contains(key)
    }
    public static func validate(_ input: HARoomAssignments) -> Bool {
        input.schemaVersion == 2 && input.items.count <= 10000 && input.items.allSatisfy {
            !$0.sourceID.isEmpty && $0.sourceID.utf8.count <= 256 && !$0.targetRoom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.targetRoom.utf8.count <= 128 && !$0.names.isEmpty && $0.names.count <= 32 && $0.names.allSatisfy { $0.utf8.count <= 256 }
        }
    }
    /// Unique meaningful names only. Conflicting HA areas and generic model labels never authorize a move.
    public static func destination(names: [String], assignments: HARoomAssignments) -> String? {
        RoomAssignmentIndex(assignments).destination(names: names)
    }
}

/// Build once per imported HA plan. A shared alias cannot identify multiple HA sources.
public struct RoomAssignmentIndex {
    private var aliases: [String: Set<String>] = [:]
    private var targets: [String: Set<String>] = [:]
    public init(_ input: HARoomAssignments) {
        guard RoomMovePolicy.validate(input) else { return }
        for item in input.items {
            targets[item.sourceID, default: []].insert(item.targetRoom)
            for name in item.names where RoomMovePolicy.usable(name) {
                aliases[RoomMovePolicy.normalize(name), default: []].insert(item.sourceID)
            }
        }
    }
    public func destination(names: [String]) -> String? {
        var sources = Set<String>()
        for name in names where RoomMovePolicy.usable(name) {
            if let ids = aliases[RoomMovePolicy.normalize(name)], ids.count == 1 { sources.formUnion(ids) }
        }
        guard sources.count == 1, let id = sources.first, let rooms = targets[id], rooms.count == 1 else { return nil }
        return rooms.first
    }
}

/// A timeout never cancels HomeKit. Quarantine persists until explicit fresh reconciliation.
public struct RoomWriteGate {
    public private(set) var outstanding = false
    public private(set) var quarantined = false
    public init() {}
    public mutating func begin() -> Bool {
        guard !outstanding, !quarantined else { return false }
        outstanding = true; return true
    }
    public mutating func finished() { outstanding = false }
    public mutating func uncertain() { quarantined = true }
    public mutating func reconcile() -> Bool {
        guard !outstanding else { return false }
        quarantined = false; return true
    }
}

public struct PendingRoomOperation: Codable, Equatable {
    public let id: UUID
    public let home: UUID
    public let accessory: UUID?
    public let original: UUID?
    public let destination: UUID?
    public let destinationName: String
    public init(id: UUID = UUID(), home: UUID, accessory: UUID?, original: UUID?, destination: UUID?, destinationName: String) {
        self.id = id; self.home = home; self.accessory = accessory; self.original = original
        self.destination = destination; self.destinationName = destinationName
    }
    public func resolved(observedHome: UUID, observedAccessory: UUID?, observedRoom: UUID?, destinationRoomCount: Int, callbackReceived: Bool) -> Bool {
        guard home == observedHome else { return false }
        if let accessory = accessory {
            guard accessory == observedAccessory else { return false }
            if let destination = destination, observedRoom == destination { return true }
            return callbackReceived && original != nil && observedRoom == original
        }
        return destinationRoomCount == 1 || (callbackReceived && destinationRoomCount == 0) // Known completion or satisfied creation intent; unknown post-restart absence stays blocked.
    }
}
