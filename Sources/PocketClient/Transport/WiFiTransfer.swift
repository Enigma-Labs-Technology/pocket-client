// pocket-client/Sources/PocketClient/Transport/WiFiTransfer.swift
import Foundation
import Network
#if os(iOS)
import NetworkExtension
#endif

/// Joining the recorder's access point. iOS can do this programmatically;
/// macOS asks the operator to join manually (the CLI prints instructions).
public protocol HotspotJoining: Sendable {
    func join(ssid: String, passphrase: String) async throws
    func leave() async
}

/// Joins programmatically on iOS. Requires the Hotspot Configuration
/// entitlement in the consuming app (Plan 3), not in this package.
///
/// A class, not a struct: `leave()` must remove the configuration for the
/// SSID that `join` actually applied, so the joined SSID is recorded under a
/// lock (join and leave can run on different tasks).
///
/// Fast in practice — seconds — which is the only reason the phone path never hit
/// the failure the macOS one did. It is not fast by construction: `apply` puts up
/// the system *"wants to join Wi-Fi network"* alert and returns when the person
/// answers it, which is the same shape of wait as the manual joiner's, just
/// usually shorter. It needs no protection of its own because
/// `openWiFiSession` starts the session keepalive before calling **any**
/// `HotspotJoining` — this one, the manual one, or a consumer's.
public final class SystemHotspotJoiner: HotspotJoining, @unchecked Sendable {
    private let lock = NSLock()
    private var joinedSSID: String?

    public init() {}

    // Synchronous accessors: NSLock's lock()/unlock() are `noasync` on the
    // iOS SDK, so async methods must reach the lock through sync helpers.
    private func recordJoined(_ ssid: String) {
        lock.lock(); joinedSSID = ssid; lock.unlock()
    }

    private func takeJoinedSSID() -> String? {
        lock.lock(); defer { lock.unlock() }
        let ssid = joinedSSID
        joinedSSID = nil
        return ssid
    }

    public func join(ssid: String, passphrase: String) async throws {
        #if os(iOS)
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        configuration.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
            recordJoined(ssid)
        } catch {
            // `alreadyAssociated` means the phone is ALREADY on this AP —
            // that is success, not failure (typical after a half-failed
            // earlier attempt left the association up). Failing it would
            // wrongly abort the retry, silently degrading `.auto` transfers
            // of large files to slow BLE. Record the SSID so `leave()` still
            // removes the configuration afterwards.
            let nsError = error as NSError
            if nsError.domain == NEHotspotConfigurationErrorDomain,
               nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                recordJoined(ssid)
                return
            }
            throw PocketError.wifiJoinFailed(error.localizedDescription)
        }
        #else
        throw PocketError.wifiJoinFailed(
            "macOS cannot join automatically — join SSID \(ssid) with password \(passphrase) manually")
        #endif
    }

    public func leave() async {
        #if os(iOS)
        guard let ssid = takeJoinedSSID() else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }
}

/// The name given to the thread `runOffTheCooperativePool` creates. Read by a
/// test, so the hand-off is proved rather than assumed.
let blockingWorkThreadName = "pocket-client.blocking-work"

/// Runs `work` — which may block its thread for an unbounded time — on a thread
/// of its own, suspending the caller until it returns.
///
/// `ManualHotspotJoiner` is the reason this exists. `readLine()` blocks until the
/// operator presses return, and on 2026-07-28 that was about a minute spent in
/// System Settings. Called straight from an `async` function, that minute is
/// spent holding one of Swift concurrency's cooperative threads — a pool with
/// roughly one thread per core — so the pool can stall, and a keepalive task that
/// is nominally "running concurrently" may not run at all. A ping going out
/// *during* that minute is the whole point (see `startWiFiSessionKeepalive`), so
/// the blocking read has to leave the pool. Nothing here would fail loudly if it
/// did not, which is exactly why it is a named function with a test on it.
///
/// A plain `Thread`, not a `DispatchQueue`: the work blocks for as long as a
/// person takes, and a queue's threads are shared with everything else on it.
///
/// Deliberately **not** cancellable — a blocking read cannot be interrupted, and
/// resuming early would leave the orphaned thread to swallow a later line of
/// stdin. That matches the bare `readLine()` this replaces; nothing regressed.
func runOffTheCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.name = blockingWorkThreadName
        thread.start()
    }
}

/// A joiner for macOS harness runs: prints instructions and waits for the
/// operator to join the AP by hand, then continues.
///
/// This join is a person, and takes as long as a person takes. Everything that
/// has to keep happening meanwhile — the `APP&WPING` keepalive that stops the
/// device's access point idling out from under the transfer — is arranged by
/// `openWiFiSession`, which starts the session keepalive **before** calling any
/// joiner.
public struct ManualHotspotJoiner: HotspotJoining {
    public init() {}
    public func join(ssid: String, passphrase: String) async throws {
        // Step 2's warning is not hypothetical: on 2026-07-28 this path printed
        // the correct post-rotation password and the operator still joined with
        // the one the Mac remembered, because macOS matches a known network by
        // SSID and never asks again. The AP password follows the session key
        // (`key[:8]`), so every rotation invalidates it on every host that has
        // joined before — and the only symptom reaching this process was a TCP
        // connect that timed out.
        print("""

        ACTION REQUIRED — the recorder's WiFi access point is now up.
          1. Open System Settings > Wi-Fi on THIS Mac.
          2. Join the network named:  \(ssid)
             using the password:      \(passphrase)
             If this Mac has joined \(ssid) before AND the device's session key
             has been rotated since, macOS will silently reuse the OLD password
             and report only that it cannot join. Forget the network first —
             System Settings > Wi-Fi > Advanced…, Known Networks — then join
             with the password above.
          3. Once connected, come back here and press return to start the transfer.
        (Bluetooth control stays up; only the file bytes travel over WiFi.)
        waiting for return…
        """)
        // Off the cooperative pool. `readLine()` blocks its thread for as long
        // as the operator takes, and the session keepalive that is now running
        // behind this call needs a thread to run on — see
        // `runOffTheCooperativePool`.
        _ = await runOffTheCooperativePool { readLine() }
    }
    public func leave() async {
        // Runs on failure paths too, so it must not claim success.
        print("wifi step finished — you may rejoin your normal WiFi network now")
    }
}

/// What this package can say about a failed access-point join that the OS will
/// not say.
///
/// Both platforms report a join failure as one opaque line — iOS as the system
/// alert *"Unable to join the network <ssid>"*, macOS (where the join is
/// manual) as nothing at all, just a TCP connect that never completes. Neither
/// distinguishes a wrong password from an access point that is down, and on
/// 2026-07-28 that ambiguity took three hardware probes to resolve.
///
/// The package holds one fact the OS does not: the session key. The AP password
/// is the key's first `passphraseLength` characters
/// (`docs/protocol/ble-protocol.md`, Wi-Fi Quick Transfer step 3), and a rebind
/// propagates into it — VERIFIED on hardware. So comparing the key against the
/// password the device just reported over BLE settles whether the *device* is
/// self-consistent, and that is what decides where to look next: if it is, the
/// credentials offered to the OS were right and the fault is on this host.
///
/// Neither password appears in the guidance text. The reported one is a live
/// credential and the derived one is eight characters of the session key, so
/// the copy states only whether they agree — which keeps the error safe to
/// paste into a bug report.
enum WiFiJoinDiagnosis: Equatable, Sendable, CaseIterable {
    /// The device's reported AP password is exactly what this session's key
    /// implies. The device is self-consistent, so the credentials handed to the
    /// OS were correct and what remains is this host: in practice a saved
    /// network still holding the pre-rotation password.
    case deviceCredentialsCurrent
    /// The device reported a password that is **not** this key's first
    /// `passphraseLength` characters. Informative, never an error: the join used
    /// the device's value, which is authoritative, and the disagreement is a
    /// finding about this firmware's derivation rather than this failure's cause.
    case reportedPassphraseDiffers
    /// No comparison was possible — this session's key is shorter than the
    /// password itself. Real keys are `PocketKey.length`; only a hand-made
    /// short key reaches this.
    case notComparable

    /// The documented derivation: AP password = the session key's first 8 chars.
    static let passphraseLength = 8

    static func of(reportedPassphrase: String, derivedFromKey: String?) -> WiFiJoinDiagnosis {
        guard let derivedFromKey else { return .notComparable }
        return reportedPassphrase == derivedFromKey
            ? .deviceCredentialsCurrent
            : .reportedPassphraseDiffers
    }

    /// Reads after the failure text, in the register the rest of the package
    /// uses: what is known, then what to do about it.
    func guidance(ssid: String) -> String {
        // Shared tail — the repair is the same whatever the comparison said,
        // and it is the only repair there is.
        let hostSideRepair =
            "A password this host saved for \(ssid) before the session key was rotated is the "
            + "likely cause: the OS re-offers it silently and reports only that it cannot join. "
            + "Forget \(ssid) in Wi-Fi settings — macOS: System Settings > Wi-Fi > Advanced…, "
            + "Known Networks; iOS: Settings > Wi-Fi > the network's info button > Forget This "
            + "Network — then run this again. Neither iOS nor macOS exposes an API that can "
            + "remove a network the user saved, so nothing here can do it for you."
        switch self {
        case .deviceCredentialsCurrent:
            return "the AP password the device reported is exactly what this session's key "
                + "implies, so the device's own credentials are current. " + hostSideRepair
        case .reportedPassphraseDiffers:
            return "the AP password the device reported is not this session key's first "
                + "\(Self.passphraseLength) characters, which is the documented derivation — the "
                + "join used the device's value, which is authoritative, so that disagreement is "
                + "a firmware finding to record, not this failure's cause. " + hostSideRepair
        case .notComparable:
            return "this session's key is shorter than the \(Self.passphraseLength)-character AP "
                + "password, so the reported password could not be checked against it. "
                + hostSideRepair
        }
    }
}

/// What this package can say about a TCP connect that never completed, once the
/// device's own report on its access point is taken into account.
///
/// `WiFiJoinDiagnosis` answers exactly one question — were the credentials
/// current? — and on 2026-07-28 that was the wrong question. The Mac was
/// demonstrably ON the access point: `ifconfig en0` held `192.168.200.2`, the
/// client address from the capture, so association and DHCP had both succeeded.
/// The transfer still failed, and by the time it ran both `ping 192.168.200.1`
/// and `nc -vz 192.168.200.1 8475` answered **No route to host** — which, on a
/// directly-connected subnet with a valid interface route and no hijacked
/// gateway, means ARP went unanswered: the device was no longer there at layer 2.
/// The access point had come up, served DHCP, and gone away again while the
/// operator was in System Settings.
///
/// A diagnosis that confidently names the wrong cause is worse than a bare error,
/// so the credential story is told only where the device's report is consistent
/// with it — the AP up, and nothing ever on it. Where the device reported a
/// client, or reported its WiFi off from under us, the subject is the access
/// point's lifetime and the text says so and says nothing about passwords.
enum WiFiConnectDiagnosis: Equatable, Sendable {
    /// The device reported a client on its AP (`MCU&WIFIS&2`, or `1` which
    /// subsumes it) and the socket still never opened. The host was associated,
    /// so the credentials are settled and out of the picture.
    case associatedThenUnreachable
    /// The device reported its WiFi **off** (`MCU&WIFIS&0`) while this client was
    /// still waiting for the association: the access point came down on its own,
    /// and no credential ever got the chance to be wrong.
    case accessPointClosedItself
    /// The device kept reporting its AP up with nothing on it (`MCU&WIFIS&3`, and
    /// never `2`) — the shape a stale saved password makes, where the join is
    /// attempted, silently rejected, and neither OS says why.
    case nothingEverJoined(WiFiJoinDiagnosis)

    /// The repair for both access-point-lifetime cases. It deliberately says
    /// nothing about saved passwords: the device's own report has ruled that
    /// story out here, and repeating it anyway is how a diagnosis starts costing
    /// more than it saves.
    private static func lifetimeRepair(ssid: String) -> String {
        "The access point's lifetime is what to spend less of: the device brings it up on "
        + "APP&WIFIO and does not hold it open indefinitely, so every second between the join "
        + "and this connect is charged against it. On macOS the join is a person — System "
        + "Settings, a network to find, a password to type — which is easily a minute, and a "
        + "minute is enough. Join \(ssid) promptly, stay on it, and run this again. The "
        + "signature that confirms it, from the host side: `ifconfig` still showing a "
        + "\(WiFiEndpoint.clientSubnet) address while `ping \(WiFiEndpoint.deviceHost)` answers "
        + "`No route to host` — that address is a DHCP lease the device has stopped answering "
        + "ARP for."
    }

    /// Reads after the failure text, in the register the rest of the package
    /// uses: what is known, then what to do about it.
    func guidance(ssid: String) -> String {
        switch self {
        case .associatedThenUnreachable:
            return "the device DID report a client on its access point (MCU&WIFIS&2), so this host "
                + "was associated and its credentials were accepted — nothing about the password "
                + "is in question. The socket then never opened, which means the access point "
                + "stopped answering after the association rather than ever refusing it. "
                + Self.lifetimeRepair(ssid: ssid)
        case .accessPointClosedItself:
            return "the device reported its WiFi off (MCU&WIFIS&0) while this client was still "
                + "waiting for the association, so the access point came down before anything "
                + "could connect to it — that is the device's doing, not a credential this host "
                + "holds. " + Self.lifetimeRepair(ssid: ssid)
        case .nothingEverJoined(let join):
            return "the device never reported a client on its AP (no MCU&WIFIS&2), so nothing "
                + "joined \(ssid): " + join.guidance(ssid: ssid)
        }
    }
}

/// Tuning for the post-join readiness wait: the official app polls
/// `APP&WIFIS` about once a second until the device reports the client
/// association (`MCU&WIFIS&2`), then switches to `APP&WPING` keepalives every
/// ~10 s while the phone finishes DHCP and opens TCP (measured from an HCI
/// snoop of one complete app-driven sync).
/// The defaults mirror that cadence; `timeout` bounds both the association
/// wait and the TCP connect.
public struct WiFiReadiness: Sendable {
    public var timeout: Duration
    public var pollInterval: Duration
    public var pingInterval: Duration

    public init(timeout: Duration = .seconds(30),
                pollInterval: Duration = .seconds(1),
                pingInterval: Duration = .seconds(10)) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.pingInterval = pingInterval
    }

    /// Cap on the post-teardown wait for `MCU&WIFIS&0` before a batch reopens the
    /// access point (`PocketSession.awaitWiFiOff`). `timeout` bounds that wait as
    /// well; this caps it, because a caller who set a generous association
    /// timeout did not thereby ask to wait that long for a state transition the
    /// device reports in about 100 ms.
    static let maximumAccessPointOffWait = Duration.seconds(5)
}

// NWEndpoint is written `Network.NWEndpoint` throughout this file: on iOS,
// NetworkExtension exports a legacy class of the same name, and the bare
// name fails to compile as ambiguous.
enum WiFiEndpoint {
    /// The device serves the file at this address once a client joins its AP.
    static let deviceHost = "192.168.200.1"
    static let devicePort: UInt16 = 8475
    /// The subnet the device's DHCP server leases from — `192.168.200.2` in the
    /// capture and on hardware. Named because `WiFiConnectDiagnosis` quotes it:
    /// still holding one of these addresses while the device answers nothing is
    /// the signature of an access point that has gone away.
    static let clientSubnet = "192.168.200.x"

    static var `default`: Network.NWEndpoint {
        .hostPort(host: Network.NWEndpoint.Host(deviceHost),
                  port: Network.NWEndpoint.Port(rawValue: devicePort)!)
    }
}

/// Wall clock of the last activity, shared between whoever produces it and
/// whoever watches for its absence. Two watchers use this type, and they must
/// NOT share one instance:
///
/// - `TCPFetch.receive`'s stall watchdog, which must fire when the device stops
///   sending bytes;
/// - the WiFi session keepalive, which must send `APP&WPING` when the session
///   goes quiet (see `startWiFiSessionKeepalive`).
///
/// One shared instance would let every keepalive ping reset the stall watchdog,
/// and a dead transfer would then never time out. So each transfer keeps its
/// own monitor for the watchdog and *also* touches the session's, which is why
/// `receive` takes `sessionActivity` separately.
final class ActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    func touch() { lock.lock(); last = .now; lock.unlock() }
    func idleSince() -> Duration { lock.lock(); defer { lock.unlock() }; return .now - last }
}

/// Single-shot guard so an NWConnection state handler can resume its checked
/// continuation exactly once (`.ready`, `.failed`, and `.cancelled` can all
/// fire over the handler's lifetime).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// TCP client for the device's :8475 file push. The connection is
/// established FIRST (the device reports it as `MCU&WIFIS&1`) and only then
/// does the caller run the `APP&U&<id>` + `APP&U&WIFI` selection over BLE —
/// the capture shows the official app in exactly that order.
enum TCPFetch {
    /// Opens the connection and waits for `.ready`, bounded by `timeout` —
    /// without the bound, an unreachable endpoint leaves `NWConnection` in
    /// `.waiting` forever.
    static func connect(to endpoint: Network.NWEndpoint,
                        timeout: Duration = .seconds(30)) async throws -> NWConnection {
        let connection = NWConnection(to: endpoint, using: .tcp)
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = ResumeOnce()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if once.first() { continuation.resume() }
                        case .failed(let error):
                            if once.first() {
                                continuation.resume(throwing:
                                    PocketError.transferFailed("wifi tcp connect failed: \(error.localizedDescription)"))
                            }
                        case .cancelled:
                            if once.first() {
                                continuation.resume(throwing:
                                    PocketError.transferFailed("wifi tcp connect cancelled"))
                            }
                        default:
                            break   // .setup / .preparing / .waiting — keep waiting
                        }
                    }
                    connection.start(queue: .global())
                }
            }
            group.addTask {
                // Doubles as the caller-cancellation path: the sleep throws
                // CancellationError when the group is cancelled.
                try await Task.sleep(for: timeout)
                throw PocketError.transferFailed("wifi tcp connect timed out after \(timeout)")
            }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
            } catch {
                // The state handler's continuation may still be pending;
                // cancelling the connection fires `.cancelled`, which resumes
                // it so the group can drain instead of deadlocking.
                connection.cancel()
                try Task.checkCancellation()
                throw error
            }
            connection.stateUpdateHandler = nil   // release the continuation capture
            return connection
        }
    }

    /// Cap on retained surplus (see `Received.surplusPreview`) so a
    /// pathological peer that streams garbage past the announced length
    /// cannot balloon memory.
    static let surplusPreviewLimit = 64

    /// What one fetch produced. The payload itself went to the transfer's
    /// `TransferSink` — never more than the announced bytes of it — so this
    /// carries only the bounded record of any surplus the device sent past
    /// that length. Live hardware appends a short trailer (10 bytes
    /// observed) after the file on the TCP stream; the announced size is
    /// authoritative — the BLE download of the same recording is
    /// byte-identical at exactly that length — so the trailer is
    /// diagnostics, not payload.
    struct Received: Sendable {
        /// Total surplus bytes read past `expected`; 0 when none was seen.
        let surplusCount: Int
        /// The first `surplusPreviewLimit` bytes of that surplus.
        let surplusPreview: Data
    }

    /// Reads exactly `expected` bytes from an already-connected socket into
    /// `sink` — surplus past `expected` never reaches it. `idleTimeout`
    /// bounds how long the connection may sit with no new bytes before the
    /// fetch is declared failed and the connection torn down.
    ///
    /// `sessionActivity`, when given, is touched alongside this fetch's own
    /// stall clock so the WiFi session keepalive can see that bytes are still
    /// flowing and stay off the wire. It is deliberately a second monitor and
    /// never the watchdog's own — see `ActivityMonitor`.
    static func receive(on connection: NWConnection,
                        expected: Int,
                        idleTimeout: Duration = .seconds(10),
                        into sink: TransferSink,
                        sessionActivity: ActivityMonitor? = nil,
                        onProgress: (@Sendable (Double) -> Void)?) async throws -> Received {
        let activity = ActivityMonitor()

        return try await withThrowingTaskGroup(of: Received?.self) { group in
            group.addTask {
                var received = 0
                var surplusCount = 0
                var surplusPreview = Data()
                while received < expected {
                    guard let part = try await nextChunk(connection) else { break }   // EOF
                    guard !part.isEmpty else { continue }
                    let needed = expected - received
                    if part.count > needed {
                        // The chunk crosses the announced length: keep exactly
                        // what completes the file, retain the overshoot
                        // (bounded) for diagnostics. No further reads happen —
                        // the loop condition is now false — so a trailer that
                        // arrives in a *later* TCP segment is simply left
                        // unread; only surplus already read is captured.
                        sink.consume(part.prefix(needed))
                        received += needed
                        let surplus = part.dropFirst(needed)
                        surplusCount += surplus.count
                        surplusPreview.append(surplus.prefix(surplusPreviewLimit - surplusPreview.count))
                    } else {
                        sink.consume(part)
                        received += part.count
                    }
                    activity.touch()
                    sessionActivity?.touch()
                    onProgress?(min(1.0, Double(received) / Double(max(expected, 1))))
                }
                return Received(surplusCount: surplusCount, surplusPreview: surplusPreview)
            }
            group.addTask {   // watchdog: resolves nil when the fetch must be aborted
                while true {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return nil }
                    if activity.idleSince() > idleTimeout { return nil }
                }
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next(), let received = first else {
                    // Watchdog fired (stall, dead endpoint, or caller
                    // cancellation). The reader is pinned inside a receive that
                    // will never call back on its own; cancelling the connection
                    // resumes it so the group can drain instead of deadlocking.
                    connection.cancel()
                    try Task.checkCancellation()
                    throw PocketError.transferFailed(
                        "wifi transfer stalled: no data for \(idleTimeout)")
                }
                connection.cancel()
                return received   // the sink may be short on EOF — finalize size-checks
            } catch {
                connection.cancel()
                throw error
            }
        }
    }

    private static func nextChunk(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { part, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: PocketError.transferFailed(error.localizedDescription))
                } else if let part, !part.isEmpty {
                    continuation.resume(returning: part)
                } else if isComplete {
                    continuation.resume(returning: nil)       // server closed the stream
                } else {
                    continuation.resume(returning: Data())    // empty wakeup; read again
                }
            }
        }
    }
}

extension PocketSession {
    /// WiFi Quick Transfer. Control stays on BLE for the whole flow; only the
    /// file bytes travel over TCP.
    ///
    /// The sequence is the one the official app performs, decoded frame by
    /// frame from an HCI snoop of one complete app-driven sync:
    ///
    /// 1. `APP&SHUT` — abort anything in flight (no reply when idle)
    /// 2. `APP&WIFIS` — state query (`MCU&WIFIS&0` on a fresh start)
    /// 3. `APP&WIFI` → `MCU&WIFI&<ssid>&<psk>` — credentials are the
    ///    synchronous reply to this request, never a push
    /// 4. `APP&WIFIO` → `MCU&WIFIO` — starts the AP (`MCU&WIFIS&3` follows)
    /// 5. join the AP, poll `APP&WIFIS` until `2` (phone associated)
    /// 6. open TCP to 192.168.200.1:8475 with `APP&WPING` keepalives while
    ///    the network stack gets ready (`MCU&WIFIS&1` = TCP connected)
    /// 7. `APP&U&<date>&<ts>` selects the recording, then `APP&U&WIFI`
    ///    reroutes that selection to the socket; read exactly `<size>` bytes
    /// 8. `APP&WIFIC` ×2 closes the session (`MCU&OFF` marks completion)
    ///
    /// Claims the same exclusive transfer slot as `downloadOverBLE` and the
    /// live stream: the device has one transfer engine, and a concurrent BLE
    /// bulk transfer would interleave with the WiFi control traffic.
    public func downloadOverWiFi(_ recording: RecordingInfo,
                                 endpointOverride: Network.NWEndpoint? = nil,
                                 joiner: HotspotJoining = SystemHotspotJoiner(),
                                 idleTimeout: Duration = .seconds(10),
                                 readiness: WiFiReadiness = WiFiReadiness(),
                                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        guard let data = try await downloadOverWiFi(recording, into: TransferSink.memory(),
                                                    endpointOverride: endpointOverride,
                                                    joiner: joiner, idleTimeout: idleTimeout,
                                                    readiness: readiness,
                                                    onProgress: onProgress) else {
            throw PocketError.transferFailed("internal: memory sink produced no data")
        }
        return data
    }

    /// Streaming variant: writes the bytes to `destination` as they arrive
    /// instead of accumulating them in memory. Same control flow, same
    /// integrity rules (announced count is authoritative, surplus trailer
    /// bytes never reach the file), same failure behaviour — the two shapes
    /// share one transfer implementation — plus the file guarantee: on ANY
    /// failure (including cancellation) nothing appears at `destination`,
    /// and a pre-existing file there is replaced only by a validated
    /// download.
    ///
    /// There is no resume: `APP&U&<date>&<ts>` takes no byte offset (no
    /// protocol command does), so a failed transfer restarts from byte zero.
    public func downloadOverWiFi(_ recording: RecordingInfo,
                                 to destination: URL,
                                 endpointOverride: Network.NWEndpoint? = nil,
                                 joiner: HotspotJoining = SystemHotspotJoiner(),
                                 idleTimeout: Duration = .seconds(10),
                                 readiness: WiFiReadiness = WiFiReadiness(),
                                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await downloadOverWiFi(recording, into: TransferSink.file(destination: destination),
                                       endpointOverride: endpointOverride,
                                       joiner: joiner, idleTimeout: idleTimeout,
                                       readiness: readiness, onProgress: onProgress)
    }

    /// The one WiFi transfer implementation both public shapes call — where
    /// the payload lands is the sink's business, never this function's, so
    /// the two shapes cannot drift. On any failure the sink is aborted: the
    /// partial payload must not survive looking like a recording.
    private func downloadOverWiFi(_ recording: RecordingInfo,
                                  into sink: TransferSink,
                                  endpointOverride: Network.NWEndpoint?,
                                  joiner: HotspotJoining,
                                  idleTimeout: Duration,
                                  readiness: WiFiReadiness,
                                  onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        do {
            return try await runWiFiTransfer(recording, sink: sink,
                                             endpointOverride: endpointOverride,
                                             joiner: joiner, idleTimeout: idleTimeout,
                                             readiness: readiness, onProgress: onProgress)
        } catch {
            sink.abort()
            throw error
        }
    }

    private func runWiFiTransfer(_ recording: RecordingInfo,
                                 sink: TransferSink,
                                 endpointOverride: Network.NWEndpoint?,
                                 joiner: HotspotJoining,
                                 idleTimeout: Duration,
                                 readiness: WiFiReadiness,
                                 onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        try beginTransfer()
        defer { endTransfer() }   // covers every exit path below

        // Steps 1–5. `openWiFiSession` cleans up after its own failures (it is
        // the only code that knows how far the sequence got), so nothing here
        // needs a catch around it.
        let session = try await openWiFiSession(joiner: joiner, readiness: readiness)
        // From here every exit must close the AP and leave the network so the
        // operator's own comes back. `leave()` is async, so a defer cannot
        // await it, and a fire-and-forget Task in a defer would race callers
        // that observe the joiner as soon as this function returns — hence
        // the explicit do/catch instead.
        do {
            // 6. TCP first — the selection that follows is served into this
            // socket, and the device reports it as MCU&WIFIS&1.
            let connection: NWConnection
            do {
                connection = try await connectKeepingLinkAlive(
                    to: endpointOverride ?? WiFiEndpoint.default, readiness: readiness,
                    sessionActivity: session.activity)
            } catch {
                throw diagnosed(connectFailure: error, ssid: session.ssid,
                                passphrase: session.passphrase,
                                clientAssociationObserved: session.clientAssociationObserved,
                                lastReportedState: session.lastReportedState)
            }
            do {
                // 7. Select, reroute, read exactly the announced bytes, verify.
                let data = try await transferOverTCP(recording, connection: connection,
                                                     sink: sink,
                                                     sessionActivity: session.activity,
                                                     idleTimeout: idleTimeout,
                                                     onProgress: onProgress)
                // 8. Close the session.
                await closeWiFiSession(session, joiner: joiner, aborting: false)
                return data
            } catch {
                connection.cancel()   // idempotent; receive() may already have
                throw error
            }
        } catch {
            await closeWiFiSession(session, joiner: joiner, aborting: true)
            throw error
        }
    }

    // MARK: - The access-point session

    /// One live access-point session: what the device told us about it, the
    /// idle clock its keepalive reads, and the keepalive itself.
    ///
    /// Held for exactly one transfer by `runWiFiTransfer` and for a whole batch
    /// by `downloadOverWiFi(_ recordings:…)`. That is the only difference
    /// between the two — the sequence either side of it is identical.
    private struct WiFiSessionHandle {
        let ssid: String
        let passphrase: String
        /// The device reported an associated client (`MCU&WIFIS&2`, or `1`
        /// which subsumes it) during setup. Feeds the connect-failure
        /// diagnosis: the device is the only witness to whether anything ever
        /// joined the AP it was broadcasting.
        let clientAssociationObserved: Bool
        /// The last `MCU&WIFIS&<n>` the association wait actually saw, or `nil`
        /// when the device answered none. Distinguishes an access point that came
        /// down (`0`) from one that stayed up with nobody on it (`3`) — two
        /// failures with one symptom and opposite causes, which is the whole
        /// reason `WiFiConnectDiagnosis` needs it.
        let lastReportedState: WiFiState?
        let activity: ActivityMonitor
        let keepalive: Task<Void, Never>
    }

    /// What the association wait saw. `observed` is the readiness signal the call
    /// site is deliberately lenient about; `lastReportedState` is evidence kept
    /// for the failure message, never for control flow.
    private struct WiFiAssociationWait {
        let observed: Bool
        let lastReportedState: WiFiState?
    }

    /// Steps 1–5 of the capture-verified sequence: abort anything in flight,
    /// read the WiFi state, read the credentials, start the AP, join it, and
    /// wait (leniently) for the device to report the association. Returns a
    /// live session with its keepalive running.
    ///
    /// Cleans up after its own failures, and the cleanup differs by how far it
    /// got — which is why it lives here rather than in the callers:
    /// before `APP&WIFIO` there is no AP to close; after it there is, but
    /// nothing has joined yet, so there is nothing to leave; after the join
    /// both apply.
    private func openWiFiSession(joiner: HotspotJoining,
                                 readiness: WiFiReadiness) async throws -> WiFiSessionHandle {
        // 1–2. Abort any in-flight transfer and read the WiFi state. SHUT is
        // fire-and-forget: an idle device sends no MCU&SHUT (live-probe
        // verified), so blocking on a reply would hang the happy path.
        try await send(.wifiShutdown)
        _ = try await request(.wifiStatus, timeout: .seconds(5)) {
            if case .wifiState = $0 { true } else { false }
        }

        // 3. Credentials are the synchronous reply to APP&WIFI. This is NOT
        // the forbidden provisioning command APP&WIFI&CH&… — it carries no
        // arguments and only reads the AP's SSID/PSK.
        let credentials = try await request(.wifiCredentials, timeout: .seconds(5)) {
            if case .wifiCredentials = $0 { true } else { false }
        }
        guard case .wifiCredentials(let ssid, let passphrase) = credentials else {
            throw PocketError.unexpectedResponse("expected MCU&WIFI&<ssid>&<psk>")
        }

        // 4. APP&WIFIO is what actually starts the AP (querying credentials
        // does not). From here every failure exit sends a best-effort
        // APP&WIFIC: a failed WiFi attempt is exactly when the BLE fallback
        // runs, and a still-broadcasting AP competes with BLE for the same
        // 2.4 GHz radio.
        do {
            _ = try await request(.wifiAccessPointOn, timeout: .seconds(5)) {
                $0 == .wifiAccessPointOn
            }
        } catch {
            try? await send(.wifiClose)   // the AP may have started despite a lost ack
            throw error
        }

        // The session keepalive starts HERE — before the join, not after it.
        //
        // On macOS the join IS a person: `ManualHotspotJoiner` prints instructions
        // and blocks on `readLine()` while the operator opens System Settings,
        // forgets a stale network, finds the SSID and types a password. On
        // 2026-07-28 that pause was long enough for the device's access point to
        // come up, serve DHCP, and go away again before a single byte was asked
        // for — after which the Mac still held a `192.168.200.x` lease and
        // everything it aimed at the device answered `No route to host`, because
        // nothing was answering ARP any more. Every downstream symptom, up to and
        // including `wifi tcp connect timed out after 30.0 seconds`, follows from
        // that one pause.
        //
        // `awaitWiFiClientJoined` pings for exactly this reason — its own comment
        // says a "possibly human-paced association" must not idle out the BLE link
        // — and it starts one step too late to see the human. Starting the
        // session-long keepalive before the join covers that stretch and every
        // later one with a single mechanism, and covers every `HotspotJoining`
        // rather than just the blocking one: `SystemHotspotJoiner` waits on an iOS
        // permission alert, which is the same shape of pause and merely faster
        // today.
        let activity = ActivityMonitor()
        let keepalive = startWiFiSessionKeepalive(activity, readiness: readiness)
        // Every failure exit below must stop it; only the returned handle takes
        // ownership. A defer rather than a line per catch, so a path added later
        // cannot leak a pinger onto a closed access point.
        var handedOver = false
        defer { if !handedOver { keepalive.cancel() } }

        do {
            try await joiner.join(ssid: ssid, passphrase: passphrase)
        } catch {
            try? await send(.wifiClose)
            throw diagnosed(joinFailure: error, ssid: ssid, passphrase: passphrase)
        }

        do {
            // 5. Wait (leniently) for MCU&WIFIS&2: the capture shows the TCP
            // connect only after the device reports the association, and
            // connecting earlier just burns the timeout against a network
            // that is not routing yet.
            let wait = try await awaitWiFiClientJoined(readiness, sessionActivity: activity)
            if !wait.observed {
                // Lenient by design: if this firmware's state machine differs
                // from the capture, do not block a transfer that would work —
                // but make sure the fact is visible to the CLI/checkpoint.
                emitEvent(.wifiReadinessNotObserved)
            }
            handedOver = true
            return WiFiSessionHandle(
                ssid: ssid, passphrase: passphrase,
                clientAssociationObserved: wait.observed,
                lastReportedState: wait.lastReportedState,
                activity: activity,
                keepalive: keepalive)
        } catch {
            // Past the join, so the full teardown applies.
            try? await send(.wifiShutdown)
            try? await send(.wifiClose)
            await joiner.leave()
            throw error
        }
    }

    /// Closes the access point and leaves the network. Best effort throughout:
    /// this runs on paths where the link may already be gone, and an AP left
    /// broadcasting into the BLE fallback is worse than a lost error.
    ///
    /// `aborting` picks between the two shapes the capture and the field
    /// established:
    ///
    /// - a completed transfer sends `APP&WIFIC` **twice**, mirroring the vendor
    ///   app's traffic (the device tolerates the redundant close);
    /// - a failure first sends `APP&SHUT` to abort an upload that may already be
    ///   selected (no reply arrives when nothing is in flight) and then closes
    ///   once.
    private func closeWiFiSession(_ session: WiFiSessionHandle,
                                  joiner: HotspotJoining,
                                  aborting: Bool) async {
        session.keepalive.cancel()
        if aborting {
            try? await send(.wifiShutdown)
            try? await send(.wifiClose)
        } else {
            try? await send(.wifiClose)
            try? await send(.wifiClose)
        }
        await joiner.leave()
    }

    /// Keeps the device's WiFi session alive for as long as it is open.
    ///
    /// `APP&WPING` used to cover exactly one stretch — the TCP connect — because
    /// a session lasted exactly one transfer. A batch adds stretches the connect
    /// pinger never saw: between one recording's `MCU&OFF` and the next one's
    /// selection, and across the integrity check and file publish. This task
    /// spans the whole session instead.
    ///
    /// **Including the join.** It is started before `joiner.join` rather than
    /// after it (see `openWiFiSession`), because the longest silence in the whole
    /// sequence is the one where a person joins the network by hand — and that is
    /// the silence that cost every macOS Wi-Fi transfer up to 0.1.3.
    ///
    /// It reads `ActivityMonitor.idleSince()` — the clock the TCP reader already
    /// touches on every chunk — rather than timing itself, so a ping goes out
    /// only after `pingInterval` of genuine silence. That is the point: nothing
    /// pings on top of a transfer that is streaming bytes, which is what the
    /// single-transfer code was careful never to do.
    ///
    /// Sends via `sendWiFiSessionKeepalive` (fire-and-forget) and never
    /// `request`, so it cannot hold the session's single request slot — see that
    /// method for why a `.busy` here would be actively misleading.
    private func startWiFiSessionKeepalive(_ activity: ActivityMonitor,
                                           readiness: WiFiReadiness) -> Task<Void, Never> {
        Task { [weak self] in
            // Check often enough to notice an idle gap promptly, never hot: a
            // `pingInterval` of zero (tests use it to force pings) must not
            // become a spin loop.
            let tick = max(min(readiness.pingInterval, .seconds(1)), .milliseconds(50))
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                if Task.isCancelled { return }
                guard let self else { return }
                guard activity.idleSince() >= readiness.pingInterval else { continue }
                await self.sendWiFiSessionKeepalive()
                activity.touch()
            }
        }
    }

    /// The comparison behind every message below: the password the device just
    /// reported over BLE against the one this session's key implies.
    private func wifiJoinDiagnosis(reportedPassphrase: String) -> WiFiJoinDiagnosis {
        .of(reportedPassphrase: reportedPassphrase, derivedFromKey: apPassphraseImpliedByKey)
    }

    /// Appends this package's own diagnosis to a join failure, so the thrown
    /// error names the likeliest cause instead of only the symptom. A stale
    /// saved credential is a known, common cause — it happens to *everyone* who
    /// rotates a key — and is invisible from the OS's API surface.
    ///
    /// Only `PocketError.wifiJoinFailed` is rewritten: both built-in joiners
    /// throw it and it is the documented shape, while a custom joiner's own
    /// error type — and `CancellationError` — propagates untouched rather than
    /// being flattened into a string. The joiner's original text still leads;
    /// the diagnosis follows it.
    private func diagnosed(joinFailure error: Error, ssid: String, passphrase: String) -> Error {
        guard case PocketError.wifiJoinFailed(let detail) = error else { return error }
        return PocketError.wifiJoinFailed(
            "\(detail) — \(wifiJoinDiagnosis(reportedPassphrase: passphrase).guidance(ssid: ssid))")
    }

    /// A TCP connect that never completes is the shape this failure takes on the
    /// macOS path, where the join cannot fail: the operator pressed return and the
    /// only symptom reaching the process is a socket that never opens
    /// (`wifi tcp connect timed out after 30.0 seconds`, on 2026-07-28).
    ///
    /// The device is the witness, and which of two opposite stories it tells
    /// decides the guidance — see `WiFiConnectDiagnosis`. It reported a client, so
    /// the host was on the AP and the credentials are irrelevant; it reported its
    /// WiFi off, so the AP came down by itself; or it reported the AP up with
    /// nobody on it, which is the stale-credential shape and the only case that
    /// gets the credential text. The earlier version added credential guidance to
    /// the first case not at all and to the second one wrongly, and a diagnosis
    /// that names the wrong cause is worse than a bare error.
    ///
    /// Message only. The error case, the control flow, and the AP teardown are
    /// unchanged, and `CancellationError` passes through untouched.
    private func diagnosed(connectFailure error: Error, ssid: String, passphrase: String,
                           clientAssociationObserved: Bool,
                           lastReportedState: WiFiState?) -> Error {
        guard case PocketError.transferFailed(let detail) = error else { return error }
        let diagnosis: WiFiConnectDiagnosis
        if clientAssociationObserved {
            diagnosis = .associatedThenUnreachable
        } else if lastReportedState == .off {
            diagnosis = .accessPointClosedItself
        } else {
            diagnosis = .nothingEverJoined(wifiJoinDiagnosis(reportedPassphrase: passphrase))
        }
        return PocketError.transferFailed("\(detail) — \(diagnosis.guidance(ssid: ssid))")
    }

    /// Polls `APP&WIFIS` until the device reports `.clientJoined` (2) — or
    /// `.tcpConnected` (1), which subsumes it — sending `APP&WPING`
    /// keepalives between polls so a slow (possibly human-paced) association
    /// cannot idle out the BLE link. Reports `observed: false` when
    /// `readiness.timeout` elapses without either state being observed —
    /// deliberately not an error (see the call site) — and carries the last state
    /// the device did report, which is what tells an access point that came down
    /// from one nobody joined. Throws only for caller cancellation and a dead
    /// session.
    ///
    /// `sessionActivity` is touched around every poll and every ping, exactly as
    /// `connectKeepingLinkAlive` does it: the session keepalive fires only after
    /// `pingInterval` of genuine silence, so this stretch's own traffic keeps it
    /// off the wire instead of doubling it.
    private func awaitWiFiClientJoined(_ readiness: WiFiReadiness,
                                       sessionActivity: ActivityMonitor?) async throws
        -> WiFiAssociationWait {
        let clock = ContinuousClock()
        let deadline = clock.now + readiness.timeout
        var lastPing = clock.now
        var lastReportedState: WiFiState?
        while clock.now < deadline {
            try Task.checkCancellation()
            guard isAuthenticated else { throw PocketError.notAuthenticated }
            sessionActivity?.touch()
            let response = try? await request(.wifiStatus, timeout: .seconds(2)) {
                if case .wifiState = $0 { true } else { false }
            }
            sessionActivity?.touch()
            if case .wifiState(let state)? = response {
                lastReportedState = state
                if state == .clientJoined || state == .tcpConnected {
                    return WiFiAssociationWait(observed: true, lastReportedState: state)
                }
            }
            if clock.now - lastPing >= readiness.pingInterval {
                _ = try? await request(.wifiKeepalive, timeout: .seconds(2)) { $0 == .pong }
                sessionActivity?.touch()
                lastPing = clock.now
            }
            try? await Task.sleep(for: readiness.pollInterval)
        }
        return WiFiAssociationWait(observed: false, lastReportedState: lastReportedState)
    }

    /// After a teardown, waits for the device to report its WiFi actually **off**
    /// before the next `APP&WIFIO` starts it again.
    ///
    /// A batch restart is the only place in this protocol that closes an access
    /// point and immediately reopens one, so it is the only place that can ask a
    /// device to start an AP that has not finished coming down. Whether that
    /// matters is unobserved — but the fallback is precisely what has to be
    /// trustworthy when this meets hardware: a restart that half-works would be
    /// read as the device refusing session reuse, which is the one thing the run
    /// is trying to measure.
    ///
    /// Evidence, not a guessed sleep. `APP&WIFIS` is already this sequence's state
    /// oracle, and the device is quick with it — a poll 114 ms after `APP&WIFIO`
    /// already reads `3` (`docs/protocol/ble-protocol.md`, Wi-Fi Quick Transfer
    /// step 4) — so waiting for the state it reports costs almost nothing when all
    /// is well. Bounded by `readiness.timeout`, capped at
    /// `WiFiReadiness.maximumAccessPointOffWait`.
    ///
    /// On expiry it **throws**, naming the last state seen, rather than pressing
    /// on into a state it cannot describe. The caller reports that as the reason
    /// the batch stopped, and no second `APP&WIFIO` is sent.
    private func awaitWiFiOff(_ readiness: WiFiReadiness) async throws {
        let bound = min(readiness.timeout, WiFiReadiness.maximumAccessPointOffWait)
        let clock = ContinuousClock()
        let deadline = clock.now + bound
        var lastSeen = "no answer to APP&WIFIS"
        repeat {
            try Task.checkCancellation()
            guard isAuthenticated else { throw PocketError.notAuthenticated }
            // The per-poll timeout cannot outlive the overall bound, or a single
            // silent poll would overshoot it.
            let response = try? await request(.wifiStatus, timeout: min(.seconds(2), bound)) {
                if case .wifiState = $0 { true } else { false }
            }
            if case .wifiState(let state)? = response {
                if state == .off { return }   // the AP is down; safe to start it again
                lastSeen = "MCU&WIFIS&\(state.rawValue)"
            }
            try? await Task.sleep(for: readiness.pollInterval)
        } while clock.now < deadline
        try Task.checkCancellation()   // a cancelled caller gets CancellationError
        throw PocketError.transferFailed(
            "the device did not report its WiFi off (MCU&WIFIS&0) within \(bound) of APP&WIFIC "
            + "— last state: \(lastSeen). Refusing to send APP&WIFIO on top of an access point "
            + "that may still be coming down, because a restart that half-works would look like "
            + "the device refusing to serve a second recording, which is exactly what this run "
            + "is trying to establish.")
    }

    /// Opens the TCP connection while keeping the BLE link alive with
    /// `APP&WPING` keepalives — the capture's cadence for the stretch where
    /// the phone-side stack does DHCP and connects (~24 s there).
    ///
    /// Internal (not private) and parameterised over `connect` so a hermetic
    /// test can hold the connect open until a WPING request is armed and
    /// prove the winner's cancellation cannot wedge this group; the default
    /// is the real TCP connect, so production behaviour is unchanged.
    func connectKeepingLinkAlive(
        to endpoint: Network.NWEndpoint,
        readiness: WiFiReadiness,
        sessionActivity: ActivityMonitor? = nil,
        connect: @escaping @Sendable (Network.NWEndpoint, Duration) async throws -> NWConnection
            = { try await TCPFetch.connect(to: $0, timeout: $1) }
    ) async throws -> NWConnection {
        try await withThrowingTaskGroup(of: NWConnection?.self) { group in
            group.addTask {
                try await connect(endpoint, readiness.timeout)
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: readiness.pingInterval)
                    if Task.isCancelled { break }
                    // Touched around the ping so the session keepalive — which
                    // fires only on `pingInterval` of silence — stays off the
                    // wire while this one is already covering the gap.
                    sessionActivity?.touch()
                    _ = try? await self.request(.wifiKeepalive, timeout: .seconds(2)) { $0 == .pong }
                    sessionActivity?.touch()
                }
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let connection = first else {
                try Task.checkCancellation()
                throw PocketError.transferFailed("wifi tcp connect never completed")
            }
            sessionActivity?.touch()
            return connection
        }
    }

    /// The connected stretch: select the recording, reroute it to the
    /// socket, read exactly the announced bytes into the sink, verify. The
    /// session close (`APP&WIFIC` ×2) belongs to `closeWiFiSession`, because a
    /// batch keeps the session open across several of these.
    private func transferOverTCP(_ recording: RecordingInfo,
                                 connection: NWConnection,
                                 sink: TransferSink,
                                 sessionActivity: ActivityMonitor?,
                                 idleTimeout: Duration,
                                 onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        await confirmWiFiTCPConnected(sessionActivity)
        let announced = try await selectRecordingOverWiFi(recording, sessionActivity: sessionActivity)
        // Same guard as the BLE path: a 0-byte recording must fail fast and
        // truthfully — before the device is told to serve it over the socket.
        guard announced > 0 else { throw PocketError.emptyRecording }
        try await rerouteSelectionToWiFi(sessionActivity)
        try await fetchOverTCP(connection: connection, expected: announced, sink: sink,
                               sessionActivity: sessionActivity, idleTimeout: idleTimeout,
                               onProgress: onProgress)
        // A cancelled caller gets CancellationError, not a bogus size error.
        try Task.checkCancellation()
        // Integrity rules are identical to BLE by construction — exact byte
        // count + FF F3 sync live in the shared sink, which also publishes a
        // file destination only now, after both checks pass.
        let data = try sink.finalize(announced: announced)
        sessionActivity?.touch()
        onProgress?(1.0)
        return data
    }

    /// One confirmation poll, as the official app does once its TCP connect
    /// succeeds (the device answers `MCU&WIFIS&1`). Lenient: the open socket is
    /// the ground truth, so the answer is observational.
    private func confirmWiFiTCPConnected(_ sessionActivity: ActivityMonitor?) async {
        _ = try? await request(.wifiStatus, timeout: .seconds(2)) {
            if case .wifiState = $0 { true } else { false }
        }
        sessionActivity?.touch()
    }

    /// 7a. Select the recording — the same frame as a BLE download, and the
    /// device may briefly restart BLE bulk for it (the capture shows ~15 KB of
    /// leakage). No bulk sink is installed on this path, so those notifications
    /// are discarded, never mixed into the file. Returns the announced length,
    /// unvalidated: the caller decides what a 0 means (it is a fact about the
    /// recording on a fresh session and ambiguous on a reused one).
    private func selectRecordingOverWiFi(_ recording: RecordingInfo,
                                         sessionActivity: ActivityMonitor?) async throws -> Int {
        sessionActivity?.touch()
        let sizeResponse = try await request(.download(recording.id), timeout: .seconds(30)) {
            if case .transferSize = $0 { true } else { false }
        }
        sessionActivity?.touch()
        guard case .transferSize(let announced) = sizeResponse else {
            throw PocketError.unexpectedResponse("expected MCU&U&<size>")
        }
        return announced
    }

    /// 7b. `APP&U&WIFI` is a modifier on the preceding selection: it reroutes
    /// the in-progress upload to the TCP socket. The `MCU&U&WIFI` ack can lag
    /// (~1.2 s in the capture); the repeated `MCU&U&<size>` that follows it
    /// arrives unarmed and surfaces as an observational event.
    private func rerouteSelectionToWiFi(_ sessionActivity: ActivityMonitor?) async throws {
        _ = try await request(.wifiDownload, timeout: .seconds(30)) { $0 == .wifiUploadAck }
        sessionActivity?.touch()
    }

    /// Reads exactly `expected` bytes into the sink and surfaces any surplus.
    private func fetchOverTCP(connection: NWConnection,
                              expected: Int,
                              sink: TransferSink,
                              sessionActivity: ActivityMonitor?,
                              idleTimeout: Duration,
                              onProgress: (@Sendable (Double) -> Void)?) async throws {
        let received = try await TCPFetch.receive(on: connection,
                                                 expected: expected,
                                                 idleTimeout: idleTimeout,
                                                 into: sink,
                                                 sessionActivity: sessionActivity,
                                                 onProgress: onProgress)
        // Live hardware sends a short trailer past the announced length
        // (10 bytes observed; content not yet identified). The announced size
        // is authoritative — the BLE download of the same recording is
        // byte-identical at exactly that length — so surplus is surfaced as a
        // diagnostic, never treated as payload or as an error.
        if received.surplusCount > 0 {
            emitEvent(.wifiTrailerReceived(byteCount: received.surplusCount,
                                           preview: received.surplusPreview))
        }
    }
}

// MARK: - One access-point session for several recordings

/// Where a batched WiFi run puts each recording's payload.
public enum WiFiBatchDestination: Sendable {
    /// Each recording's bytes come back in its outcome's `data`. Convenient at
    /// the device's observed sizes; a large backlog should prefer `.files`,
    /// which never holds a whole recording in memory.
    case memory
    /// Each recording streams to the URL this returns, with the same file
    /// guarantee as the single-recording streaming API: on ANY failure nothing
    /// appears at the destination, and a pre-existing file there is replaced
    /// only by a fully validated download. Outcomes carry no `data`.
    case files(@Sendable (RecordingInfo) -> URL)
}

/// How one recording in a batch got its access point.
///
/// This is the batch's whole experiment in one value. Whether the device will
/// serve a second `APP&U&<date>&<ts>` while its AP is still up has never been
/// observed — the packet capture this protocol was decoded from covered a
/// single-file sync — so a run attempts reuse and records what the device
/// actually did.
public enum WiFiSessionUse: Sendable, Equatable {
    /// Opened the batch's first access-point session: the full
    /// `APP&SHUT → APP&WIFIS → APP&WIFI → APP&WIFIO` handshake, the join, and
    /// the association wait — about 6.5 s for the association alone.
    case openedSession
    /// Served by the session an earlier recording opened: no second join, no
    /// second handshake. This is the saving the batch exists for, and observing
    /// it on hardware is what would promote the capability out of `unverified`.
    case reusedSession
    /// Reuse was attempted and the device would not serve this recording on the
    /// live session. The session was torn down properly and a fresh one opened
    /// for this recording, so nothing was lost; `refusal` records what the
    /// device did. After this the run stops attempting reuse — a doomed attempt
    /// plus a teardown per recording would be *worse* than the
    /// one-session-per-recording behaviour it falls back to.
    case restartedSession(refusal: String)
    /// Reuse had already been ruled out by an earlier `restartedSession`, so
    /// this recording opened its own session without re-attempting it. Exactly
    /// the behaviour of calling `downloadOverWiFi(_:)` once per recording.
    case ownSession
}

/// What one recording's transfer produced inside a batch.
public struct WiFiRecordingOutcome: Sendable, Equatable {
    public let recording: RecordingInfo
    public let sessionUse: WiFiSessionUse
    /// Payload bytes delivered — the device's announced length, which the
    /// integrity check proved was received exactly.
    public let byteCount: Int
    /// The payload, for a `.memory` destination; `nil` for `.files`, where the
    /// bytes are already at their validated path.
    public let data: Data?

    public init(recording: RecordingInfo, sessionUse: WiFiSessionUse,
                byteCount: Int, data: Data?) {
        self.recording = recording
        self.sessionUse = sessionUse
        self.byteCount = byteCount
        self.data = data
    }
}

/// The recording a batch stopped on, and what it left untried.
public struct WiFiBatchStop: Sendable, Equatable {
    public let recording: RecordingInfo
    /// One line naming the failure.
    public let reason: String
    /// The failure itself when it was one of this package's, so a caller can
    /// branch on it — e.g. drop a `.emptyRecording` and re-batch the rest.
    /// `nil` for anything else (a custom joiner's own error type, say).
    public let error: PocketError?
    /// The recordings after `recording`: never attempted, never touched.
    /// Deciding what to do about them — a BLE retry, a later batch, nothing —
    /// is the caller's call, which is why the run stops instead of guessing.
    public let remaining: [RecordingInfo]

    public init(recording: RecordingInfo, reason: String,
                error: PocketError?, remaining: [RecordingInfo]) {
        self.recording = recording
        self.reason = reason
        self.error = error
        self.remaining = remaining
    }
}

/// The result of one batched WiFi run.
public struct WiFiBatchResult: Sendable, Equatable {
    /// One entry per recording delivered, in the order requested. A run that
    /// stops partway still reports these — a failure on recording 4 of 10 must
    /// not lose 1–3.
    public let delivered: [WiFiRecordingOutcome]
    /// `nil` ⇔ every requested recording was delivered.
    public let stopped: WiFiBatchStop?

    public init(delivered: [WiFiRecordingOutcome], stopped: WiFiBatchStop?) {
        self.delivered = delivered
        self.stopped = stopped
    }

    public var isComplete: Bool { stopped == nil }

    /// True when at least one recording rode a session another recording had
    /// already opened — i.e. the device DID serve a second selection on a live
    /// access point. This is the answer to the open question, read off a real
    /// run rather than assumed.
    public var didReuseSession: Bool {
        delivered.contains { $0.sessionUse == .reusedSession }
    }

    /// Every refusal observed, in order. Non-empty means the device declined to
    /// serve a recording on a live session and the run fell back to one session
    /// per recording. Worth recording in the protocol reference either way.
    public var refusals: [String] {
        delivered.compactMap {
            if case .restartedSession(let refusal) = $0.sessionUse { refusal } else { nil }
        }
    }

    /// How many access-point sessions the *delivered* recordings needed. `1`
    /// with several recordings delivered is the win; `delivered.count` is the
    /// fallback. Counted over `delivered` only — a session opened for the
    /// recording the run stopped on is not included, because that recording
    /// produced no outcome.
    public var sessionsOpened: Int {
        delivered.filter { $0.sessionUse != .reusedSession }.count
    }

    /// One line for a log or a harness transcript.
    public var summary: String {
        let head = "\(delivered.count) recording(s) delivered over \(sessionsOpened) "
            + "access-point session(s)"
        let reuse = didReuseSession
            ? " — the device DID serve a second selection on a live session"
            : (refusals.isEmpty
                ? ""
                : " — the device refused a second selection: \(refusals[0])")
        guard let stopped else { return head + reuse }
        return head + reuse + "; stopped on \(stopped.recording.id.timestamp): \(stopped.reason)"
    }
}

/// One line naming a failure, for a batch report a caller may log or print.
/// The string-carrying `PocketError` cases already hold a sentence, so their
/// detail is used verbatim; the rest get prose here rather than an enum dump.
/// Exhaustive on purpose — a new `PocketError` case must be given a sentence.
func wifiFailureText(_ error: Error) -> String {
    guard let pocket = error as? PocketError else { return String(describing: error) }
    switch pocket {
    case .transferFailed(let detail):     return detail
    case .wifiJoinFailed(let detail):     return "could not join the device's WiFi AP: \(detail)"
    case .unexpectedResponse(let detail): return "protocol drift: \(detail)"
    case .busy(let what):                 return what
    case .emptyRecording:
        return "the device announced 0 bytes for this recording (MCU&U&0)"
    case .timeout(let command):
        return "no reply matching what this client expects for \(command.wireFormat)"
    case .unknownCommand(let command):
        return "the device answered MCU&UNKNOWN to \(command.wireFormat)"
    case .sizeMismatch(let expected, let received):
        return "received \(received) of \(expected) announced bytes"
    case .notMP3:
        return "the payload did not start with an MP3 frame header"
    case .notAuthenticated:
        return "the BLE session is no longer authenticated"
    case .disconnected:
        return "the BLE link dropped"
    case .authRejected:
        return "the device rejected the session key"
    case .deviceNotFound(let identifier):
        return "this system does not know peripheral \(identifier)"
    }
}

extension PocketSession {
    /// Transfers several recordings over **one** access-point session: the AP
    /// comes up once, every recording is fetched, and it closes once.
    ///
    /// **Why this exists.** A session is not cheap.
    /// `APP&SHUT → APP&WIFIS → APP&WIFI → APP&WIFIO`, the join, and the
    /// association wait cost about 6.5 s for the association alone, and on iOS
    /// `NEHotspotConfiguration.joinOnce` makes the OS discard the configuration
    /// when the phone disassociates — so a ten-recording sync done one session
    /// at a time asks the person to join the network **ten times** and pays the
    /// handshake ten times. Watched happening on hardware, 2026-07-29, across
    /// ~354 MB in 30–50 MB files.
    ///
    /// **The reuse itself is `unverified`.** Nobody has ever issued a second
    /// `APP&U&<date>&<ts>` while the AP was still up: the capture this protocol
    /// was decoded from covered a single-file sync, so the device may serve a
    /// second selection, refuse it, or do something else. This function
    /// therefore *attempts* reuse and falls back cleanly. The moment the device
    /// will not serve a recording on the live session — and that is always
    /// decided **before** a single payload byte of it has flowed, which is what
    /// makes a restart safe — the session is torn down properly (`APP&SHUT` +
    /// `APP&WIFIC`, then leave the network) and a fresh one is opened for that
    /// recording; reuse is not attempted again in the run. The worst case is
    /// therefore exactly the one-session-per-recording behaviour of
    /// `downloadOverWiFi(_:)`, never a wedged device or a half-open AP.
    /// `WiFiBatchResult.didReuseSession` and `.refusals` say which happened;
    /// `pocket-cli sync-wifi` exists to run the experiment on hardware.
    ///
    /// **Partial progress is kept.** The run stops at the first recording it
    /// cannot deliver and reports what it already delivered — a failure on
    /// recording 4 of 10 must not lose 1–3 — leaving the rest untouched for the
    /// caller to decide about. That is not an error, so it does not throw:
    /// `WiFiBatchResult.stopped` carries the recording, the reason, and what was
    /// left. It throws only for what makes the batch impossible
    /// (`PocketError.busy` when another transfer holds the device's single
    /// transfer engine, `PocketError.notAuthenticated` before the handshake) and
    /// for caller cancellation.
    ///
    /// Every exit path closes the access point, cancellation included: a still-
    /// broadcasting AP competes with BLE for the same 2.4 GHz radio. An empty
    /// `recordings` array is a no-op that never touches the radio.
    ///
    /// Claims the same exclusive transfer slot as `downloadOverBLE`, the live
    /// stream, and the single-recording WiFi path — for the whole batch.
    public func downloadOverWiFi(
        _ recordings: [RecordingInfo],
        into destination: WiFiBatchDestination = .memory,
        endpointOverride: Network.NWEndpoint? = nil,
        joiner: HotspotJoining = SystemHotspotJoiner(),
        idleTimeout: Duration = .seconds(10),
        readiness: WiFiReadiness = WiFiReadiness(),
        onProgress: (@Sendable (RecordingID, Double) -> Void)? = nil
    ) async throws -> WiFiBatchResult {
        guard !recordings.isEmpty else { return WiFiBatchResult(delivered: [], stopped: nil) }
        try beginTransfer()
        defer { endTransfer() }   // covers every exit path below
        return try await runWiFiBatch(recordings, destination: destination,
                                      endpointOverride: endpointOverride, joiner: joiner,
                                      idleTimeout: idleTimeout, readiness: readiness,
                                      onProgress: onProgress)
    }

    /// What one recording's attempt did. `refused` is the only case that is not
    /// terminal: it means the LIVE session would not serve this recording, and
    /// it is only ever produced before a payload byte flowed.
    private enum WiFiAttempt {
        case delivered(byteCount: Int, data: Data?)
        case refused(String)
        case failed(String, PocketError?)
        case cancelled
    }

    private func runWiFiBatch(
        _ recordings: [RecordingInfo],
        destination: WiFiBatchDestination,
        endpointOverride: Network.NWEndpoint?,
        joiner: HotspotJoining,
        idleTimeout: Duration,
        readiness: WiFiReadiness,
        onProgress: (@Sendable (RecordingID, Double) -> Void)?
    ) async throws -> WiFiBatchResult {
        var delivered: [WiFiRecordingOutcome] = []
        var live: WiFiSessionHandle?
        /// Set by the first refusal. From then on every recording opens and
        /// closes its own session and reuse is never attempted again.
        var reuseRuledOut = false

        /// Set by the first actual teardown. Only a run that has already closed an
        /// access point can ask the device to start one that is still coming down,
        /// so only such a run waits for `MCU&WIFIS&0` first — the very first
        /// session opens exactly as the capture-verified single-transfer path does,
        /// with no extra frame.
        var hasClosedASession = false

        /// The single teardown path. Clearing `live` first makes it idempotent,
        /// so no exit can close twice and none can forget.
        func closeLive(aborting: Bool) async {
            guard let session = live else { return }
            live = nil
            hasClosedASession = true
            await closeWiFiSession(session, joiner: joiner, aborting: aborting)
        }

        /// Opens a session, first waiting out any access point this run already
        /// closed. `awaitWiFiOff` throws when the device never reports itself off,
        /// and that throw must reach the caller: pressing on would send
        /// `APP&WIFIO` into a state nothing here can describe.
        func openSession() async throws -> WiFiSessionHandle {
            if hasClosedASession { try await awaitWiFiOff(readiness) }
            return try await openWiFiSession(joiner: joiner, readiness: readiness)
        }

        func stopping(at index: Int, _ reason: String, _ error: PocketError?) -> WiFiBatchResult {
            WiFiBatchResult(
                delivered: delivered,
                stopped: WiFiBatchStop(recording: recordings[index], reason: reason, error: error,
                                       remaining: Array(recordings[(index + 1)...])))
        }

        do {
            for (index, recording) in recordings.enumerated() {
                if Task.isCancelled {
                    await closeLive(aborting: true)
                    throw CancellationError()
                }

                // Acquire a session. `live != nil` implies reuse is still on the
                // table: the loop closes the session after every recording once
                // it has been ruled out.
                let session: WiFiSessionHandle
                var use: WiFiSessionUse
                if let existing = live {
                    session = existing
                    use = .reusedSession
                } else {
                    do {
                        session = try await openSession()
                    } catch is CancellationError {
                        throw CancellationError()   // nothing open: openWiFiSession cleaned up
                    } catch {
                        return stopping(at: index, wifiFailureText(error), error as? PocketError)
                    }
                    live = session
                    use = reuseRuledOut ? .ownSession : .openedSession
                }

                var attempt = await transferOneRecording(
                    recording, on: session, reusingSession: use == .reusedSession,
                    destination: destination, endpointOverride: endpointOverride,
                    idleTimeout: idleTimeout, readiness: readiness, onProgress: onProgress)

                // The unknown answering: the live session would not serve this
                // recording. Tear it down properly and give the recording a
                // fresh session — the pre-existing behaviour, and from here on
                // the only behaviour.
                if case .refused(let refusal) = attempt {
                    reuseRuledOut = true
                    await closeLive(aborting: true)
                    use = .restartedSession(refusal: refusal)
                    do {
                        let fresh = try await openSession()
                        live = fresh
                        attempt = await transferOneRecording(
                            recording, on: fresh, reusingSession: false,
                            destination: destination, endpointOverride: endpointOverride,
                            idleTimeout: idleTimeout, readiness: readiness, onProgress: onProgress)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return stopping(at: index, wifiFailureText(error), error as? PocketError)
                    }
                }

                switch attempt {
                case .delivered(let byteCount, let data):
                    delivered.append(WiFiRecordingOutcome(recording: recording, sessionUse: use,
                                                          byteCount: byteCount, data: data))
                case .failed(let reason, let error):
                    await closeLive(aborting: true)
                    return stopping(at: index, reason, error)
                case .cancelled:
                    await closeLive(aborting: true)
                    throw CancellationError()
                case .refused(let refusal):
                    // Unreachable: a refusal is retried on a FRESH session
                    // above, where setup failures come back as `.failed`.
                    // Handled rather than trapped — a wedged AP is worse than
                    // an odd error.
                    await closeLive(aborting: true)
                    return stopping(at: index,
                                    "internal: unhandled access-point session refusal: \(refusal)",
                                    nil)
                }

                // Once reuse is ruled out, each recording closes its own
                // session — exactly what calling the single-recording API in a
                // loop does.
                if reuseRuledOut { await closeLive(aborting: false) }
            }
        } catch {
            await closeLive(aborting: true)
            throw error
        }
        await closeLive(aborting: false)
        return WiFiBatchResult(delivered: delivered, stopped: nil)
    }

    /// One recording on an already-open session.
    ///
    /// The split that matters is between the setup phase — the state check, the
    /// TCP connect, the selection, the reroute — and the payload phase. Nothing
    /// of this recording has been read during setup, so a setup failure on a
    /// REUSED session is the device declining a second selection and a clean
    /// restart costs only time. From the first payload byte on, a failure is
    /// this recording's transfer failing and the batch stops.
    private func transferOneRecording(
        _ recording: RecordingInfo,
        on session: WiFiSessionHandle,
        reusingSession: Bool,
        destination: WiFiBatchDestination,
        endpointOverride: Network.NWEndpoint?,
        idleTimeout: Duration,
        readiness: WiFiReadiness,
        onProgress: (@Sendable (RecordingID, Double) -> Void)?
    ) async -> WiFiAttempt {
        // Is the session still there at all? The device is the only witness to
        // its own AP, and its answer distinguishes the two ways reuse can die
        // before anything is even attempted. Asked before anything is allocated,
        // so a refusal here costs nothing but the round-trip.
        if reusingSession, let state = await liveWiFiState(session) {
            switch state {
            case .off:
                return .refused("the device reported its WiFi off (MCU&WIFIS&0) after the "
                                + "previous recording — it closed the session itself")
            case .accessPointUp:
                return .refused("the device reports its AP up with no associated client "
                                + "(MCU&WIFIS&3) — this host left the network between "
                                + "recordings (iOS discards a joinOnce configuration on "
                                + "disassociation)")
            case .clientJoined, .tcpConnected:
                break   // still associated; carry on
            }
        }

        let sink: TransferSink
        switch destination {
        case .memory:
            sink = TransferSink.memory()
        case .files(let url):
            do { sink = try TransferSink.file(destination: url(recording)) }
            catch { return .failed(wifiFailureText(error), error as? PocketError) }
        }

        // The batch reports progress per recording; the transfer machinery below
        // is shared with the single-recording path and takes a bare fraction.
        let id = recording.id
        let progress: (@Sendable (Double) -> Void)?
        if let report = onProgress {
            progress = { fraction in report(id, fraction) }
        } else {
            progress = nil
        }

        // A fresh TCP connection per recording: the device closes the socket at
        // `MCU&OFF` (TCP FIN in the capture, at the same instant), so the previous
        // one is spent. The AP and the association are what carry over, not the
        // socket. Its own do/catch, not folded into the selection below, because
        // from the moment it returns EVERY exit must cancel it — a refusal that
        // left a socket open would leak one per recording.
        let connection: NWConnection
        do {
            connection = try await connectKeepingLinkAlive(
                to: endpointOverride ?? WiFiEndpoint.default, readiness: readiness,
                sessionActivity: session.activity)
        } catch is CancellationError {
            sink.abort()
            return .cancelled
        } catch {
            sink.abort()
            if reusingSession {
                // Not terminal: the live session would not take a second socket,
                // so this recording gets a fresh one. No diagnosis belongs on a
                // refusal — the run is about to repair it itself.
                return .refused("the device did not accept a second TCP connection on :8475 — it "
                                + "stopped listening after the previous recording: "
                                + wifiFailureText(error))
            }
            // A terminal connect failure, and the one the hardware run of
            // 2026-07-28 hit. It must carry the same diagnosis the
            // single-recording path attaches (`diagnosed(connectFailure:…)`),
            // because THIS is the text a batch prints as its stop reason: the
            // enrichment 0.1.2 added for exactly this failure never reached the
            // transcript, which reported only `wifi tcp connect timed out after
            // 30.0 seconds` and left the cause to be found by hand.
            let enriched = diagnosed(connectFailure: error, ssid: session.ssid,
                                     passphrase: session.passphrase,
                                     clientAssociationObserved: session.clientAssociationObserved,
                                     lastReportedState: session.lastReportedState)
            return .failed(wifiFailureText(enriched), enriched as? PocketError)
        }

        let announced: Int
        do {
            await confirmWiFiTCPConnected(session.activity)
            announced = try await selectRecordingOverWiFi(recording,
                                                          sessionActivity: session.activity)
        } catch is CancellationError {
            connection.cancel(); sink.abort()
            return .cancelled
        } catch {
            connection.cancel(); sink.abort()
            let text = wifiFailureText(error)
            return reusingSession
                ? .refused("the device would not serve another recording on the live session: \(text)")
                : .failed(text, error as? PocketError)
        }

        // A 0-byte announcement is a fact about the recording, not a refusal:
        // 0-second recordings exist on hardware, and a fresh session would
        // announce the same 0. It is admittedly ambiguous on a reused session —
        // the device *could* be declining by announcing nothing — but treating
        // it as a refusal would tear down a working session every time a
        // genuinely empty recording turned up in a batch. Recorded as an open
        // question in docs/protocol/ble-protocol.md.
        guard announced > 0 else {
            connection.cancel()
            sink.abort()
            return .failed(wifiFailureText(PocketError.emptyRecording), .emptyRecording)
        }

        do {
            try await rerouteSelectionToWiFi(session.activity)
        } catch is CancellationError {
            connection.cancel(); sink.abort()
            return .cancelled
        } catch {
            connection.cancel(); sink.abort()
            let text = wifiFailureText(error)
            return reusingSession
                ? .refused("the device acked a second selection but would not reroute it to the "
                           + "socket (APP&U&WIFI): \(text)")
                : .failed(text, error as? PocketError)
        }

        // Payload phase. Past here the device is pushing this recording's bytes,
        // so nothing is a reuse question any more.
        do {
            try await fetchOverTCP(connection: connection, expected: announced, sink: sink,
                                   sessionActivity: session.activity, idleTimeout: idleTimeout,
                                   onProgress: progress)
            try Task.checkCancellation()
            let data = try sink.finalize(announced: announced)
            session.activity.touch()
            progress?(1.0)
            return .delivered(byteCount: announced, data: data)
        } catch is CancellationError {
            connection.cancel(); sink.abort()
            return .cancelled
        } catch {
            connection.cancel(); sink.abort()
            return .failed(wifiFailureText(error), error as? PocketError)
        }
    }

    /// The device's own view of its WiFi state, or `nil` when it did not answer.
    /// Silence is not evidence — a firmware that stops answering `APP&WIFIS`
    /// must not be read as having closed the session — so the caller carries on
    /// and lets the selection decide.
    private func liveWiFiState(_ session: WiFiSessionHandle) async -> WiFiState? {
        session.activity.touch()
        let response = try? await request(.wifiStatus, timeout: .seconds(2)) {
            if case .wifiState = $0 { true } else { false }
        }
        session.activity.touch()
        guard case .wifiState(let state)? = response else { return nil }
        return state
    }
}
