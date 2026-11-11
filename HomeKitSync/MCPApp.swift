import SwiftUI

@main
struct HomeKitMCPApp: App {
    @StateObject private var model = LocalRoomEditor()
    var body: some Scene {
        WindowGroup { LocalRoomEditorView(model: model) }
    }
}

import HomeKit
import UniformTypeIdentifiers

private struct LocalMove: Identifiable {
    let id = UUID()
    let scope: RoomMoveScope
    let name: String
    let originalName: String
    let homeName: String
}
private struct LocalReceipt: Codable {
    let operationID: UUID
    let schemaVersion: Int
    let phase: String
    let home: UUID
    let accessory: UUID
    let original: UUID
    let destination: UUID
    let name: String
    let originalName: String
    let destinationName: String
    let timestamp: Date
}

/// All HomeKit-derived records, reconciliation and recovery files remain in this Mac's sandbox.
private final class LocalRoomEditor: NSObject, ObservableObject, HMHomeManagerDelegate {
    @Published var status = "Connect to HomeKit on this Mac to begin."
    @Published var moves: [LocalMove] = []
    @Published var busy = false
    @Published var connected = false
    @Published var completed = 0
    @Published var backupFolder = ""
    @Published var selectedHome: UUID?
    @Published var homes: [HomeChoice] = []
    @Published var quarantined = false
    struct HomeChoice: Identifiable { let id: UUID; let name: String }
    private var index: RoomAssignmentIndex?
    private var gate = RoomWriteGate()
    private var manager: HMHomeManager?
    private var verifier: HMHomeManager?
    private var verifyCompletion: ((HMHomeManager) -> Void)?
    private var assignments: HARoomAssignments?
    private var batchGeneration = UUID()
    private var active = false
    private var mutationPending = false
    private var pendingOperation: PendingRoomOperation?
    private var callbackOperations = Set<UUID>()
    private var instanceLock: RoomEditorInstanceLock?
    private var fatalJournalError = false
    private struct Journal: Codable { let phase: String; let operation: PendingRoomOperation? }

    override init() {
        super.init()
        do {
            let directory = try recoveryDirectory()
            instanceLock = try RoomEditorInstanceLock(directory: directory)
            let markerURL = directory.appendingPathComponent("active.json")
            if FileManager.default.fileExists(atPath: markerURL.path) {
                let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: markerURL))
                guard ["pending", "resolved"].contains(journal.phase) else { throw MCPWireError.invalidFrame }
                if journal.phase == "pending" {
                    guard let operation = journal.operation else { throw MCPWireError.invalidFrame }
                    pendingOperation = operation; gate.uncertain(); quarantined = true
                    status = "A prior operation needs exact-state reconciliation before further writes."
                }
            }
        } catch {
            fatalJournalError = true
            gate.uncertain(); quarantined = true
            status = "Recovery journal unavailable or another editor is active. Writes are disabled."
        }
    }
    func connect() {
        guard manager == nil, instanceLock != nil else { return }
        status = "Waiting for HomeKit authorization and home synchronization…"
        let manager = HMHomeManager()
        self.manager = manager
        manager.delegate = self
    }
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        DispatchQueue.main.async {
            if manager === self.verifier {
                let callback = self.verifyCompletion
                self.verifyCompletion = nil
                self.verifier = nil
                callback?(manager)
            } else if manager === self.manager {
                self.connected = !manager.homes.isEmpty
                self.homes = manager.homes.map { HomeChoice(id: $0.uniqueIdentifier, name: $0.name) }
                if self.selectedHome == nil, self.homes.count == 1 { self.selectedHome = self.homes.first?.id }
                if !self.busy { self.rebuild() }
            }
        }
    }
    func importFile(_ url: URL, rollback: Bool) {
        guard !busy, instanceLock != nil, !fatalJournalError else { return }
        moves = []; assignments = nil; index = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_097_152 else { throw NSError(domain: "RoomPlan", code: 1) }
            let data = try Data(contentsOf: url)
            guard data.count <= 2_097_152 else { throw NSError(domain: "RoomPlan", code: 1) }
            if rollback {
                let receipt = try JSONDecoder().decode(LocalReceipt.self, from: data)
                guard receipt.schemaVersion == 1, ["verified", "submitted"].contains(receipt.phase), !gate.outstanding,
                      pendingOperation == nil || (pendingOperation?.id == receipt.operationID && pendingOperation?.home == receipt.home && pendingOperation?.accessory == receipt.accessory && pendingOperation?.original == receipt.original && pendingOperation?.destination == receipt.destination) else {
                    status = "Recovery requires a submitted or verified receipt with no outstanding operation."; return
                }
                busy = true
                refresh { refreshed in
                    self.manager = refreshed
                    self.busy = false
                    guard let home = refreshed.homes.first(where: { $0.uniqueIdentifier == receipt.home && $0.uniqueIdentifier == self.selectedHome }),
                          let accessory = home.accessories.first(where: { $0.uniqueIdentifier == receipt.accessory }),
                          accessory.room?.uniqueIdentifier == receipt.destination,
                          let original = home.rooms.first(where: { $0.uniqueIdentifier == receipt.original }) else {
                        self.status = "Recovery rejected: refreshed home/device/room IDs do not match the receipt. No reverse move prepared."; return
                    }
                    do { try self.saveMarker(false) } catch { self.status = "Cannot save reconciliation state; recovery remains blocked."; return }
                    _ = self.gate.reconcile(); self.quarantined = false; self.mutationPending = false
                    self.moves = [LocalMove(scope: .init(home: receipt.home, accessory: receipt.accessory, originalRoom: receipt.destination, destinationName: original.name, expires: Date().addingTimeInterval(600), destinationRoom: original.uniqueIdentifier), name: accessory.name, originalName: accessory.room?.name ?? "", homeName: home.name)]
                    self.status = "Fresh inventory confirms the receipt's destination. Review this exact-UUID reverse move before applying."
                }
            } else {
                let input = try JSONDecoder().decode(HARoomAssignments.self, from: data)
                guard RoomMovePolicy.validate(input) else { throw NSError(domain: "RoomPlan", code: 2) }
                assignments = input
                index = RoomAssignmentIndex(input)
                rebuild()
            }
        } catch { status = "Could not import a valid plan. No changes made. Local recovery files require this app's verified receipt format." }
    }
    private func rebuild() {
        guard let manager = manager, !manager.homes.isEmpty else {
            status = "HomeKit has not provided an authorized home. Check account, permissions and home hubs."
            return
        }
        guard let assignments = assignments else {
            status = "HomeKit connected. Import Home Assistant names and target rooms to prepare a local plan."
            return
        }
        guard let home = manager.homes.first(where: { $0.uniqueIdentifier == selectedHome }), let index = index else {
            moves = []; status = "Select one home before preparing moves."; return
        }
        var owners: [String: Set<UUID>] = [:]
        for accessory in home.accessories {
            for name in [accessory.name] + accessory.services.map(\.name) where RoomMovePolicy.usable(name) {
                owners[RoomMovePolicy.normalize(name), default: []].insert(accessory.uniqueIdentifier)
            }
        }
        var plan: [LocalMove] = []
        for home in [home] {
            for accessory in home.accessories {
                guard let room = accessory.room,
                      let target = index.destination(names: ([accessory.name] + accessory.services.map(\.name)).filter { owners[RoomMovePolicy.normalize($0)]?.count == 1 }),
                      target != room.name,
                      home.rooms.filter({ $0.name == target }).count <= 1 else { continue }
                plan.append(LocalMove(scope: .init(home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, originalRoom: room.uniqueIdentifier, destinationName: target, expires: Date().addingTimeInterval(600), destinationRoom: home.rooms.first(where: { $0.name == target })?.uniqueIdentifier), name: accessory.name, originalName: room.name, homeName: home.name))
            }
        }
        moves = plan.sorted { left, right in
            if left.name == "Living Room Fan" { return right.name != "Living Room Fan" }
            if right.name == "Living Room Fan" { return false }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        status = "Prepared \(moves.count) unique room moves from Home Assistant. Unmatched or conflicting names are excluded. Missing destination rooms will be created; existing rooms will not be deleted."
    }
    func apply(pilot: Bool) {
        guard !busy, !fatalJournalError, !quarantined, connected, !moves.isEmpty else { return }
        guard moves.allSatisfy({ $0.scope.destinationRoom != nil }) else {
            status = "Create the missing destination rooms first, then review the refreshed UUID-bound plan."; return
        }
        let plan = pilot ? Array(moves.prefix(1)) : moves
        busy = true
        active = true
        batchGeneration = UUID()
        let generation = batchGeneration
        status = "Applying \(plan.count) reviewed room move(s)…"
        next(plan, index: 0, generation: generation)
    }
    private func fail(_ message: String) {
        if gate.outstanding || mutationPending { gate.uncertain(); quarantined = true }
        moves = []
        active = false; busy = false
        verifyCompletion = nil; verifier = nil
        status = message + " Batch stopped; no automatic retry. Review local recovery files before continuing."
    }
    private func next(_ plan: [LocalMove], index: Int, generation: UUID) {
        guard active, generation == batchGeneration else { return }
        guard index < plan.count else {
            active = false; busy = false
            status = "Verified \(plan.count) room move(s) using a refreshed HomeKit inventory. Recovery receipts stay on this Mac."
            return
        }
        let move = plan[index]
        let operationID = UUID()
        guard let home = manager?.homes.first(where: { $0.uniqueIdentifier == move.scope.home }),
              let accessory = home.accessories.first(where: { $0.uniqueIdentifier == move.scope.accessory }),
              let original = accessory.room,
              move.scope.permits(home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, currentRoom: original.uniqueIdentifier, destinationName: move.scope.destinationName, now: Date(), observedDestination: home.rooms.first(where: { $0.uniqueIdentifier == move.scope.destinationRoom })?.uniqueIdentifier) else {
            fail("Plan expired or the original room changed. Import a fresh plan."); return
        }
        // Preserve the pre-change state before creating a room or submitting an assignment.
        do { try save(LocalReceipt(operationID: operationID, schemaVersion: 1, phase: "before", home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, original: original.uniqueIdentifier, destination: original.uniqueIdentifier, name: accessory.name, originalName: original.name, destinationName: move.scope.destinationName, timestamp: Date())) }
        catch { fail("Could not save the local rollback record; no move submitted."); return }
        var settled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.active, generation == self.batchGeneration, !settled else { return }
            settled = true
            self.fail("HomeKit timed out. Its final state is unknown; a late completion may still arrive.")
        }
        func assign(_ destination: HMRoom) {
            guard self.active, generation == self.batchGeneration, !settled,
                  move.scope.permits(home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, currentRoom: accessory.room?.uniqueIdentifier ?? UUID(), destinationName: destination.name, now: Date(), observedDestination: destination.uniqueIdentifier) else {
                settled = true; self.fail("Move scope changed or expired before submission."); return
            }
            let pending = LocalReceipt(operationID: operationID, schemaVersion: 1, phase: "submitted", home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, original: original.uniqueIdentifier, destination: destination.uniqueIdentifier, name: accessory.name, originalName: original.name, destinationName: destination.name, timestamp: Date())
            do { try self.save(pending) }
            catch { settled = true; self.fail("Could not save the local submission record; no move submitted."); return }
            self.pendingOperation = PendingRoomOperation(id: operationID, home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, original: original.uniqueIdentifier, destination: destination.uniqueIdentifier, destinationName: destination.name)
            do { try self.saveMarker(true) } catch { settled = true; self.fail("Could not save the pending-operation marker."); return }
            guard self.gate.begin() else { settled = true; self.fail("An earlier write requires reconciliation."); return }
            self.mutationPending = true
            home.assignAccessory(accessory, to: destination) { error in
                DispatchQueue.main.async {
                    self.gate.finished()
                    self.callbackOperations.insert(operationID)
                    if settled { self.status = "A late HomeKit completion arrived. Reconcile its actual state before further writes." }
                    guard self.active, generation == self.batchGeneration, !settled else { return }
                    if let error = error {
                        settled = true
                        let e = error as NSError
                        self.gate.uncertain(); self.quarantined = true
                        self.fail("HomeKit rejected the room move (\(e.domain) \(e.code))."); return
                    }
                    self.refresh { refreshed in
                        guard self.active, generation == self.batchGeneration, !settled else { return }
                        guard let observed = refreshed.homes.first(where: { $0.uniqueIdentifier == home.uniqueIdentifier })?.accessories.first(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }), observed.room?.uniqueIdentifier == destination.uniqueIdentifier else {
                            settled = true; self.gate.uncertain(); self.quarantined = true; self.fail("HomeKit accepted the request but refreshed inventory did not confirm the room."); return
                        }
                        do { try self.save(LocalReceipt(operationID: operationID, schemaVersion: 1, phase: "verified", home: home.uniqueIdentifier, accessory: accessory.uniqueIdentifier, original: original.uniqueIdentifier, destination: destination.uniqueIdentifier, name: accessory.name, originalName: original.name, destinationName: destination.name, timestamp: Date())) }
                        catch { settled = true; self.gate.uncertain(); self.quarantined = true; self.fail("Move verified but its recovery receipt could not be saved."); return }
                        do { try self.saveMarker(false) } catch {
                            settled = true; self.gate.uncertain(); self.quarantined = true; self.fail("Move verified but pending-state journal could not be finalized."); return
                        }
                        self.manager = refreshed
                        self.mutationPending = false
                        settled = true
                        self.completed += 1
                        self.moves.removeAll { $0.id == move.id }
                        self.next(plan, index: index + 1, generation: generation)
                    }
                }
            }
        }
        guard let targetID = move.scope.destinationRoom,
              let destination = home.rooms.first(where: { $0.uniqueIdentifier == targetID && $0.name == move.scope.destinationName }) else {
            settled = true; fail("The reviewed destination room no longer exists."); return
        }
        assign(destination)
    }
    func homeChanged() { guard !busy else { return }; moves = []; rebuild() }
    func reconcile() {
        guard !busy, instanceLock != nil, !fatalJournalError, !gate.outstanding else { status = "An earlier HomeKit operation is still outstanding. Wait for its completion before reconciling."; return }
        busy = true
        refresh { manager in
            self.manager = manager
            self.busy = false
            guard let operation = self.pendingOperation,
                  let home = manager.homes.first(where: { $0.uniqueIdentifier == operation.home && $0.uniqueIdentifier == self.selectedHome }),
                  operation.resolved(observedHome: home.uniqueIdentifier,
                    observedAccessory: home.accessories.first(where: { $0.uniqueIdentifier == operation.accessory })?.uniqueIdentifier,
                    observedRoom: home.accessories.first(where: { $0.uniqueIdentifier == operation.accessory })?.room?.uniqueIdentifier,
                    destinationRoomCount: home.rooms.filter { $0.name == operation.destinationName }.count,
                    callbackReceived: self.callbackOperations.contains(operation.id)) else {
                if !self.quarantined, self.pendingOperation == nil { self.rebuild() }
                else { self.status = "The pending operation's outcome is still unknown. Writes remain quarantined; do not retry." }
                return
            }
            do { try self.saveMarker(false) } catch { self.status = "Cannot persist fresh reconciliation; writes remain blocked."; return }
            _ = self.gate.reconcile()
            self.quarantined = false
            self.mutationPending = false
            self.rebuild()
            self.status = "Fresh HomeKit state loaded. Review the new plan or open a submitted recovery receipt before continuing."
        }
    }
    func createMissingRooms() {
        guard !busy, instanceLock != nil, !fatalJournalError, !quarantined, let home = manager?.homes.first(where: { $0.uniqueIdentifier == selectedHome }) else { return }
        let names = Array(Set(moves.filter { $0.scope.destinationRoom == nil }.map { $0.scope.destinationName })).sorted()
        guard !names.isEmpty else { return }
        moves = []; busy = true
        func step(_ offset: Int) {
            guard offset < names.count else {
                self.refresh { manager in self.manager = manager; self.busy = false; self.rebuild() }
                return
            }
            do {
                let directory = try self.recoveryDirectory()
                let intent: [String: String] = ["phase": "room-creation-intent", "home": home.uniqueIdentifier.uuidString, "name": names[offset]]
                try self.writePrivate(try JSONSerialization.data(withJSONObject: intent), to: directory.appendingPathComponent(UUID().uuidString + "-room-create.json"))
                self.pendingOperation = PendingRoomOperation(home: home.uniqueIdentifier, accessory: nil, original: nil, destination: nil, destinationName: names[offset])
                try self.saveMarker(true)
            } catch { self.busy = false; self.status = "Could not save room-creation recovery state; no room submitted."; return }
            guard self.gate.begin() else { self.busy = false; return }
            var finished = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                guard !finished else { return }
                self.gate.uncertain(); self.quarantined = true; self.busy = false
                self.status = "Room creation timed out. Reconcile after its completion; no automatic retry."
            }
            home.addRoom(withName: names[offset]) { room, error in
                DispatchQueue.main.async {
                    finished = true; self.gate.finished()
                    if let id = self.pendingOperation?.id { self.callbackOperations.insert(id) }
                    guard !self.quarantined, error == nil, room != nil else {
                        self.gate.uncertain(); self.quarantined = true; self.busy = false
                        self.status = "Room creation failed or was delayed. No accessory moves were submitted."; return
                    }
                    do { try self.saveMarker(false) } catch {
                        self.gate.uncertain(); self.quarantined = true; self.busy = false; self.status = "Created room but journal finalization failed; reconcile first."; return
                    }
                    step(offset + 1)
                }
            }
        }
        step(0)
    }
    
    private func refresh(_ completion: @escaping (HMHomeManager) -> Void) {
        verifyCompletion = completion
        let manager = HMHomeManager()
        verifier = manager
        manager.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak manager] in
            guard let self = self, let manager = manager, self.verifier === manager else { return }
            self.verifyCompletion = nil; self.verifier = nil; self.busy = false
            if self.mutationPending { self.gate.uncertain(); self.quarantined = true }
            self.status = "HomeKit did not return a fresh inventory. No further writes were submitted; reconnect and reconcile before continuing."
        }
    }
    private func recoveryDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("RoomMoveRecovery", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }
    private func writePrivate(_ data: Data, to path: URL) throws {
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let file = try FileHandle(forWritingTo: path)
        try file.synchronize(); try file.close()
    }
    private func saveMarker(_ pending: Bool) throws {
        if pending, pendingOperation == nil { throw MCPWireError.invalidFrame }
        try writePrivate(try JSONEncoder().encode(Journal(phase: pending ? "pending" : "resolved", operation: pendingOperation)), to: recoveryDirectory().appendingPathComponent("active.json"))
        if !pending { pendingOperation = nil }
    }
    private func save(_ receipt: LocalReceipt) throws {
        let directory = try recoveryDirectory()
        try writePrivate(try JSONEncoder().encode(receipt), to: directory.appendingPathComponent(UUID().uuidString + "-" + receipt.phase + ".json"))
        backupFolder = directory.path
    }

}

private struct LocalRoomEditorView: View {
    @ObservedObject var model: LocalRoomEditor
    @State private var importing = false
    @State private var rollback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Home Assistant → Apple Home Rooms").font(.title2).bold()
            Text("Matching, room changes and recovery files stay on this Mac. No power controls or device deletion.").font(.caption)
            Picker("Home", selection: $model.selectedHome) {
                Text("Select a home").tag(Optional<UUID>.none)
                ForEach(model.homes) { home in Text(home.name).tag(Optional(home.id)) }
            }.disabled(model.busy).onChange(of: model.selectedHome) { _ in model.homeChanged() }
            HStack {
                Button("Connect to HomeKit") { model.connect() }.disabled(model.connected || model.busy)
                Button("Import Home Assistant Plan") { rollback = false; importing = true }.disabled(!model.connected || model.busy)
                Button("Open Recovery Receipt") { rollback = true; importing = true }.disabled(!model.connected || model.busy)
            }
            Text(model.status).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("RoomEditor.Status")
            List(model.moves) { move in
                VStack(alignment: .leading) {
                    Text(move.name).bold()
                    Text(move.originalName + " → " + move.scope.destinationName + (move.scope.destinationRoom == nil ? " (create first)" : "")).font(.caption)
                    Text(move.homeName + " · " + move.scope.accessory.uuidString).font(.caption2)
                }
            }.frame(minHeight: 250)
            HStack {
                Button("Create Missing Rooms") { model.createMissingRooms() }.disabled(model.busy || model.quarantined || !model.moves.contains(where: { $0.scope.destinationRoom == nil }))
                Button("Reconcile Pending Operation") { model.reconcile() }.disabled(model.busy)
                Button("Move First Item") { model.apply(pilot: true) }.disabled(model.busy || model.quarantined || model.moves.isEmpty)
                Button("Apply Reviewed Moves") { model.apply(pilot: false) }.disabled(model.busy || model.quarantined || model.moves.isEmpty)
                Text("Verified this session: \(model.completed)").font(.caption)
            }
            if !model.backupFolder.isEmpty { Text("Recovery: " + model.backupFolder).font(.caption).textSelection(.enabled) }
        }
        .padding()
        .frame(minWidth: 800, minHeight: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.importFile(url, rollback: rollback) }
        }
    }
}
