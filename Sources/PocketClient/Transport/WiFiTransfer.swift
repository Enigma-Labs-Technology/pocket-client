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

/// A joiner for macOS harness runs: prints instructions and waits for the
/// operator to join the AP by hand, then continues.
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
        _ = readLine()
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
}

// NWEndpoint is written `Network.NWEndpoint` throughout this file: on iOS,
// NetworkExtension exports a legacy class of the same name, and the bare
// name fails to compile as ambiguous.
enum WiFiEndpoint {
    /// The device serves the file at this address once a client joins its AP.
    static let deviceHost = "192.168.200.1"
    static let devicePort: UInt16 = 8475

    static var `default`: Network.NWEndpoint {
        .hostPort(host: Network.NWEndpoint.Host(deviceHost),
                  port: Network.NWEndpoint.Port(rawValue: devicePort)!)
    }
}

/// Wall clock of the last transfer activity, shared between the TCP reader
/// and its stall watchdog.
private final class ActivityMonitor: @unchecked Sendable {
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
    static func receive(on connection: NWConnection,
                        expected: Int,
                        idleTimeout: Duration = .seconds(10),
                        into sink: TransferSink,
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

        do {
            try await joiner.join(ssid: ssid, passphrase: passphrase)
        } catch {
            try? await send(.wifiClose)
            throw diagnosed(joinFailure: error, ssid: ssid, passphrase: passphrase)
        }
        // From here every exit must also leave the AP so the operator's
        // normal network comes back. `leave()` is async, so a defer cannot
        // await it, and a fire-and-forget Task in a defer would race callers
        // that observe the joiner as soon as this function returns — hence
        // the explicit do/catch instead.
        do {
            // 5. Wait (leniently) for MCU&WIFIS&2: the capture shows the TCP
            // connect only after the device reports the association, and
            // connecting earlier just burns the timeout against a network
            // that is not routing yet.
            let observedJoin = try await awaitWiFiClientJoined(readiness)
            if !observedJoin {
                // Lenient by design: if this firmware's state machine differs
                // from the capture, do not block a transfer that would work —
                // but make sure the fact is visible to the CLI/checkpoint.
                emitEvent(.wifiReadinessNotObserved)
            }
            // 6. TCP first — the selection that follows is served into this
            // socket, and the device reports it as MCU&WIFIS&1.
            let connection: NWConnection
            do {
                connection = try await connectKeepingLinkAlive(
                    to: endpointOverride ?? WiFiEndpoint.default, readiness: readiness)
            } catch {
                throw diagnosed(connectFailure: error, ssid: ssid, passphrase: passphrase,
                                clientAssociationObserved: observedJoin)
            }
            do {
                let data = try await transferOverTCP(recording, connection: connection,
                                                     sink: sink,
                                                     idleTimeout: idleTimeout,
                                                     onProgress: onProgress)
                await joiner.leave()
                return data
            } catch {
                connection.cancel()   // idempotent; receive() may already have
                throw error
            }
        } catch {
            // Best-effort abort of a possibly selected upload (SHUT has no
            // reply when nothing is in flight), then close the AP.
            try? await send(.wifiShutdown)
            try? await send(.wifiClose)
            await joiner.leave()
            throw error
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

    /// A TCP connect that fails while the device never reported a client on its
    /// AP is the shape this failure takes on the macOS path, where the join
    /// cannot fail: the operator pressed return, nothing associated, and the
    /// only symptom reaching the process is a socket that never opens
    /// (`wifi tcp connect timed out after 30.0 seconds`, on 2026-07-28). The
    /// device is the witness here — it says whether *any* client ever
    /// associated with the AP it was broadcasting — so the guidance is added
    /// only when it saw none. When the association *was* observed the text is
    /// left alone: the host is demonstrably on the AP, so cached credentials
    /// are not the story and saying otherwise would be noise.
    ///
    /// Message only. The error case, the control flow, and the AP teardown are
    /// unchanged, and `CancellationError` passes through untouched.
    private func diagnosed(connectFailure error: Error, ssid: String, passphrase: String,
                           clientAssociationObserved: Bool) -> Error {
        guard !clientAssociationObserved,
              case PocketError.transferFailed(let detail) = error else { return error }
        return PocketError.transferFailed(
            "\(detail) — the device never reported a client on its AP (no MCU&WIFIS&2), so nothing "
            + "joined \(ssid): "
            + wifiJoinDiagnosis(reportedPassphrase: passphrase).guidance(ssid: ssid))
    }

    /// Polls `APP&WIFIS` until the device reports `.clientJoined` (2) — or
    /// `.tcpConnected` (1), which subsumes it — sending `APP&WPING`
    /// keepalives between polls so a slow (possibly human-paced) association
    /// cannot idle out the BLE link. Returns `false` when `readiness.timeout`
    /// elapses without either state being observed — deliberately not an
    /// error (see the call site). Throws only for caller cancellation and a
    /// dead session.
    private func awaitWiFiClientJoined(_ readiness: WiFiReadiness) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + readiness.timeout
        var lastPing = clock.now
        while clock.now < deadline {
            try Task.checkCancellation()
            guard isAuthenticated else { throw PocketError.notAuthenticated }
            let response = try? await request(.wifiStatus, timeout: .seconds(2)) {
                if case .wifiState = $0 { true } else { false }
            }
            if case .wifiState(let state)? = response,
               state == .clientJoined || state == .tcpConnected {
                return true
            }
            if clock.now - lastPing >= readiness.pingInterval {
                _ = try? await request(.wifiKeepalive, timeout: .seconds(2)) { $0 == .pong }
                lastPing = clock.now
            }
            try? await Task.sleep(for: readiness.pollInterval)
        }
        return false
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
                    _ = try? await self.request(.wifiKeepalive, timeout: .seconds(2)) { $0 == .pong }
                }
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let connection = first else {
                try Task.checkCancellation()
                throw PocketError.transferFailed("wifi tcp connect never completed")
            }
            return connection
        }
    }

    /// The connected stretch: select the recording, reroute it to the
    /// socket, read exactly the announced bytes into the sink, close, verify.
    private func transferOverTCP(_ recording: RecordingInfo,
                                 connection: NWConnection,
                                 sink: TransferSink,
                                 idleTimeout: Duration,
                                 onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        // One confirmation poll, as the official app does once its TCP
        // connect succeeds (the device answers MCU&WIFIS&1). Lenient: the
        // open socket is the ground truth, so the answer is observational.
        _ = try? await request(.wifiStatus, timeout: .seconds(2)) {
            if case .wifiState = $0 { true } else { false }
        }

        // 7a. Select the recording — the same frame as a BLE download, and
        // the device may briefly restart BLE bulk for it (the capture shows
        // ~15 KB of leakage). No bulk sink is installed on this path, so
        // those notifications are discarded, never mixed into the file.
        let sizeResponse = try await request(.download(recording.id), timeout: .seconds(30)) {
            if case .transferSize = $0 { true } else { false }
        }
        guard case .transferSize(let announced) = sizeResponse else {
            throw PocketError.unexpectedResponse("expected MCU&U&<size>")
        }
        // Same guard as the BLE path: a 0-byte recording must fail fast and
        // truthfully — before the device is told to serve it over the socket.
        guard announced > 0 else { throw PocketError.emptyRecording }

        // 7b. APP&U&WIFI is a modifier on the selection above: it reroutes
        // the in-progress upload to the TCP socket. The MCU&U&WIFI ack can
        // lag (~1.2 s in the capture); the repeated MCU&U&<size> that follows
        // it arrives unarmed and surfaces as an observational event.
        _ = try await request(.wifiDownload, timeout: .seconds(30)) { $0 == .wifiUploadAck }

        let received = try await TCPFetch.receive(on: connection,
                                                  expected: announced,
                                                  idleTimeout: idleTimeout,
                                                  into: sink,
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

        // 8. Sent twice, mirroring the vendor app's captured traffic; the
        // device tolerates the redundant close.
        try? await send(.wifiClose)
        try? await send(.wifiClose)

        // A cancelled caller gets CancellationError, not a bogus size error.
        try Task.checkCancellation()
        // Integrity rules are identical to BLE by construction — exact byte
        // count + FF F3 sync live in the shared sink, which also publishes a
        // file destination only now, after both checks pass.
        let data = try sink.finalize(announced: announced)
        onProgress?(1.0)
        return data
    }
}
