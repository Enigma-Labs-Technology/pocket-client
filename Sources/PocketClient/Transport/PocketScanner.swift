// pocket-client/Sources/PocketClient/Transport/PocketScanner.swift
import Foundation
@preconcurrency import CoreBluetooth

/// Live enumeration of nearby Pocket recorders — the picker feed a pairing
/// UI needs before any connection exists. Strictly link-layer: it reads
/// advertisements and never connects, so it can send no commands and touches
/// no GATT table at all (see the safety note on `PocketGATT` — with no
/// connection there is nothing to discover, wildcard or otherwise).
///
///     let scanner = PocketScanner()
///     for await state in scanner.updates() {
///         // .scanning(nearby)                      → render the picker rows
///         // .poweredOff/.unauthorized/.unsupported → say why scanning can't run
///     }
///
/// The radio scans only while at least one `updates()` consumer is alive:
/// ending the loop (or cancelling its task) stops the scan — a scanner left
/// running is a battery bug, so consumption is the on-switch. Scanning uses
/// the package's proven discovery approach: a no-filter scan plus the
/// `PKT01_` name gate (the device does not advertise its service UUID), with
/// duplicate deliveries enabled so signal strength stays live (iOS honors
/// that in the foreground only — exactly where a pairing picker lives).
///
/// The scanner owns a central manager of its own, created on the first
/// `updates()` call — constructing one is what triggers the OS Bluetooth
/// permission prompt, so a merely-instantiated scanner is inert — and
/// separate from any `BLETransport`'s central, so enumeration can never
/// leave the transport in a state that breaks a later connect. Scanning
/// while a connect runs is legal but wastes radio time: cancel the consumer
/// once the user picks a row, then hand its `identifier` to
/// `BLETransport.connect(to:)`.
///
/// Unlike `BLETransport`, a scanner is NOT single-use: calling `updates()`
/// again after the last consumer went away scans afresh, and every scanning
/// session starts with an empty list — rows from a previous session (or from
/// before a radio bounce) are never shown as live.
///
/// Threading: every mutable property is confined to `queue`, the serial
/// queue the central delivers its callbacks on — the same discipline as
/// `BLETransport`.
public final class PocketScanner: NSObject, @unchecked Sendable {

    /// What the picker should show right now. The unavailability cases are
    /// deliberately distinct: "turn Bluetooth on" (`poweredOff`), "allow the
    /// app to use Bluetooth" (`unauthorized`) and "this device cannot do
    /// BLE" (`unsupported`) need different words in the UI, and the UI
    /// cannot invent that distinction itself.
    public enum State: Sendable, Equatable {
        /// The radio's state is not known yet (also a resetting radio).
        case starting
        case poweredOff
        case unauthorized
        case unsupported
        /// Scanning is live; the current rows, in first-seen order.
        case scanning([NearbyPocket])
    }

    private let queue = DispatchQueue(label: "pocket.ble.scan")
    private let clock = ContinuousClock()

    // MARK: Queue-confined state

    /// Created on the first `updates()` call, never in `init`: constructing
    /// a CBCentralManager triggers the OS permission prompt, and merely
    /// instantiating a scanner must not.
    private var central: CBCentralManager?
    private var list: BLEScanList
    private var subscribers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var scanningActive = false
    private var pruneTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - namePrefix: advertising-name filter. The literal default mirrors
    ///     `PocketGATT.namePrefix` (an internal constant cannot appear in a
    ///     public default argument).
    ///   - ageOut: how long a device may stay silent before its row is
    ///     removed. The literal default mirrors `BLEScanList.defaultAgeOut`
    ///     (same visibility constraint) — a judgment call pending real
    ///     advertisement-cadence measurements, injectable so it can be tuned
    ///     the moment hardware provides them.
    public init(namePrefix: String = "PKT01_", ageOut: Duration = .seconds(10)) {
        list = BLEScanList(namePrefix: namePrefix, ageOut: ageOut)
        super.init()
    }

    deinit {
        // Every queued block and in-flight callback holds a strong self, so
        // deinit only runs with the queue quiet — touching state here is
        // safe. Dropping the central ends any OS scan; finishing the streams
        // keeps a consumer from parking forever on a dead scanner.
        for continuation in subscribers.values { continuation.finish() }
        pruneTimer?.cancel()
    }

    /// A live feed of scanner state, starting with the current state. Each
    /// call is an independent consumer; the radio scans while at least one
    /// exists and stops when the last goes away (ending the `for await`
    /// loop, or cancelling its task, is the off-switch). A slow consumer
    /// only ever sees the newest state — snapshots are superseded, never
    /// queued up.
    public func updates() -> AsyncStream<State> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.removeSubscriber(token) }
        }
        queue.async { [self] in addSubscriber(token, continuation) }
        return stream
    }

    /// The picker state a radio state forces, or nil when the radio is
    /// poweredOn and scanning can proceed. Pure so tests can pin that each
    /// unavailability reason stays distinct — the UI's wording depends on it.
    static func unavailableState(for state: CBManagerState) -> State? {
        switch state {
        case .poweredOn:            return nil
        case .poweredOff:           return .poweredOff
        case .unauthorized:         return .unauthorized
        case .unsupported:          return .unsupported
        case .unknown, .resetting:  return .starting
        @unknown default:           return .starting
        }
    }

    // MARK: - Queue-confined helpers

    private func addSubscriber(_ token: UUID, _ continuation: AsyncStream<State>.Continuation) {
        subscribers[token] = continuation
        let central = ensureCentral()
        startScanningIfNeeded()
        continuation.yield(currentState(of: central))
    }

    private func removeSubscriber(_ token: UUID) {
        guard subscribers.removeValue(forKey: token) != nil else { return }
        if subscribers.isEmpty { stopScanning() }
    }

    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let created = CBCentralManager(delegate: self, queue: queue)
        central = created
        return created
    }

    private func currentState(of central: CBCentralManager) -> State {
        Self.unavailableState(for: central.state) ?? .scanning(list.nearby)
    }

    private func startScanningIfNeeded() {
        guard !scanningActive, !subscribers.isEmpty,
              let central, central.state == .poweredOn else { return }
        scanningActive = true
        list.removeAll()   // each scanning session starts fresh
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pruneInterval, repeating: Self.pruneInterval,
                       leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.pruneTick() }
        timer.resume()
        pruneTimer = timer
    }

    private func stopScanning() {
        guard scanningActive else { return }
        scanningActive = false
        pruneTimer?.cancel()
        pruneTimer = nil
        // A radio that left poweredOn stopped the scan itself; only a
        // powered-on central accepts (or needs) an explicit stop.
        if let central, central.state == .poweredOn { central.stopScan() }
        list.removeAll()
    }

    private func pruneTick() {
        guard scanningActive else { return }
        if list.prune(at: clock.now) { broadcast(.scanning(list.nearby)) }
    }

    private func broadcast(_ state: State) {
        for continuation in subscribers.values { continuation.yield(state) }
    }

    /// How often silence is checked for; comfortably finer than the age-out.
    private static let pruneInterval: DispatchTimeInterval = .seconds(1)
}

// MARK: - CBCentralManagerDelegate (all callbacks arrive on `queue`)

extension PocketScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Consumers already waiting when the radio comes up (or back up
            // after a bounce) resume scanning without re-subscribing.
            startScanningIfNeeded()
        } else {
            stopScanning()
        }
        broadcast(currentState(of: central))
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanningActive else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        if list.record(name: name, identifier: peripheral.identifier,
                       rssi: RSSI.intValue, at: clock.now) {
            broadcast(.scanning(list.nearby))
        }
    }
}

// MARK: - Scan-list policy (pure, unit-tested)

/// The scan list's entire behavior — what enters, what one more
/// advertisement changes, how rows are ordered, when silence removes one —
/// factored free of CoreBluetooth so it is unit-testable with no radio (the
/// same pattern as `BLERestoration`). `PocketScanner`'s delegate shell does
/// nothing but feed this type and broadcast when it reports a visible change.
struct BLEScanList {
    /// CoreBluetooth's "no reading available" RSSI sentinel.
    static let rssiUnavailable = 127
    /// A row whose device has been this silent is removed. An advertising
    /// Pocket beacons several times a second (and duplicate deliveries are
    /// enabled), so ten silent seconds means gone — powered off, out of
    /// range, or connected elsewhere — not merely unlucky.
    static let defaultAgeOut: Duration = .seconds(10)

    let namePrefix: String
    let ageOut: Duration

    private struct Entry {
        let identifier: UUID
        var name: String
        var rssi: Int?
        var lastSeen: ContinuousClock.Instant
    }

    private var entries: [Entry] = []

    init(namePrefix: String, ageOut: Duration = BLEScanList.defaultAgeOut) {
        self.namePrefix = namePrefix
        self.ageOut = ageOut
    }

    /// The picker rows, in FIRST-SEEN order. That ordering IS the damping
    /// policy: RSSI jitters by tens of dB between advertisements, and a list
    /// sorted by it reshuffles under the user's thumb exactly as they reach
    /// for a row. First-seen order never moves an existing row — new devices
    /// append, aged-out devices vanish, nothing else changes position.
    /// Signal strength is row *data* (a proximity hint), never a sort key.
    var nearby: [NearbyPocket] {
        entries.map { NearbyPocket(identifier: $0.identifier, name: $0.name, rssi: $0.rssi) }
    }

    /// Folds one advertisement in. Returns whether the *visible* list
    /// changed — the shell broadcasts only then, so consumers are not
    /// re-rendered for the (overwhelmingly common) advertisement that
    /// changes nothing. A liveness refresh alone is invisible and reports
    /// false, but still counts against age-out.
    mutating func record(name: String?, identifier: UUID, rssi: Int,
                         at now: ContinuousClock.Instant) -> Bool {
        guard let name, name.hasPrefix(namePrefix) else { return false }
        let reading: Int? = rssi == Self.rssiUnavailable ? nil : rssi
        guard let index = entries.firstIndex(where: { $0.identifier == identifier }) else {
            entries.append(Entry(identifier: identifier, name: name, rssi: reading, lastSeen: now))
            return true
        }
        let visiblyChanged = entries[index].name != name
            || (reading != nil && entries[index].rssi != reading)
        entries[index].name = name
        // The unavailable sentinel refreshes liveness but keeps the last
        // real reading — a sentinel must never blank a working indicator.
        if let reading { entries[index].rssi = reading }
        entries[index].lastSeen = now
        return visiblyChanged
    }

    /// Removes rows whose device has been silent for longer than `ageOut` —
    /// strictly, so a row seen exactly `ageOut` ago survives. Returns
    /// whether anything was removed.
    mutating func prune(at now: ContinuousClock.Instant) -> Bool {
        let before = entries.count
        entries.removeAll { now - $0.lastSeen > ageOut }
        return entries.count != before
    }

    mutating func removeAll() {
        entries = []
    }
}
