// pocket-client/Sources/PocketClient/Transport/BLETransport.swift
import Foundation
@preconcurrency import CoreBluetooth

/// The only CoreBluetooth implementation of `PocketTransport`.
///
/// SAFETY: exactly three characteristics are ever resolved — the `001120a*`
/// command/response/bulk channels in `PocketGATT`. Service and characteristic
/// discovery always pass explicit UUID lists, never `nil` wildcards, so the
/// device's OTA/rebinding services are never even enumerated (see the safety
/// note on `PocketGATT`). That is now enforced by the type system as well as
/// by discipline: discovery goes through `BLEPeripheral.discoverServices(only:)`,
/// whose list is non-optional, so the wildcard is unrepresentable here — and
/// `BLEDiscoveryTests` pins the exact lists on top of that.
///
/// Threading: every mutable property is confined to `queue`, the serial
/// dispatch queue the central manager delivers its delegate callbacks on.
/// The public async methods hop onto it before touching state, which makes
/// each check-and-arm atomic with respect to the delegate.
///
/// Lifecycle: single-use, matching the protocol's single-consumer streams.
/// `disconnect()`, link loss, or radio loss permanently finishes both
/// streams — the session's consume loops depend on that to terminate — and
/// fails anything still pending. Build a new `BLETransport` (and a new
/// `PocketDevice`) for a new connection.
///
/// iOS state restoration: constructing with a `restoreIdentifier` opts in.
/// When iOS relaunches the app for a Bluetooth event,
/// `centralManager(_:willRestoreState:)` adopts the previous life's matching
/// peripheral, and `connect()` then claims that link instead of scanning —
/// the calling sequence is identical to a cold start (see README,
/// "Background execution (iOS)"). macOS has no state restoration; the
/// identifier is ignored there and this type behaves exactly as before.
///
/// Testability: the radio is reached only through the `BLECentral` /
/// `BLEPeripheral` seam (see `BLESeam.swift`), so the whole state machine —
/// connect, discovery, teardown, cancellation, the attempt tokens, state
/// restoration — runs against a fake radio in `swift test` with no device
/// present. Hardware validates the parts a fake cannot: real timing, the
/// device's actual GATT table, and whether the recorder answers at all.
public final class BLETransport: NSObject, PocketTransport, @unchecked Sendable {
    /// IUO only because `self` must already be the delegate when the central
    /// is constructed (state restoration delivers `willRestoreState` as the
    /// very first callback; a delegate attached even one statement later is a
    /// race against it). Assigned exactly once in `init`, never nil after.
    private var central: (any BLECentral)!
    private let queue = DispatchQueue(label: "pocket.ble")
    private let namePrefix: String

    // MARK: Queue-confined state

    private var peripheral: (any BLEPeripheral)?
    private var commandCharacteristic: (any BLECharacteristic)?
    private var connectContinuation: CheckedContinuation<DiscoveredDevice, Error>?
    private var poweredOnContinuation: CheckedContinuation<Void, Error>?
    /// FIFO of senders awaiting their GATT write ack; CoreBluetooth delivers
    /// `didWriteValueFor` acks for one characteristic in submission order.
    private var pendingWrites: [CheckedContinuation<Void, Error>] = []
    /// Unique token per `connect()` call, recorded at arming: a stale timeout
    /// task may only fail the attempt it belongs to (identity, not presence —
    /// the same discipline as the session's waiter generation).
    private var attemptCounter = 0
    /// INVARIANT: nonzero exactly while a stage continuation (powered-on wait
    /// or scan/resolve) is parked; zeroed at every site that resumes one. A
    /// deadline landing in the gap *between* stages then fails the identity
    /// check and poisons the attempt instead of no-opping — otherwise the
    /// next stage would arm with its timeout already spent and park forever.
    private var armedAttempt = 0
    /// Highest attempt whose deadline fired before it could arm; arming then
    /// refuses (nobody is left to expire an armed-late continuation).
    private var latestFailedAttempt = 0
    /// Set once the link is torn down; the transport is then permanently dead.
    private var closeReason: Error?

    // MARK: iOS state-restoration state (queue-confined; inert on macOS)

    /// Sticky: `willRestoreState` adopted a peripheral. Read by `wasRestored()`.
    private var adoptedFromRestore = false
    /// True from adoption until `connect()` claims the restored link — it
    /// distinguishes "restored link awaiting its connect() call" from
    /// "connect() already succeeded", which both look like a non-nil
    /// `peripheral` with no continuation armed. INVARIANT: true implies
    /// `peripheral != nil` (cleared at every site that clears `peripheral`).
    private var restoredAwaitingConnect = false
    /// Work the adoption deferred: CoreBluetooth drops GATT commands issued
    /// before the radio reports poweredOn, so `willRestoreState` only records
    /// the plan and `performDeferredRestoration()` executes it there.
    private var pendingRestorationPlan: BLERestoration.Plan?
    /// Restored peripherals that were NOT adopted: retained until poweredOn so
    /// their stale links can be cancelled, then forgotten. Their disconnect
    /// callbacks are bookkeeping, not a teardown of this transport.
    private var restorationDiscards: [any BLEPeripheral] = []

    // MARK: Diagnostics state (Task 9 harness — recording only, no BLE traffic)

    /// Snapshot of the command characteristic's GATT properties, captured at
    /// discovery time (so it survives teardown); nil until discovery completes.
    private var commandPropertiesDescription: String?
    /// Notify-enable outcomes per channel ("response"/"bulk") as reported by
    /// `peripheral(_:didUpdateNotificationStateFor:error:)`.
    private var notifyStates: [String: String] = [:]

    private let responses: AsyncStream<Data>
    private let responseContinuation: AsyncStream<Data>.Continuation
    private let bulk: AsyncStream<Data>
    private let bulkContinuation: AsyncStream<Data>.Continuation

    /// - Parameters:
    ///   - namePrefix: advertising-name filter. The literal default mirrors
    ///     `PocketGATT.namePrefix` (an internal constant cannot appear in a
    ///     public default argument).
    ///   - restoreIdentifier: opts in to CoreBluetooth state restoration
    ///     (iOS only — macOS has none, so the value is ignored there). Pass
    ///     the same stable string on every launch; nil (the default) opts out
    ///     and constructs exactly the plain central this type always used.
    ///     See README, "Background execution (iOS)".
    public convenience init(namePrefix: String = "PKT01_", restoreIdentifier: String? = nil) {
        self.init(namePrefix: namePrefix, restoreIdentifier: restoreIdentifier,
                  central: Self.liveCentral)
    }

    /// The designated initializer, taking the factory that builds the central.
    /// Internal, and the only reason the public one above is a convenience:
    /// substituting a fake radio here is what makes every path below reachable
    /// by a test (see `BLESeam.swift`). Production behavior is unchanged — the
    /// public initializer passes `liveCentral`, which constructs exactly the
    /// `CBCentralManager` this type always constructed.
    init(namePrefix: String, restoreIdentifier: String?, central makeCentral: BLECentralFactory) {
        self.namePrefix = namePrefix
        (responses, responseContinuation) = AsyncStream<Data>.makeStream()
        (bulk, bulkContinuation) = AsyncStream<Data>.makeStream()
        super.init()
        // The delegate is attached at construction so a restored central's
        // first callback (`willRestoreState`) cannot race a late assignment.
        // Without restoration the ordering is behaviorally identical: every
        // callback no-ops against the empty initial state.
        central = makeCentral(self, queue, Self.centralManagerOptions(restoreIdentifier: restoreIdentifier))
    }

    /// The one place a real `CBCentralManager` is created.
    private static let liveCentral: BLECentralFactory = { delegate, queue, options in
        CBCentralManager(delegate: delegate, queue: queue, options: options)
    }

    /// Central-manager construction options for a restore identifier.
    /// Factored out (and platform-gated) so tests can pin the contract:
    /// nil — and any identifier on macOS, which has no state restoration —
    /// yields nil options, i.e. the plain non-restoring central of today.
    static func centralManagerOptions(restoreIdentifier: String?) -> [String: Any]? {
        #if os(iOS)
        guard let restoreIdentifier else { return nil }
        return [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        #else
        return nil
        #endif
    }

    /// Waits for the radio, scans for the first advertiser whose name starts
    /// with the prefix, connects, and resolves the three channel
    /// characteristics. `timeout` covers the whole sequence.
    ///
    /// On a transport that adopted a restored peripheral (iOS state
    /// restoration), `connect()` MUST still be called and is still the first
    /// step — but it never scans: it claims the restored link, waits for any
    /// still-running discovery (or the system's in-flight connect) to finish,
    /// and returns the device, immediately if the link came back fully
    /// resolved. Either way the result is a *link*, not an authenticated
    /// *session*: the SK handshake (`PocketDevice.connect()`) always follows,
    /// restored or not — the device requires it once per connection and it
    /// does not survive a relaunch.
    public func connect(timeout: Duration = .seconds(20)) async throws -> DiscoveredDevice {
        try await establishLink(target: nil, timeout: timeout)
    }

    /// Connects to one specific Pocket by its CoreBluetooth peripheral
    /// identifier (as enumerated by `PocketScanner`, or carried by a
    /// previous `DiscoveredDevice`) — no scanning, and deliberately no
    /// fallback: an identifier this system has never seen fails immediately
    /// with `PocketError.deviceNotFound`, and one the system knows but
    /// cannot reach (device asleep, out of range, or factory-reset into a
    /// new identity) fails when `timeout` expires. Silently connecting to
    /// some *other* Pocket would defeat the point of choosing one.
    ///
    /// Everything past resolution is the scanned path: the same
    /// explicit-UUID GATT discovery, the same resolved link, and the SK
    /// handshake (`PocketDevice.connect()`) is still the caller's next step.
    public func connect(to identifier: UUID, timeout: Duration = .seconds(20)) async throws -> DiscoveredDevice {
        try await establishLink(target: identifier, timeout: timeout)
    }

    /// Shared skeleton of both connect flavors: wait for the radio, arm the
    /// link continuation (scan, retrieve-by-identifier, or restored-link
    /// claim — see `armLink`), and race it against the deadline. `timeout`
    /// covers the whole sequence, exactly as `connect()` always has.
    private func establishLink(target: UUID?, timeout: Duration) async throws -> DiscoveredDevice {
        let attempt = await allocateAttempt()
        return try await withThrowingTaskGroup(of: DiscoveredDevice.self) { group in
            group.addTask { [self] in
                try await waitUntilPoweredOn(attempt: attempt)
                return try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        armLink(attempt: attempt, target: target, continuation: continuation)
                    }
                }
            }
            group.addTask { [self] in
                try? await Task.sleep(for: timeout)
                // Runs on genuine expiry AND when cancelled by the winner:
                // cancellation alone never resumes a checked continuation,
                // and one left pending would deadlock this group. The call
                // is identity-guarded, so a resolved (or later) attempt is
                // untouched.
                let error: Error = Task.isCancelled ? CancellationError() : PocketError.timeout(.auth(""))
                failPendingConnect(attempt: attempt, with: error)
                throw error
            }
            defer { group.cancelAll() }
            guard let device = try await group.next() else { throw PocketError.disconnected }
            return device
        }
    }

    /// The check-and-arm for both connect flavors, queue-confined so it is
    /// atomic with respect to the delegate. `target == nil` is the scanning
    /// path, byte-for-byte the behavior `connect()` always had.
    private func armLink(attempt: Int, target: UUID?,
                         continuation: CheckedContinuation<DiscoveredDevice, Error>) {
        if let closeReason {
            continuation.resume(throwing: closeReason)
            return
        }
        guard attempt > latestFailedAttempt else {
            continuation.resume(throwing: PocketError.timeout(.auth("")))
            return
        }
        guard connectContinuation == nil else {
            continuation.resume(throwing: PocketError.busy("connect already in progress"))
            return
        }
        if restoredAwaitingConnect, let restored = peripheral {
            if let target, restored.identifier != target {
                // The caller asked for a specific device and the restored
                // link is a different one: the explicit choice wins. The
                // restored link is dropped like an unadopted leftover — its
                // disconnect callback is bookkeeping, not a teardown — and
                // the targeted path below proceeds. Its recovery plan dies
                // with it: left set, a deferred restoration running after
                // this arm (the early-poweredOn race) would execute the old
                // device's plan against the new target's peripheral.
                restoredAwaitingConnect = false
                peripheral = nil
                pendingRestorationPlan = nil
                restorationDiscards.append(restored)
                central.cancelConnection(to: restored)
            } else {
                // iOS state restoration adopted this link at construction;
                // connect() claims it instead of scanning. The claim is
                // single-shot: a second connect() falls through to the busy
                // guard below like any already-connected transport.
                restoredAwaitingConnect = false
                if commandCharacteristic != nil {
                    // Fully restored — link up, channels resolved; nothing
                    // left to drive.
                    continuation.resume(returning: DiscoveredDevice(name: restored.name ?? "",
                                                                    identifier: restored.identifier))
                } else {
                    // Restoration's discovery (or the system's pending
                    // connect) is still in flight; the same delegate chain
                    // that resolves a scanned peripheral resumes this
                    // continuation, and the caller's timeout still governs
                    // via failPendingConnect.
                    armedAttempt = attempt
                    connectContinuation = continuation
                }
                return
            }
        }
        guard peripheral == nil else {
            continuation.resume(throwing: PocketError.busy("connect already in progress"))
            return
        }
        if let target {
            // Resolution by identifier, never by scan; the connect chain
            // that follows passes the same explicit PocketGATT UUID lists
            // as always. An unknown identifier fails RIGHT HERE — the
            // defined stale/absent behavior, with no fallback device.
            guard let known = central.knownPeripheral(withIdentifier: target) else {
                continuation.resume(throwing: PocketError.deviceNotFound(target))
                return
            }
            armedAttempt = attempt
            connectContinuation = continuation
            peripheral = known   // must be retained or the connect is dropped
            // The system hands back ONE CBPeripheral instance per identifier,
            // so a restored-but-unadopted leftover can BE this target: reclaim
            // it, or the deferred-restoration sweep would cancel the connect
            // just issued, and discardRestorationLeftover would misread its
            // real disconnect callbacks as bookkeeping.
            if let index = restorationDiscards.firstIndex(where: { $0 === known }) {
                restorationDiscards.remove(at: index)
            }
            known.attachDelegate(self)
            central.connectPeripheral(known)
        } else {
            armedAttempt = attempt
            connectContinuation = continuation
            central.beginScan()
        }
    }

    /// Writes to the command channel (001120a2) and waits for the write ack,
    /// so GATT-level failures surface as thrown errors instead of silent
    /// losses. Pending writes are failed by `close` on any teardown; there is
    /// no per-write timer — a dead link always ends in a teardown path.
    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let closeReason {
                    continuation.resume(throwing: closeReason)
                    return
                }
                guard let peripheral, let characteristic = commandCharacteristic else {
                    continuation.resume(throwing: PocketError.disconnected)
                    return
                }
                pendingWrites.append(continuation)
                peripheral.writeWithResponse(data, to: characteristic)
            }
        }
    }

    public func responseStream() -> AsyncStream<Data> { responses }
    public func bulkStream() -> AsyncStream<Data> { bulk }

    /// Whether iOS state restoration handed this transport an existing link
    /// at construction. Always false on macOS and on transports built
    /// without a `restoreIdentifier`.
    ///
    /// A restored link is a GATT connection, NOT an authenticated session:
    /// the caller still drives the normal sequence — `connect()` (which
    /// claims the restored link instead of scanning) followed by the SK
    /// handshake via `PocketDevice.connect()`. Skipping the handshake
    /// because the link "came back" silently breaks every request: the
    /// device requires it once per connection, and it died with the old
    /// process.
    public func wasRestored() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: adoptedFromRestore) }
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                close(with: PocketError.disconnected)
                continuation.resume()
            }
        }
    }

    // MARK: - Diagnostics accessors (read-only; never touch the peripheral)

    /// The command characteristic's discovered GATT properties as a
    /// human-readable list (e.g. "write-with-response, notify"), or nil
    /// before characteristic discovery has completed. Pure reporting of
    /// already-discovered state for the CLI harness — performs no BLE
    /// operation of any kind.
    public func commandCharacteristicProperties() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: commandPropertiesDescription) }
        }
    }

    /// Notify-enable outcomes for the response and bulk characteristics,
    /// e.g. "response: enabled, bulk: enabled". "no callback yet" means
    /// CoreBluetooth has not yet acknowledged that CCCD write — persistent
    /// "no callback yet" plus a handshake timeout points at the enable, not
    /// at authentication. Pure reporting; performs no BLE operation.
    public func notifyStateSummary() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let summary = ["response", "bulk"]
                    .map { "\($0): \(notifyStates[$0] ?? "no callback yet")" }
                    .joined(separator: ", ")
                continuation.resume(returning: summary)
            }
        }
    }

    private static func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write-with-response") }
        if properties.contains(.writeWithoutResponse) { names.append("write-without-response") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        let named: CBCharacteristicProperties = [.read, .write, .writeWithoutResponse, .notify, .indicate]
        let unnamed = properties.rawValue & ~named.rawValue
        if unnamed != 0 { names.append(String(format: "+0x%02X", unnamed)) }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    // MARK: - Queue-confined helpers

    private func allocateAttempt() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                attemptCounter += 1
                continuation.resume(returning: attemptCounter)
            }
        }
    }

    /// Resolves immediately if the radio is up; otherwise parks until
    /// `centralManagerDidUpdateState` (or a teardown/timeout) resumes it.
    /// The check-and-arm runs on `queue`, so the powered-on callback cannot
    /// slip between the check and the arm.
    private func waitUntilPoweredOn(attempt: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let closeReason {
                    continuation.resume(throwing: closeReason)
                } else if central.state == .poweredOn {
                    continuation.resume()
                } else if attempt <= latestFailedAttempt {
                    continuation.resume(throwing: PocketError.timeout(.auth("")))
                } else if poweredOnContinuation != nil || connectContinuation != nil {
                    continuation.resume(throwing: PocketError.busy("connect already in progress"))
                } else {
                    armedAttempt = attempt
                    poweredOnContinuation = continuation
                }
            }
        }
    }

    /// Fails whichever stage of `connect` is pending — if, and only if, the
    /// pending stage still belongs to `attempt`. If the deadline beat the
    /// arming block onto the queue, the attempt is poisoned instead so the
    /// late arming refuses rather than parking a continuation forever.
    ///
    /// Internal rather than private so a test can drive the identity guard
    /// directly: the interleaving it defends against (a resolved attempt's
    /// cancelled deadline task landing after the NEXT attempt armed) is real
    /// but not forceable from outside, and a guard nothing can exercise is a
    /// guard nobody can prove.
    func failPendingConnect(attempt: Int, with error: Error) {
        queue.async { [self] in
            guard attempt == armedAttempt else {
                latestFailedAttempt = max(latestFailedAttempt, attempt)
                return
            }
            if let pending = poweredOnContinuation {
                poweredOnContinuation = nil
                armedAttempt = 0
                pending.resume(throwing: error)
            }
            if let pending = connectContinuation {
                connectContinuation = nil
                armedAttempt = 0
                commandCharacteristic = nil
                central.endScan()
                // A half-established link (found but not yet resolved) must
                // not be left dangling behind the failure.
                if let doomed = peripheral {
                    peripheral = nil
                    restoredAwaitingConnect = false
                    central.cancelConnection(to: doomed)
                }
                pending.resume(throwing: error)
            }
        }
    }

    /// Fails a pending connect after the link stage was reached (discovery or
    /// resolution failed) and drops the half-open connection. Also the
    /// failure path for a restored peripheral whose recovery died before
    /// `connect()` claimed it: dropping the peripheral (and the claim flag)
    /// gracefully degrades the transport to a normal scanning `connect()`.
    private func failConnect(with error: Error) {
        commandCharacteristic = nil
        if let doomed = peripheral {
            peripheral = nil
            restoredAwaitingConnect = false
            central.cancelConnection(to: doomed)
        }
        guard let pending = connectContinuation else { return }
        connectContinuation = nil
        armedAttempt = 0
        pending.resume(throwing: error)
    }

    /// The single permanent-teardown funnel: fails every pending continuation
    /// and finishes both streams, which is what lets the session's consume
    /// loops end and its `handleDisconnect` run. Idempotent; queue-confined.
    private func close(with error: Error) {
        if closeReason == nil { closeReason = error }
        commandCharacteristic = nil
        armedAttempt = 0   // nothing stays parked past this point
        restoredAwaitingConnect = false
        pendingRestorationPlan = nil
        // Unadopted restored links die with the transport. (If the radio
        // never reached poweredOn these cancels are dropped with a CoreBluetooth
        // log line — harmless; there is nothing else to do with them.)
        //
        // Clearing the pile is right HERE, unlike in performDeferredRestoration:
        // past this point nothing distinguishes bookkeeping from a teardown,
        // because there is no teardown left to do. `closeReason` is already
        // set, every continuation slot is nil and both streams are finished, so
        // a leftover's disconnect callback arriving later finds an empty pile,
        // re-enters this funnel and changes nothing. The pile may now hold
        // peripherals performDeferredRestoration already cancelled; a second
        // cancel on a link that is already down is a no-op.
        for discard in restorationDiscards { central.cancelConnection(to: discard) }
        restorationDiscards = []
        if let doomed = peripheral {
            peripheral = nil
            central.cancelConnection(to: doomed)
        }
        let writes = pendingWrites
        pendingWrites = []
        for write in writes { write.resume(throwing: error) }
        if let pending = poweredOnContinuation {
            poweredOnContinuation = nil
            pending.resume(throwing: error)
        }
        if let pending = connectContinuation {
            connectContinuation = nil
            central.endScan()
            pending.resume(throwing: error)
        }
        responseContinuation.finish()
        bulkContinuation.finish()
    }

    /// Executes what `willRestoreState` recorded, at the first poweredOn —
    /// CoreBluetooth drops GATT commands issued before the radio reports
    /// that state, so adoption defers all radio work to here. No-op unless a
    /// restoration is pending. Queue-confined.
    ///
    /// SAFETY: every discovery issued here passes the same explicit
    /// `PocketGATT` UUID lists as a scanned connect — a restored peripheral
    /// never gets wildcard discovery, and the `.ready` path issues no
    /// discovery at all (it only *searches* the restored attribute arrays
    /// for the three known UUIDs).
    private func performDeferredRestoration() {
        if connectContinuation == nil, pendingRestorationPlan != nil || !restorationDiscards.isEmpty {
            // A restored scan would be the old life's nil-service scan —
            // useless in the background and radio-hungry — so stop it. Only
            // while no connect is armed: a fast caller whose scan raced
            // ahead of willRestoreState (possible when the state property
            // read poweredOn early) keeps its scan.
            central.endScan()
        }
        // Belt-and-suspenders with the reclaim in armLink: the same
        // CBPeripheral instance can sit in both roles, and this sweep must
        // never cancel the link the transport is actively driving. Filtering
        // (rather than skipping) also drops any such alias from the pile, so
        // the active link's callbacks can never be misread as bookkeeping —
        // exactly what clearing the whole array used to guarantee.
        let doomed = restorationDiscards.filter { $0 !== peripheral }
        for discard in doomed { central.cancelConnection(to: discard) }
        // The cancelled leftovers stay LISTED until their callbacks arrive.
        // Cancelling a live link makes CoreBluetooth report it disconnected,
        // and `discardRestorationLeftover` removing the entry is the only
        // thing that tells that callback apart from a real teardown: emptying
        // the pile here left the callback to fall through the teardown funnel
        // and kill the link that WAS adopted.
        //
        // An entry whose callback never comes (a cancelled *pending* connect
        // may produce none) simply waits for `close`, which clears the pile
        // wholesale. That residue is inert: re-cancelling it on a later
        // poweredOn is a no-op, and it cannot mislabel a future link's
        // callbacks — a peripheral that becomes the active one is either
        // reclaimed out of the pile by armLink or excluded by the identity
        // guard in `discardRestorationLeftover`.
        restorationDiscards = doomed
        guard let plan = pendingRestorationPlan else { return }
        pendingRestorationPlan = nil
        guard let peripheral else { return }   // recovery already failed/closed
        switch plan {
        case .ready:
            let characteristics = peripheral.discoveredServices?
                .first { $0.uuid == PocketGATT.service }?.discoveredCharacteristics
            guard let command = characteristics?.first(where: { $0.uuid == PocketGATT.command }),
                  let response = characteristics?.first(where: { $0.uuid == PocketGATT.response }),
                  let bulkCharacteristic = characteristics?.first(where: { $0.uuid == PocketGATT.bulk })
            else {
                // The restored attribute cache thinned out between adoption
                // and power-up; re-resolve through the normal explicit-UUID
                // chain instead.
                peripheral.discoverServices(only: [PocketGATT.service])
                return
            }
            commandCharacteristic = command
            commandPropertiesDescription = Self.describeProperties(command.properties)
            // Restoration preserves CCCD subscriptions; re-arm only what the
            // relaunch actually lost.
            if !response.isNotifying { peripheral.setNotify(true, for: response) }
            if !bulkCharacteristic.isNotifying { peripheral.setNotify(true, for: bulkCharacteristic) }
            // A connect() that raced ahead of willRestoreState (possible when
            // the state property read poweredOn before the first didUpdateState
            // delivered) armed its continuation while commandCharacteristic was
            // still nil. This plan issues no discovery and no connect, so no
            // delegate callback would ever resume it: the caller would block
            // until its deadline, and failPendingConnect would then cancel a
            // perfectly good restored link — the exact background-relaunch case
            // this feature exists for. Resume it here, mirroring the resume site
            // in didDiscoverCharacteristicsFor. Single-resume discipline is
            // preserved: the slot is cleared before resuming, and every other
            // resume path guards on it being non-nil.
            guard let pending = connectContinuation else { return }
            connectContinuation = nil
            armedAttempt = 0
            restoredAwaitingConnect = false
            pending.resume(returning: DiscoveredDevice(name: peripheral.name ?? "",
                                                       identifier: peripheral.identifier))
        case .discoverCharacteristics:
            guard let service = peripheral.discoveredServices?
                .first(where: { $0.uuid == PocketGATT.service }) else {
                peripheral.discoverServices(only: [PocketGATT.service])
                return
            }
            peripheral.discoverCharacteristics(only: [PocketGATT.command, PocketGATT.response,
                                                      PocketGATT.bulk],
                                               for: service)
        case .discoverServices:
            peripheral.discoverServices(only: [PocketGATT.service])
        case .awaitSystemConnect:
            // The relaunch restored a connection attempt still in flight.
            // Re-issue it: connect on a connecting peripheral is idempotent,
            // and this guards against the pending request not surviving the
            // relaunch. didConnect then drives the normal discovery chain.
            central.connectPeripheral(peripheral)
        }
    }
}

// MARK: - CoreBluetooth delegate witnesses
//
// FORWARDING ONLY. Each of these hands CoreBluetooth's own objects to the
// seam handler for the same event and does nothing else. That emptiness is
// the point: any behavior living here would be reachable only from a real
// radio, i.e. untested exactly as before. The state machine is in the
// `BLEDelegate` extension below, where a fake radio can drive it.

extension BLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bleDidUpdateState(central)
    }

    #if os(iOS)
    /// State restoration: iOS relaunched the app for a Bluetooth event and
    /// hands back the previous life's central. Arrives on `queue` as the very
    /// first callback, before the initial didUpdateState. macOS has no state
    /// restoration, so only this witness is platform-gated — the handler it
    /// forwards to is not, which is what lets `swift test` exercise adoption
    /// and the mismatch teardown.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        bleWillRestoreState(central, peripherals: restored)
    }
    #endif

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        bleDidDiscoverPeripheral(peripheral, advertisementData: advertisementData)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bleDidConnect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        bleDidFailToConnect(peripheral, error: error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        bleDidDisconnect(peripheral, error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        bleDidDiscoverServices(peripheral, error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        bleDidDiscoverCharacteristics(peripheral, for: service, error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        bleDidWriteValue(peripheral, for: characteristic, error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        bleDidUpdateNotificationState(peripheral, for: characteristic, error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        bleDidUpdateValue(peripheral, for: characteristic, error: error)
    }
}

// MARK: - The delegate state machine (all callbacks arrive on `queue`)

extension BLETransport: BLEDelegate {
    func bleDidUpdateState(_ central: any BLECentral) {
        switch central.state {
        case .poweredOn:
            // Must run before the powered-on continuation resumes: the
            // parked connect()'s next stage is queued behind this block, so
            // a fully-restored link is already re-resolved (or its recovery
            // already in flight) by the time connect() inspects it.
            performDeferredRestoration()
            if let pending = poweredOnContinuation {
                poweredOnContinuation = nil
                // Surrender the token: nothing is parked again until the scan
                // block arms. A deadline landing in that gap has nothing to
                // fail, so it must poison the attempt — with the token still
                // held it would no-op instead, and the late-arming scan would
                // then park forever with its timeout already spent.
                armedAttempt = 0
                pending.resume()
            }
        case .unsupported, .unauthorized:
            // Terminal: no amount of waiting produces a radio.
            close(with: PocketError.transferFailed("bluetooth unavailable (state \(central.state.rawValue))"))
        case .poweredOff, .resetting:
            // An established link dies *silently* here — CoreBluetooth sends
            // no didDisconnectPeripheral when the radio goes away — so this
            // is the only place its streams can be finished. A scan cannot
            // survive a radio bounce either; only a pre-scan powered-on wait
            // keeps waiting (the radio may come back within its timeout).
            if peripheral != nil {
                close(with: PocketError.disconnected)
            } else if let pending = connectContinuation {
                connectContinuation = nil
                armedAttempt = 0
                pending.resume(throwing: PocketError.transferFailed("bluetooth powered off during scan"))
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Adopts the previous life's peripheral, or declines and records the
    /// leftovers for cancellation. This only RECORDS the adoption — the radio
    /// is not poweredOn yet and CoreBluetooth drops commands issued before it
    /// is — so `performDeferredRestoration()` executes the plan at the first
    /// poweredOn.
    ///
    /// Continuation discipline: this callback never resumes, arms, or fails
    /// any continuation, so it cannot double-resume a connect attempt in
    /// flight. If a racing `connect()` already armed its scan (possible when
    /// the caller was fast and the radio state read poweredOn early),
    /// adoption is declined entirely and the restored links are dropped.
    ///
    /// SAFETY: adoption never enumerates services or characteristics — the
    /// snapshot only *searches* the restored attribute arrays for the three
    /// `001120a*` UUIDs, and any discovery the plan later issues passes the
    /// same explicit UUID lists as a scanned connect.
    func bleWillRestoreState(_ central: any BLECentral, peripherals restored: [any BLEPeripheral]) {
        guard closeReason == nil, self.peripheral == nil, connectContinuation == nil else {
            restorationDiscards.append(contentsOf: restored)
            return
        }
        let snapshots = restored.map(BLERestoration.PeripheralSnapshot.init(of:))
        guard let adoption = BLERestoration.firstAdoptable(in: snapshots, namePrefix: namePrefix) else {
            restorationDiscards.append(contentsOf: restored)
            return
        }
        for (index, leftover) in restored.enumerated() where index != adoption.index {
            restorationDiscards.append(leftover)
        }
        let adopted = restored[adoption.index]
        peripheral = adopted
        adopted.attachDelegate(self)
        adoptedFromRestore = true
        restoredAwaitingConnect = true
        pendingRestorationPlan = adoption.plan
    }

    func bleDidDiscoverPeripheral(_ peripheral: any BLEPeripheral, advertisementData: [String: Any]) {
        // Discoveries can keep arriving until the scan stop takes effect; only
        // the first matching peripheral wins, and only while a connect is
        // pending.
        guard self.peripheral == nil, connectContinuation != nil else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.hasPrefix(namePrefix) else { return }
        central.endScan()
        self.peripheral = peripheral   // must be retained or the connect is dropped
        peripheral.attachDelegate(self)
        central.connectPeripheral(peripheral)
    }

    func bleDidConnect(_ peripheral: any BLEPeripheral) {
        // Only the command service — never a nil wildcard (see PocketGATT).
        // The seam cannot express one: `only:` takes a non-optional list.
        peripheral.discoverServices(only: [PocketGATT.service])
    }

    func bleDidFailToConnect(_ peripheral: any BLEPeripheral, error: Error?) {
        if discardRestorationLeftover(peripheral) { return }
        failConnect(with: PocketError.transferFailed(error?.localizedDescription ?? "connect failed"))
    }

    func bleDidDisconnect(_ peripheral: any BLEPeripheral, error: Error?) {
        if discardRestorationLeftover(peripheral) { return }
        close(with: PocketError.disconnected)
    }

    /// True when the callback belongs to a restored-but-unadopted peripheral
    /// being cancelled: its link ending is bookkeeping, not a teardown of
    /// this transport. Everything else (including our own cancelled
    /// half-connects, whose callbacks arrive after `peripheral` was already
    /// cleared) keeps today's behavior exactly. The ACTIVE peripheral never
    /// matches, whatever the discard pile holds — the system hands back one
    /// CBPeripheral instance per identifier, so a leftover can alias the
    /// link the transport is driving, and that link's callbacks are real.
    private func discardRestorationLeftover(_ peripheral: any BLEPeripheral) -> Bool {
        guard peripheral !== self.peripheral,
              let index = restorationDiscards.firstIndex(where: { $0 === peripheral }) else { return false }
        restorationDiscards.remove(at: index)
        return true
    }

    func bleDidDiscoverServices(_ peripheral: any BLEPeripheral, error: Error?) {
        if let error {
            failConnect(with: PocketError.transferFailed("service discovery failed: \(error.localizedDescription)"))
            return
        }
        guard let service = peripheral.discoveredServices?
            .first(where: { $0.uuid == PocketGATT.service }) else {
            failConnect(with: PocketError.transferFailed("command service not found"))
            return
        }
        // Exactly the three 001120a* channels — never a nil wildcard.
        peripheral.discoverCharacteristics(only: [PocketGATT.command, PocketGATT.response, PocketGATT.bulk],
                                           for: service)
    }

    func bleDidDiscoverCharacteristics(_ peripheral: any BLEPeripheral, for service: any BLEService,
                                       error: Error?) {
        if let error {
            failConnect(with: PocketError.transferFailed("characteristic discovery failed: \(error.localizedDescription)"))
            return
        }
        var response: (any BLECharacteristic)?
        var bulkCharacteristic: (any BLECharacteristic)?
        for characteristic in service.discoveredCharacteristics ?? [] {
            switch characteristic.uuid {
            case PocketGATT.command:
                commandCharacteristic = characteristic
                commandPropertiesDescription = Self.describeProperties(characteristic.properties)
            case PocketGATT.response: response = characteristic
            case PocketGATT.bulk:     bulkCharacteristic = characteristic
            default:                  break
            }
        }
        guard commandCharacteristic != nil, let response, let bulkCharacteristic else {
            failConnect(with: PocketError.transferFailed("channel characteristics missing"))
            return
        }
        // ATT serialises one transaction at a time, so these CCCD writes are
        // queued ahead of any later command write: notifications are armed on
        // the device before the session's handshake can reach it.
        peripheral.setNotify(true, for: response)
        peripheral.setNotify(true, for: bulkCharacteristic)
        guard let pending = connectContinuation else { return }
        connectContinuation = nil
        armedAttempt = 0
        pending.resume(returning: DiscoveredDevice(name: peripheral.name ?? "",
                                                   identifier: peripheral.identifier))
    }

    func bleDidWriteValue(_ peripheral: any BLEPeripheral, for characteristic: any BLECharacteristic,
                          error: Error?) {
        guard characteristic.uuid == PocketGATT.command, !pendingWrites.isEmpty else { return }
        let continuation = pendingWrites.removeFirst()
        if let error {
            continuation.resume(throwing: PocketError.transferFailed("write failed: \(error.localizedDescription)"))
        } else {
            continuation.resume(returning: ())
        }
    }

    /// Diagnostics only: records whether each CCCD enable succeeded so the
    /// CLI harness can distinguish "notify never armed" from "device silent".
    /// Runs on `queue` like every delegate callback; mutates nothing but the
    /// diagnostic record.
    func bleDidUpdateNotificationState(_ peripheral: any BLEPeripheral,
                                       for characteristic: any BLECharacteristic, error: Error?) {
        let channel: String
        switch characteristic.uuid {
        case PocketGATT.response: channel = "response"
        case PocketGATT.bulk:     channel = "bulk"
        default:                  return
        }
        if let error {
            notifyStates[channel] = "enable FAILED: \(error.localizedDescription)"
        } else {
            notifyStates[channel] = characteristic.isNotifying ? "enabled" : "reported off"
        }
    }

    func bleDidUpdateValue(_ peripheral: any BLEPeripheral, for characteristic: any BLECharacteristic,
                           error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case PocketGATT.response: responseContinuation.yield(value)
        case PocketGATT.bulk:     bulkContinuation.yield(value)
        default:                  break
        }
    }
}

// MARK: - State-restoration policy (pure, unit-tested)

/// The restoration *policy*, factored free of live CoreBluetooth objects so
/// it can be unit-tested on macOS: which restored peripheral to adopt, and
/// what work drives it back to usable. `BLETransport` maps CBPeripherals to
/// snapshots and executes the returned plan; nothing here touches a radio.
enum BLERestoration {
    /// What a restored peripheral needs before the transport can use it.
    enum Plan: Equatable {
        /// Link up, all three channels resolved — usable as soon as any
        /// dropped notify subscription is re-armed. No discovery at all.
        case ready
        /// Link up, command service known, channels unresolved — discover
        /// exactly the three `001120a*` characteristics.
        case discoverCharacteristics
        /// Link up, nothing discovered yet — discover the command service
        /// (explicit UUID), then its characteristics, like a scanned connect.
        case discoverServices
        /// The system's connection attempt is still in flight — re-issue it
        /// and let didConnect drive the normal discovery chain.
        case awaitSystemConnect
    }

    /// Plain-value view of a restored CBPeripheral. The `has*` flags refer to
    /// the `001120a*` command service and its three channels ONLY — the
    /// snapshot never records, and its builder never inspects, any other
    /// service or characteristic.
    struct PeripheralSnapshot: Equatable {
        var name: String?
        var state: CBPeripheralState
        var hasCommandService: Bool
        var hasCommandCharacteristic: Bool
        var hasResponseCharacteristic: Bool
        var hasBulkCharacteristic: Bool
    }

    /// The plan for one restored peripheral, or nil to reject it. Only a
    /// peripheral carrying our name prefix with its link still alive
    /// (connected or connecting) is adoptable: a restored peripheral that is
    /// already disconnected is NOT resurrected — reconnecting in the
    /// background is the app's policy call, not the transport's, and the
    /// single-use lifecycle means a fresh `connect()` handles it anyway. A
    /// nil name is rejected too (we only ever connected to matching names,
    /// but the prefix check is the rule and an unnameable link fails it).
    static func plan(for snapshot: PeripheralSnapshot, namePrefix: String) -> Plan? {
        guard let name = snapshot.name, name.hasPrefix(namePrefix) else { return nil }
        switch snapshot.state {
        case .connected:
            if snapshot.hasCommandService,
               snapshot.hasCommandCharacteristic,
               snapshot.hasResponseCharacteristic,
               snapshot.hasBulkCharacteristic {
                return .ready
            }
            return snapshot.hasCommandService ? .discoverCharacteristics : .discoverServices
        case .connecting:
            return .awaitSystemConnect
        case .disconnected, .disconnecting:
            return nil
        @unknown default:
            return nil
        }
    }

    /// The first adoptable peripheral wins — mirroring the scan path, which
    /// takes the first matching advertiser. Returns its index in the input
    /// plus its plan, or nil when nothing qualifies.
    static func firstAdoptable(in snapshots: [PeripheralSnapshot],
                               namePrefix: String) -> (index: Int, plan: Plan)? {
        for (index, snapshot) in snapshots.enumerated() {
            if let plan = plan(for: snapshot, namePrefix: namePrefix) {
                return (index, plan)
            }
        }
        return nil
    }
}

extension BLERestoration.PeripheralSnapshot {
    /// Reads already-restored attribute arrays only — property access, no
    /// discovery, no radio traffic — and only *searches* them for the three
    /// PocketGATT UUIDs, never enumerating anything else.
    ///
    /// Not platform-gated: it reads seam values, so it compiles and runs
    /// wherever the tests do, even though only iOS ever restores state.
    init(of peripheral: any BLEPeripheral) {
        let service = peripheral.discoveredServices?.first { $0.uuid == PocketGATT.service }
        let characteristics = service?.discoveredCharacteristics ?? []
        self.init(name: peripheral.name,
                  state: peripheral.state,
                  hasCommandService: service != nil,
                  hasCommandCharacteristic: characteristics.contains { $0.uuid == PocketGATT.command },
                  hasResponseCharacteristic: characteristics.contains { $0.uuid == PocketGATT.response },
                  hasBulkCharacteristic: characteristics.contains { $0.uuid == PocketGATT.bulk })
    }
}
