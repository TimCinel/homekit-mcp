import XCTest
@testable import HomeKitMCPCore

final class RoomMovePolicyTests: XCTestCase {
    func testUniqueMeaningfulNameMatchesHA() {
        let input = HARoomAssignments(items: [.init(names: ["Living Room Fan"], targetRoom: "Living Room")])
        XCTAssertEqual(RoomMovePolicy.destination(names: ["living_room_fan", "Power"], assignments: input), "Living Room")
    }
    func testGenericNamesNeverAuthorize() {
        let input = HARoomAssignments(items: [.init(names: ["Power", "Smart RGBTW Bulb"], targetRoom: "Bedroom")])
        XCTAssertNil(RoomMovePolicy.destination(names: ["Power", "Smart RGBTW Bulb"], assignments: input))
    }
    func testConflictingAreasAreRejected() {
        let input = HARoomAssignments(items: [.init(names: ["Lamp"], targetRoom: "Kitchen"), .init(names: ["Lamp"], targetRoom: "Nursery")])
        XCTAssertNil(RoomMovePolicy.destination(names: ["Lamp"], assignments: input))
    }
    func testScopeCannotMoveDifferentDeviceHomeOrStaleRoom() {
        let h = UUID(), a = UUID(), r = UUID(), now = Date()
        let scope = RoomMoveScope(home: h, accessory: a, originalRoom: r, destinationName: "Nursery", expires: now.addingTimeInterval(60))
        XCTAssertTrue(scope.permits(home: h, accessory: a, currentRoom: r, destinationName: "Nursery", now: now))
        XCTAssertFalse(scope.permits(home: UUID(), accessory: a, currentRoom: r, destinationName: "Nursery", now: now))
        XCTAssertFalse(scope.permits(home: h, accessory: UUID(), currentRoom: r, destinationName: "Nursery", now: now))
        XCTAssertFalse(scope.permits(home: h, accessory: a, currentRoom: UUID(), destinationName: "Nursery", now: now))
        XCTAssertFalse(scope.permits(home: h, accessory: a, currentRoom: r, destinationName: "Kitchen", now: now))
        XCTAssertFalse(scope.permits(home: h, accessory: a, currentRoom: r, destinationName: "Nursery", now: now.addingTimeInterval(61)))
    }
    func testInvalidInputsAndUnmatchedNamesAreRejected() {
        let input = HARoomAssignments(items: [.init(names: ["A"], targetRoom: "")])
        XCTAssertFalse(RoomMovePolicy.validate(input))
        XCTAssertNil(RoomMovePolicy.destination(names: ["B"], assignments: input))
    }
}

final class RoomWriteSafetyTests: XCTestCase {
    func testTimeoutCannotBeRetriedAndLateCompletionDoesNotUnlock() {
        var gate = RoomWriteGate()
        XCTAssertTrue(gate.begin())
        gate.uncertain()
        XCTAssertFalse(gate.begin())
        XCTAssertFalse(gate.reconcile())
        gate.finished()
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.reconcile())
        XCTAssertTrue(gate.begin())
    }
    func testExactDestinationIDCannotBeReplacedBySameName() {
        let home = UUID(), accessory = UUID(), original = UUID(), target = UUID()
        let scope = RoomMoveScope(home: home, accessory: accessory, originalRoom: original, destinationName: "Living Room", expires: Date().addingTimeInterval(60), destinationRoom: target)
        XCTAssertTrue(scope.permits(home: home, accessory: accessory, currentRoom: original, destinationName: "Living Room", now: Date(), observedDestination: target))
        XCTAssertFalse(scope.permits(home: home, accessory: accessory, currentRoom: original, destinationName: "Living Room", now: Date(), observedDestination: UUID()))
    }
    func testOneAliasSharedAcrossDifferentHASourcesIsAmbiguousEvenInSameRoom() {
        let input = HARoomAssignments(items: [.init(names: ["Ceiling Light"], targetRoom: "Kitchen", sourceID: "device1"), .init(names: ["Ceiling-Light"], targetRoom: "Kitchen", sourceID: "device2")])
        XCTAssertNil(RoomAssignmentIndex(input).destination(names: ["Ceiling Light"]))
    }
    func testRepeatedEntitiesOfSameHADeviceAreNotAmbiguous() {
        let input = HARoomAssignments(items: [.init(names: ["Desk Lamp"], targetRoom: "Office", sourceID: "device1"), .init(names: ["Desk Lamp", "Desk Brightness"], targetRoom: "Office", sourceID: "device1")])
        XCTAssertEqual(RoomAssignmentIndex(input).destination(names: ["Desk Lamp"]), "Office")
    }
    func testConflictingEntityAreasOfOneDeviceAreRejected() {
        let input = HARoomAssignments(items: [.init(names: ["Desk Lamp"], targetRoom: "Office", sourceID: "device1"), .init(names: ["Desk Lamp"], targetRoom: "Nursery", sourceID: "device1")])
        XCTAssertNil(RoomAssignmentIndex(input).destination(names: ["Desk Lamp"]))
    }
}

final class PendingRoomOperationTests: XCTestCase {
    func testRestartAbsenceDoesNotResolveUnknownAssignment() {
        let home = UUID(), accessory = UUID(), original = UUID(), destination = UUID()
        let operation = PendingRoomOperation(home: home, accessory: accessory, original: original, destination: destination, destinationName: "Office")
        XCTAssertFalse(operation.resolved(observedHome: home, observedAccessory: accessory, observedRoom: original, destinationRoomCount: 1, callbackReceived: false))
        XCTAssertTrue(operation.resolved(observedHome: home, observedAccessory: accessory, observedRoom: destination, destinationRoomCount: 1, callbackReceived: false))
        XCTAssertTrue(operation.resolved(observedHome: home, observedAccessory: accessory, observedRoom: original, destinationRoomCount: 1, callbackReceived: true))
        XCTAssertFalse(operation.resolved(observedHome: UUID(), observedAccessory: accessory, observedRoom: destination, destinationRoomCount: 1, callbackReceived: true))
        XCTAssertFalse(operation.resolved(observedHome: home, observedAccessory: UUID(), observedRoom: destination, destinationRoomCount: 1, callbackReceived: true))
    }
    func testCreationUnknownAndKnownFailureAreDistinct() {
        let home = UUID()
        let operation = PendingRoomOperation(home: home, accessory: nil, original: nil, destination: nil, destinationName: "Office")
        XCTAssertFalse(operation.resolved(observedHome: home, observedAccessory: nil, observedRoom: nil, destinationRoomCount: 0, callbackReceived: false))
        XCTAssertTrue(operation.resolved(observedHome: home, observedAccessory: nil, observedRoom: nil, destinationRoomCount: 0, callbackReceived: true))
        XCTAssertTrue(operation.resolved(observedHome: home, observedAccessory: nil, observedRoom: nil, destinationRoomCount: 1, callbackReceived: false))
        XCTAssertFalse(operation.resolved(observedHome: home, observedAccessory: nil, observedRoom: nil, destinationRoomCount: 2, callbackReceived: true))
    }
}
#if os(macOS)
final class RoomEditorInstanceTests: XCTestCase {
    func testOnlyOneEditorCanOwnTheRecoveryLedger() throws {
        let path = URL(fileURLWithPath: "/tmp/homekit-editor-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: path) }
        var first: RoomEditorInstanceLock? = try RoomEditorInstanceLock(directory: path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try RoomEditorInstanceLock(directory: path))
        first = nil
        XCTAssertNoThrow(try RoomEditorInstanceLock(directory: path))
    }
}
#endif
