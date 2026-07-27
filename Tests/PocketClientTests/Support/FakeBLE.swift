// pocket-client/Tests/PocketClientTests/Support/FakeBLE.swift
//
// A radio that isn't. `BLETransport` reaches CoreBluetooth only through the
// `BLECentral`/`BLEPeripheral` seam (see `Sources/.../BLESeam.swift`), so
// everything below can stand in for the real stack: the state machine runs
// unmodified, in-process, with no device, no permission prompt, and no risk
// of sending a byte to hardware that can be bricked by the wrong one.
//
// DETERMINISM. Every callback the fake delivers is dispatched with
// `queue.async` on the transport's own serial queue — the same queue
// CoreBluetooth delivers on. Because the fake's methods are themselves called
// from inside the transport's queue blocks, a scripted reply is always
// scheduled BEHIND the block that triggered it: the transport finishes arming
// before it can be answered. No sleeps, no gates, no polling for state.
//
// THREADING. Scripted fields are set before the transport is driven, or
// mutated inside a queue block by the `deliver`/`power`/`advertise` helpers.
// Reads all happen on the queue. The recording log is separately lock-guarded
// because the test thread reads it while the queue writes it.
import Foundation
import CoreBluetooth
import Testing
@testable import PocketClient

// MARK: - Recording

/// One thing the transport asked the radio to do.
///
/// Discovery calls carry their UUID lists, which is the point: the package's
/// central safety property ("explicit UUIDs, never a `nil` wildcard") stops
/// being a code-reading exercise and becomes an assertion.
enum BLECall: Equatable, CustomStringConvertible {
    case beginScan
    case endScan
    case connect(UUID)
    case cancelConnection(UUID)
    case retrieve(UUID)
    case discoverServices(peripheral: UUID, uuids: [CBUUID])
    case discoverCharacteristics(peripheral: UUID, service: CBUUID, uuids: [CBUUID])
    case setNotify(Bool, CBUUID)
    case write(Data)

    var description: String {
        switch self {
        case .beginScan: return "beginScan"
        case .endScan: return "endScan"
        case .connect(let id): return "connect(\(id))"
        case .cancelConnection(let id): return "cancel(\(id))"
        case .retrieve(let id): return "retrieve(\(id))"
        case .discoverServices(_, let uuids): return "discoverServices(\(uuids))"
        case .discoverCharacteristics(_, let service, let uuids):
            return "discoverCharacteristics(\(uuids), for: \(service))"
        case .setNotify(let on, let uuid): return "setNotify(\(on), \(uuid))"
        case .write(let data): return "write(\(data.count) bytes)"
        }
    }

    /// The UUID list of a discovery call, or nil for anything else. What the
    /// explicit-discovery assertions are written against.
    var discoveryUUIDs: [CBUUID]? {
        switch self {
        case .discoverServices(_, let uuids), .discoverCharacteristics(_, _, let uuids): return uuids
        default: return nil
        }
    }
}

/// Ordered record of every call into the fake radio. Lock-guarded: the
/// transport's queue writes it while the test thread reads it.
final class BLECallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BLECall] = []

    func record(_ call: BLECall) {
        lock.lock()
        storage.append(call)
        lock.unlock()
    }

    var calls: [BLECall] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func contains(_ call: BLECall) -> Bool { calls.contains(call) }
    func count(of call: BLECall) -> Int { calls.filter { $0 == call }.count }
    func count(where predicate: (BLECall) -> Bool) -> Int { calls.filter(predicate).count }

    /// Suspends until a matching call has been recorded; returns false if it
    /// never arrives. Polling, deliberately: this file's whole job is proving
    /// the transport's continuation discipline, and adding another
    /// continuation here would put the instrument and the subject on the same
    /// footing.
    @discardableResult
    func wait(for predicate: @escaping @Sendable (BLECall) -> Bool,
              within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: within)
        while ContinuousClock().now < deadline {
            if calls.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    @discardableResult
    func wait(for call: BLECall, within: Duration = .seconds(5)) async -> Bool {
        await wait(for: { $0 == call }, within: within)
    }
}

// MARK: - Scripted outcomes

/// A radio failure shaped like CoreBluetooth's: what the transport quotes into
/// its own messages is `localizedDescription`, which a bare Swift enum does not
/// carry — it degrades to "The operation couldn't be completed", losing the one
/// detail the diagnostic exists to preserve.
struct RadioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// How the fake answers one radio operation.
enum FakeOutcome {
    case succeed
    case fail(any Error)
    /// No callback at all — the radio simply never answers. The shape every
    /// timeout, cancellation and "is anything still parked?" test needs.
    case silent
}

/// Whether cancelling a connection produces a `didDisconnect` callback.
///
/// CoreBluetooth reports the link ending for a connection that was UP. What it
/// does for a *pending* connect that never completed is not contractually
/// pinned, so the default models the conservative reading ("nothing was
/// connected, nothing disconnects") and `.always` lets a test drive the other
/// shape explicitly — `BLETransport` is written to survive both.
enum DisconnectOnCancel {
    case whenConnected
    case always
    case never
}

// MARK: - Fake GATT objects

final class FakeCharacteristic: BLECharacteristic, @unchecked Sendable {
    let uuid: CBUUID
    var properties: CBCharacteristicProperties
    var isNotifying = false
    var value: Data?

    init(_ uuid: CBUUID, properties: CBCharacteristicProperties = [.write, .notify]) {
        self.uuid = uuid
        self.properties = properties
    }
}

final class FakeService: BLEService, @unchecked Sendable {
    let uuid: CBUUID
    /// What the device actually has — the fake's ground truth, including
    /// characteristics this package must never touch.
    let table: [FakeCharacteristic]
    /// What discovery has REVEALED so far. nil until the transport asks, and
    /// only ever the subset it explicitly asked for.
    var discoveredCharacteristics: [any BLECharacteristic]?

    init(_ uuid: CBUUID, characteristics: [FakeCharacteristic]) {
        self.uuid = uuid
        self.table = characteristics
    }

    func reveal(only uuids: [CBUUID]) {
        discoveredCharacteristics = table.filter { uuids.contains($0.uuid) }
    }

    func revealEverything() { discoveredCharacteristics = table }

    func characteristic(_ uuid: CBUUID) -> FakeCharacteristic? { table.first { $0.uuid == uuid } }
}

final class FakePeripheral: BLEPeripheral, @unchecked Sendable {
    let identifier: UUID
    var name: String?
    var state: CBPeripheralState = .disconnected
    var advertisementData: [String: Any] = [:]

    /// The device's real GATT table. `FakeBLE.pocket()` fills it with the
    /// recorder's ACTUAL map, forbidden services and all, so a discovery test
    /// has something dangerous to accidentally enumerate.
    let table: [FakeService]
    /// Services discovery (or a restored attribute cache) has revealed.
    var discoveredServices: [any BLEService]?

    // Scripted outcomes. Set before the operation they govern is triggered.
    var connectOutcome: FakeOutcome = .succeed
    var serviceDiscovery: FakeOutcome = .succeed
    var characteristicDiscovery: FakeOutcome = .succeed
    var notifyOutcome: FakeOutcome = .succeed
    var writeOutcome: FakeOutcome = .succeed
    var disconnectOnCancel: DisconnectOnCancel = .whenConnected

    private(set) weak var delegate: (any BLEDelegate)?
    private var queue: DispatchQueue?
    private var log = BLECallLog()

    init(identifier: UUID = UUID(), name: String?, services: [FakeService]) {
        self.identifier = identifier
        self.name = name
        self.table = services
    }

    /// Wires the peripheral into the transport's world. Called by the central
    /// for every peripheral it knows about.
    func attach(queue: DispatchQueue, log: BLECallLog) {
        self.queue = queue
        self.log = log
    }

    // MARK: BLEPeripheral

    func attachDelegate(_ delegate: any BLEDelegate) { self.delegate = delegate }

    func discoverServices(only serviceUUIDs: [CBUUID]) {
        log.record(.discoverServices(peripheral: identifier, uuids: serviceUUIDs))
        switch serviceDiscovery {
        case .silent:
            return
        case .fail(let error):
            deliver { $0.bleDidDiscoverServices(self, error: error) }
        case .succeed:
            deliver {
                // The fake honors the filter, exactly as a real device does:
                // whatever was NOT asked for stays invisible.
                self.discoveredServices = self.table.filter { serviceUUIDs.contains($0.uuid) }
                $0.bleDidDiscoverServices(self, error: nil)
            }
        }
    }

    func discoverCharacteristics(only characteristicUUIDs: [CBUUID], for service: any BLEService) {
        log.record(.discoverCharacteristics(peripheral: identifier, service: service.uuid,
                                            uuids: characteristicUUIDs))
        guard let service = service as? FakeService else { return }
        switch characteristicDiscovery {
        case .silent:
            return
        case .fail(let error):
            deliver { $0.bleDidDiscoverCharacteristics(self, for: service, error: error) }
        case .succeed:
            deliver {
                service.reveal(only: characteristicUUIDs)
                $0.bleDidDiscoverCharacteristics(self, for: service, error: nil)
            }
        }
    }

    func setNotify(_ enabled: Bool, for characteristic: any BLECharacteristic) {
        log.record(.setNotify(enabled, characteristic.uuid))
        guard let characteristic = characteristic as? FakeCharacteristic else { return }
        switch notifyOutcome {
        case .silent:
            return
        case .fail(let error):
            deliver { $0.bleDidUpdateNotificationState(self, for: characteristic, error: error) }
        case .succeed:
            deliver {
                characteristic.isNotifying = enabled
                $0.bleDidUpdateNotificationState(self, for: characteristic, error: nil)
            }
        }
    }

    func writeWithResponse(_ data: Data, to characteristic: any BLECharacteristic) {
        log.record(.write(data))
        guard let characteristic = characteristic as? FakeCharacteristic else { return }
        switch writeOutcome {
        case .silent:
            return
        case .fail(let error):
            deliver { $0.bleDidWriteValue(self, for: characteristic, error: error) }
        case .succeed:
            deliver { $0.bleDidWriteValue(self, for: characteristic, error: nil) }
        }
    }

    // MARK: Test-side drive

    /// Emits a notification on a channel, the way the device does. Sequential
    /// calls keep their order: each is its own queue block, and the value is
    /// set inside it, immediately before the callback that reads it.
    func notify(_ channel: CBUUID, _ payload: Data,
                sourceLocation: SourceLocation = #_sourceLocation) {
        guard let characteristic = service(containing: channel) else {
            Issue.record("no characteristic \(channel) on this device", sourceLocation: sourceLocation)
            return
        }
        driveOrReport("a notification on \(channel)", {
            characteristic.value = payload
            $0.bleDidUpdateValue(self, for: characteristic, error: nil)
        }, sourceLocation: sourceLocation)
    }

    /// Acknowledges the oldest unacknowledged write, for a peripheral whose
    /// `writeOutcome` is `.silent`.
    func acknowledgeWrite(channel: CBUUID = PocketGATT.command, error: (any Error)? = nil,
                          sourceLocation: SourceLocation = #_sourceLocation) {
        guard let characteristic = service(containing: channel) else {
            Issue.record("no characteristic \(channel) on this device", sourceLocation: sourceLocation)
            return
        }
        driveOrReport("a write acknowledgement on \(channel)", {
            $0.bleDidWriteValue(self, for: characteristic, error: error)
        }, sourceLocation: sourceLocation)
    }

    /// Reports the notification state the device chose, for a `.silent`
    /// `notifyOutcome` — including "enabled the write, but reported off".
    func reportNotifyState(_ channel: CBUUID, notifying: Bool, error: (any Error)? = nil,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let characteristic = service(containing: channel) else {
            Issue.record("no characteristic \(channel) on this device", sourceLocation: sourceLocation)
            return
        }
        driveOrReport("a notification-state report on \(channel)", {
            characteristic.isNotifying = notifying
            $0.bleDidUpdateNotificationState(self, for: characteristic, error: error)
        }, sourceLocation: sourceLocation)
    }

    /// The device (or the link) goes away on its own.
    func dropLink(error: (any Error)? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        driveOrReport("a link drop", {
            self.state = .disconnected
            $0.bleDidDisconnect(self, error: error)
        }, sourceLocation: sourceLocation)
    }

    /// Completes a `.silent` connect attempt.
    func completeConnect(sourceLocation: SourceLocation = #_sourceLocation) {
        driveOrReport("a connect completion", {
            self.state = .connected
            $0.bleDidConnect(self)
        }, sourceLocation: sourceLocation)
    }

    /// Fills in the attribute cache iOS hands back through state restoration:
    /// the command service and its three channels, exactly what the previous
    /// life had discovered.
    func restoreFullCache() {
        discoveredServices = table.filter { $0.uuid == PocketGATT.service }
        commandService?.revealEverything()
    }

    /// A restored cache that knows the service but not its characteristics.
    func restoreServiceOnlyCache() {
        discoveredServices = table.filter { $0.uuid == PocketGATT.service }
        commandService?.discoveredCharacteristics = nil
    }

    var commandService: FakeService? { table.first { $0.uuid == PocketGATT.service } }

    private func service(containing characteristic: CBUUID) -> FakeCharacteristic? {
        table.compactMap { $0.characteristic(characteristic) }.first
    }

    private func deliver(_ body: @escaping (any BLEDelegate) -> Void) {
        guard let queue else { return }
        queue.async { [self] in
            guard let delegate else { return }
            body(delegate)
        }
    }

    /// `deliver` for the test-side drive helpers, which reports rather than
    /// shrugs when the peripheral has no delegate.
    ///
    /// A peripheral only gets one when the transport attaches it, so driving
    /// one it never adopted means the test is wrong about what the transport
    /// did. Silently dropping the delivery turns that into an eternal wait on
    /// a stream that will never yield — a hung suite reports NOTHING, which is
    /// the worst failure mode a test can have. (The scripted radio replies
    /// keep the quiet path: a discarded leftover legitimately has no delegate.)
    private func driveOrReport(_ what: String, _ body: @escaping (any BLEDelegate) -> Void,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard queue != nil else {
            Issue.record("\(name ?? "peripheral") was never attached to a central; \(what) went nowhere",
                         sourceLocation: sourceLocation)
            return
        }
        guard delegate != nil else {
            Issue.record("""
                \(name ?? "peripheral") has no delegate — the transport never attached it, \
                so \(what) went nowhere. The test is driving a peripheral the transport is \
                not talking to.
                """, sourceLocation: sourceLocation)
            return
        }
        deliver(body)
    }
}

// MARK: - Fake central

final class FakeCentral: BLECentral, @unchecked Sendable {
    let log = BLECallLog()
    var state: CBManagerState

    /// Advertisers the scan finds, in order.
    var advertisers: [FakePeripheral] = []
    /// Peripherals this system remembers — what `connect(to:)` resolves
    /// against. An identifier missing here is the `deviceNotFound` case.
    var known: [FakePeripheral] = []
    /// Peripherals iOS hands back through `willRestoreState`, delivered as the
    /// very first callback exactly as CoreBluetooth does.
    var restored: [FakePeripheral] = []
    /// Whether construction announces the initial radio state, the way a real
    /// central does. Off for tests that want to drive power-up by hand.
    var announcesStateAtLaunch = true

    private(set) var constructionOptions: [String: Any]?
    private(set) weak var delegate: (any BLEDelegate)?
    private var queue: DispatchQueue!
    private var scanning = false

    init(state: CBManagerState = .poweredOn) {
        self.state = state
    }

    /// The factory body: wires this central into a transport under
    /// construction, then replays a real central's opening sequence.
    func adopt(delegate: any BLEDelegate, queue: DispatchQueue, options: [String: Any]?) {
        self.delegate = delegate
        self.queue = queue
        self.constructionOptions = options
        for peripheral in advertisers + known + restored {
            peripheral.attach(queue: queue, log: log)
        }
        // willRestoreState first, then the initial didUpdateState — the order
        // CoreBluetooth uses, and the one the transport's deferred-restoration
        // design depends on.
        if !restored.isEmpty {
            let restored = restored
            queue.async { delegate.bleWillRestoreState(self, peripherals: restored) }
        }
        if announcesStateAtLaunch {
            queue.async { delegate.bleDidUpdateState(self) }
        }
    }

    // MARK: BLECentral

    func beginScan() {
        log.record(.beginScan)
        scanning = true
        for peripheral in advertisers { announce(peripheral) }
    }

    func endScan() {
        log.record(.endScan)
        scanning = false
    }

    func connectPeripheral(_ peripheral: any BLEPeripheral) {
        log.record(.connect(peripheral.identifier))
        guard let peripheral = peripheral as? FakePeripheral else { return }
        peripheral.state = .connecting
        switch peripheral.connectOutcome {
        case .silent:
            return
        case .fail(let error):
            queue.async { [self] in
                peripheral.state = .disconnected
                delegate?.bleDidFailToConnect(peripheral, error: error)
            }
        case .succeed:
            queue.async { [self] in
                peripheral.state = .connected
                delegate?.bleDidConnect(peripheral)
            }
        }
    }

    func cancelConnection(to peripheral: any BLEPeripheral) {
        log.record(.cancelConnection(peripheral.identifier))
        guard let peripheral = peripheral as? FakePeripheral else { return }
        let wasConnected = peripheral.state == .connected
        peripheral.state = .disconnected
        switch peripheral.disconnectOnCancel {
        case .never: return
        case .whenConnected where !wasConnected: return
        default: break
        }
        queue.async { [self] in delegate?.bleDidDisconnect(peripheral, error: nil) }
    }

    func knownPeripheral(withIdentifier identifier: UUID) -> (any BLEPeripheral)? {
        log.record(.retrieve(identifier))
        return known.first { $0.identifier == identifier }
    }

    // MARK: Test-side drive

    /// Runs `body` on the transport's serial queue and waits for it to finish.
    ///
    /// Two jobs, both about determinism. It FLUSHES: every callback the fake
    /// scheduled before this point has run by the time it returns, so an
    /// assertion about the recorded log is reading a settled world. And it is
    /// the race-free way to re-script the fake between operations — the queue
    /// is where every other read of these fields happens.
    func settle(_ body: @escaping @Sendable () -> Void = {}) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                body()
                continuation.resume()
            }
        }
    }

    /// A radio state change, delivered like the real `didUpdateState`.
    func power(_ newState: CBManagerState) {
        queue.async { [self] in
            state = newState
            delegate?.bleDidUpdateState(self)
        }
    }

    /// A device that starts advertising after the scan began.
    func advertise(_ peripheral: FakePeripheral) {
        peripheral.attach(queue: queue, log: log)
        queue.async { [self] in
            advertisers.append(peripheral)
            announce(peripheral)
        }
    }

    private func announce(_ peripheral: FakePeripheral) {
        queue.async { [self] in
            guard scanning, let delegate else { return }
            delegate.bleDidDiscoverPeripheral(peripheral, advertisementData: peripheral.advertisementData)
        }
    }
}

// MARK: - Builders

enum FakeBLE {
    /// The recorder's forbidden services — the real UUIDs from the protocol
    /// map. Present in every fake device precisely so a discovery bug has
    /// something to enumerate that it must not.
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    static let factoryService = CBUUID(string: "FFD0")
    static let otaService = CBUUID(string: "E49A3001-F69A-11E8-8EB2-F2801F1B9FD1")
    static let provisioningService = CBUUID(string: "E49A25F8-F69A-11E8-8EB2-F2801F1B9FD1")

    /// Every service UUID a Pocket exposes that this package must never touch.
    static let forbiddenServices = [batteryService, factoryService, otaService, provisioningService]

    /// ...and every characteristic behind them. Checked separately because a
    /// discovery call that names a forbidden CHARACTERISTIC while naming only
    /// the allowed SERVICE is a distinct mistake, and a service-only sweep
    /// would miss it.
    static let forbiddenCharacteristics = [
        batteryLevel,
        CBUUID(string: "FFD1"), CBUUID(string: "FFD2"), CBUUID(string: "FFD3"),
        CBUUID(string: "E49A3002-F69A-11E8-8EB2-F2801F1B9FD1"),
        CBUUID(string: "E49A3003-F69A-11E8-8EB2-F2801F1B9FD1"),
        CBUUID(string: "E49A25E0-F69A-11E8-8EB2-F2801F1B9FD1"),
        CBUUID(string: "E49A28E1-F69A-11E8-8EB2-F2801F1B9FD1"),
    ]

    /// A fake Pocket carrying the device's ACTUAL GATT map (see
    /// docs/protocol/ble-protocol.md): the battery service, the two
    /// combo-chip OTA/provisioning services, the factory service, and the
    /// `001120a*` command service with its three channels.
    static func pocket(name: String? = "PKT01_EXAMPLE", identifier: UUID = UUID()) -> FakePeripheral {
        FakePeripheral(identifier: identifier, name: name, services: [
            FakeService(batteryService, characteristics: [
                FakeCharacteristic(batteryLevel, properties: [.read, .notify]),
            ]),
            FakeService(factoryService, characteristics: [
                FakeCharacteristic(CBUUID(string: "FFD1"), properties: [.write]),
                FakeCharacteristic(CBUUID(string: "FFD2"), properties: [.notify]),
                FakeCharacteristic(CBUUID(string: "FFD3"), properties: [.write, .notify]),
            ]),
            FakeService(otaService, characteristics: [
                FakeCharacteristic(CBUUID(string: "E49A3002-F69A-11E8-8EB2-F2801F1B9FD1"),
                                   properties: [.write]),
                FakeCharacteristic(CBUUID(string: "E49A3003-F69A-11E8-8EB2-F2801F1B9FD1"),
                                   properties: [.notify]),
            ]),
            FakeService(provisioningService, characteristics: [
                FakeCharacteristic(CBUUID(string: "E49A25E0-F69A-11E8-8EB2-F2801F1B9FD1"),
                                   properties: [.write]),
                FakeCharacteristic(CBUUID(string: "E49A28E1-F69A-11E8-8EB2-F2801F1B9FD1"),
                                   properties: [.notify]),
            ]),
            FakeService(PocketGATT.service, characteristics: [
                FakeCharacteristic(PocketGATT.command, properties: [.write]),
                FakeCharacteristic(PocketGATT.bulk, properties: [.notify]),
                FakeCharacteristic(PocketGATT.response, properties: [.notify, .writeWithoutResponse]),
            ]),
        ])
    }

    /// A transport wired to `central` instead of a real `CBCentralManager`.
    static func transport(_ central: FakeCentral, namePrefix: String = "PKT01_",
                          restoreIdentifier: String? = nil) -> BLETransport {
        BLETransport(namePrefix: namePrefix, restoreIdentifier: restoreIdentifier) { delegate, queue, options in
            central.adopt(delegate: delegate, queue: queue, options: options)
            return central
        }
    }

    /// The state most tests start from: one advertiser, radio up, link
    /// resolved. Returns the connected transport and the device it found.
    static func connected(namePrefix: String = "PKT01_")
        async throws -> (BLETransport, FakeCentral, FakePeripheral) {
        let central = FakeCentral()
        let peripheral = pocket()
        central.advertisers = [peripheral]
        let transport = transport(central, namePrefix: namePrefix)
        _ = try await transport.connect(timeout: .seconds(5))
        return (transport, central, peripheral)
    }
}

// MARK: - Bounded awaiting

/// Awaits `task`, giving up after `within`.
///
/// nil means "still running" — which is exactly how a continuation bug
/// presents. Without this, the failure mode of every cancellation test in this
/// suite would be a hung run that reports nothing at all.
///
/// Deliberately NOT a task group racing a sleeper: a group awaits every child
/// before it returns, so the child observing a never-finishing task would hang
/// the very helper whose job is not to hang. The observer here is detached and
/// simply abandoned on expiry; it holds nothing but the box.
func outcome<T: Sendable>(of task: Task<T, any Error>,
                          within: Duration = .seconds(5)) async -> Result<T, any Error>? {
    let box = OutcomeBox<T>()
    Task { box.value = await task.result }
    let deadline = ContinuousClock().now.advanced(by: within)
    while ContinuousClock().now < deadline {
        if let value = box.value { return value }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return box.value
}

/// The next `count` payloads from a stream, or nil if they do not all arrive.
///
/// Bounded for the same reason as `outcome(of:)`: a stream that never yields
/// suspends its reader forever, and swift-testing then waits forever for that
/// test — the whole run ends up reporting nothing at all. Ask for what you
/// expect and let the deadline turn a silent hang into a named failure.
func payloads(_ count: Int, from stream: AsyncStream<Data>,
              within: Duration = .seconds(5)) async -> [Data]? {
    let reader = Task { () throws -> [Data] in
        var collected: [Data] = []
        for await payload in stream {
            collected.append(payload)
            if collected.count == count { break }
        }
        return collected
    }
    guard let result = await outcome(of: reader, within: within),
          let collected = try? result.get(), collected.count == count else { return nil }
    return collected
}

/// The first payload a stream delivers, or nil if none arrives in time.
func firstPayload(from stream: AsyncStream<Data>, within: Duration = .seconds(5)) async -> Data? {
    await payloads(1, from: stream, within: within)?.first
}

private final class OutcomeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<T, any Error>?

    var value: Result<T, any Error>? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

extension Result {
    var thrownError: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }

    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }
}
