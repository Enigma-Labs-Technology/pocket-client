// pocket-client/Sources/PocketClient/Session/PocketSession.swift
import Foundation

/// Owns the authenticated conversation with the device: handshake,
/// request/response correlation, unsolicited events, and the keepalive.
public actor PocketSession {
    private let transport: PocketTransport
    private let sessionKey: String
    private let keepaliveInterval: Duration

    private var consumeTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// Read by RecordControl's lifecycle guard; only this file mutates it.
    private(set) var isAuthenticated = false

    /// One in-flight request at a time; the actor serialises callers.
    private var waiter: Waiter?
    /// Monotonic token, one per `perform`, recorded in the waiter it arms.
    /// Cleanup paths that can run late — timeout expiry, a suspended send's
    /// failure — must prove the slot still holds *their* waiter before
    /// touching it: a bare nil-check would let request A's stale cleanup
    /// destroy request B's waiter and double-resume A's continuation.
    private var generation = 0
    /// Highest generation whose deadline fired before its waiter was armed;
    /// `arm` refuses to install such a waiter (its expiry already ran, so
    /// nobody would be left to resume it — the slot would wedge forever).
    private var latestExpiredGeneration = 0

    /// What this session's key implies the device's Wi-Fi AP password should
    /// be: the key's first `WiFiJoinDiagnosis.passphraseLength` characters, the
    /// derivation recorded in `docs/protocol/ble-protocol.md`. `nil` when the
    /// key is too short for that derivation to say anything — real keys are
    /// `PocketKey.length`, so only a hand-made short one lands there.
    ///
    /// Internal, and deliberately this narrow rather than exposing the key:
    /// the WiFi transfer compares it against the password the device reports
    /// in order to say *where* a failed join went wrong (see
    /// `WiFiJoinDiagnosis`). That is the only reason any part of the key leaves
    /// this file, and neither value is ever logged or put in an error message.
    var apPassphraseImpliedByKey: String? {
        guard sessionKey.count >= WiFiJoinDiagnosis.passphraseLength else { return nil }
        return String(sessionKey.prefix(WiFiJoinDiagnosis.passphraseLength))
    }

    /// Events buffer bound. Events are current-state signals (recording
    /// markers, link loss, observational frames) with no replay value once
    /// stale, so the stream keeps only the newest 64 — comfortably above the
    /// busiest observed burst (a full WiFi flow surfaces well under ten
    /// observational frames) — and drops the oldest first, which can never
    /// drop the final `.disconnected`.
    static let eventBufferDepth = 64

    private let eventContinuation: AsyncStream<DeviceEvent>.Continuation
    /// Unsolicited device traffic and session diagnostics.
    ///
    /// Single-consumer: one shared `AsyncStream` backs this property, so a
    /// second concurrent `for await` splits events between the two iterators
    /// nondeterministically. Hand the stream to exactly one consumer and fan
    /// out from there. Buffers the newest `eventBufferDepth` events and
    /// finishes on `stop()` and on link loss — after the final
    /// `.disconnected` — so a consumer's loop terminates instead of blocking
    /// on a dead session.
    public nonisolated let events: AsyncStream<DeviceEvent>

    /// Echoes the keepalive's own `APP&BAT` pings are still owed (one per
    /// ping sent). `emitAsEvent` absorbs exactly this many unsolicited
    /// battery frames instead of surfacing them as `.unmatchedResponse` —
    /// they are this session's link filler being answered every interval,
    /// not a device anomaly, and as noise they would bury the genuine
    /// unexpected-frame diagnostic. Only keepalive-provoked echoes count;
    /// any other battery frame keeps flowing.
    private var pendingKeepaliveEchoes = 0

    /// Bulk chunks are consumed by whoever is transferring; nil means discard.
    private var bulkSink: ((Data) -> Void)?

    /// Bulk transfers are exclusive. `request`'s busy guard only covers the
    /// armed window; a transfer spends most of its life consuming bulk data
    /// with no waiter armed, so it needs its own mutual exclusion — otherwise
    /// a second transfer would silently overwrite the first one's sink.
    private var transferActive = false

    /// Continuation of the active live-audio stream, if any. `stop()` and
    /// link loss must finish it — otherwise a consumer blocked on the next
    /// frame hangs forever on a dead link, and the transfer slot the stream
    /// holds stays claimed, failing every later download with `.busy`.
    /// Owned by RecordControl; torn down via `teardownLiveStream()`.
    var liveContinuation: AsyncStream<Data>.Continuation?
    /// Monotonic token distinguishing the current live stream from a defunct
    /// one whose off-actor termination hop lands late (e.g. after a
    /// disconnect-teardown-reconnect cycle has started a new stream).
    var liveStreamGeneration = 0
    /// Teardown-effect witness: counts actual (non-no-op) live-stream
    /// teardowns. Lets tests prove a specific path — e.g. the onTermination
    /// hop — performed the release, rather than an idempotent later call.
    var liveTeardownCount = 0

    private struct Waiter {
        let matches: (Response) -> Bool
        let isTerminator: ((Response) -> Bool)?
        let command: Command
        var collected: [Response]
        let continuation: CheckedContinuation<[Response], Error>
        let generation: Int
    }

    public init(transport: PocketTransport, sessionKey: String) {
        self.init(transport: transport, sessionKey: sessionKey, keepaliveInterval: .seconds(30))
    }

    /// Internal: tests inject a short interval to exercise keepalive behaviour.
    init(transport: PocketTransport, sessionKey: String, keepaliveInterval: Duration) {
        self.transport = transport
        self.sessionKey = sessionKey
        self.keepaliveInterval = keepaliveInterval
        (events, eventContinuation) = AsyncStream<DeviceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferDepth))
    }

    /// Starts the response loop and performs the mandatory SK handshake.
    /// Commands sent before this are silently ignored by the device.
    public func start(timeout: Duration = .seconds(5)) async throws {
        let responses = transport.responseStream()
        consumeTask = Task { [weak self] in
            for await payload in responses {
                // The frame text rides along so an unmatched response can be
                // reported verbatim — `Response` alone cannot reproduce it
                // (parsed cases discard the original text).
                let raw = String(decoding: payload, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await self?.handle(Response.parse(raw), raw: raw)
            }
            await self?.handleDisconnect()
        }
        let bulk = transport.bulkStream()
        Task { [weak self] in
            for await chunk in bulk { await self?.deliverBulk(chunk) }
        }

        let result = try await perform(.auth(sessionKey), timeout: timeout,
                                       matches: { $0 == .authOK || $0 == .authError },
                                       terminator: nil)
        guard result.first == .authOK else { throw PocketError.authRejected }
        isAuthenticated = true
        startKeepalive()
    }

    public func stop() async {
        isAuthenticated = false
        // Before any suspension: the consumer's `for await` must end promptly
        // and the transfer slot must be free for whatever comes next.
        teardownLiveStream()
        keepaliveTask?.cancel()
        consumeTask?.cancel()
        await transport.disconnect()
        eventContinuation.finish()
    }

    /// Sends a command and waits for the first response satisfying `expecting`.
    public func request(_ command: Command,
                        timeout: Duration = .seconds(5),
                        expecting: @escaping @Sendable (Response) -> Bool) async throws -> Response {
        guard isAuthenticated || command.isAuth else { throw PocketError.notAuthenticated }
        let responses = try await perform(command, timeout: timeout, matches: expecting, terminator: nil)
        guard let first = responses.first else { throw PocketError.timeout(command) }
        return first
    }

    /// Sends a command and collects every response satisfying `element`
    /// until one satisfying `terminator` arrives. Returns the elements only.
    public func requestCollecting(_ command: Command,
                                  timeout: Duration = .seconds(10),
                                  element: @escaping @Sendable (Response) -> Bool,
                                  terminator: @escaping @Sendable (Response) -> Bool) async throws -> [Response] {
        guard isAuthenticated else { throw PocketError.notAuthenticated }
        return try await perform(command, timeout: timeout, matches: element, terminator: terminator)
    }

    /// Fire-and-forget write (used by transfer flows that await bulk data instead).
    public func send(_ command: Command) async throws {
        guard isAuthenticated || command.isAuth else { throw PocketError.notAuthenticated }
        try await transport.send(command.encoded)
    }

    func setBulkSink(_ sink: ((Data) -> Void)?) { bulkSink = sink }

    /// Atomically claims the single transfer slot. Actor isolation makes the
    /// check-and-set indivisible; callers must install their sink without
    /// suspending in between and release via `endTransfer` in the same defer
    /// that restores the sink.
    func beginTransfer() throws {
        guard !transferActive else { throw PocketError.busy("transfer already in progress") }
        transferActive = true
    }

    func endTransfer() { transferActive = false }

    // MARK: - Internals

    private func perform(_ command: Command,
                         timeout: Duration,
                         matches: @escaping (Response) -> Bool,
                         terminator: ((Response) -> Bool)?) async throws -> [Response] {
        generation += 1
        let g = generation
        return try await withThrowingTaskGroup(of: [Response].self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.arm(command: command, generation: g, matches: matches,
                                          terminator: terminator, continuation: continuation) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                // Wakes on genuine expiry AND on cancellation — the caller's
                // own, or the winner's cancelAll. Either way the armed waiter
                // must be failed so its child task can finish: cancellation
                // alone never resumes a checked continuation, and one left
                // pending deadlocks this group — the caller would hang past
                // every timeout while the wedged slot failed all later
                // requests with `.busy`. Only the error differs; the call is
                // identity-guarded, so a resolved waiter is untouched.
                let error: Error = Task.isCancelled ? CancellationError()
                                                    : PocketError.timeout(command)
                await self.expireWaiter(command, generation: g, throwing: error)
                throw error
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PocketError.timeout(command) }
            return first
        }
    }

    private func arm(command: Command,
                     generation g: Int,
                     matches: @escaping (Response) -> Bool,
                     terminator: ((Response) -> Bool)?,
                     continuation: CheckedContinuation<[Response], Error>) async {
        // The deadline can beat this job onto the actor; a waiter armed after
        // its own expiry would never be resumed, wedging the slot forever.
        guard g > latestExpiredGeneration else {
            continuation.resume(throwing: PocketError.timeout(command))
            return
        }
        guard waiter == nil else {
            continuation.resume(throwing: PocketError.busy("request already in flight"))
            return
        }
        waiter = Waiter(matches: matches, isTerminator: terminator, command: command,
                        collected: [], continuation: continuation, generation: g)
        do {
            try await transport.send(command.encoded)
        } catch {
            // While `send` was suspended, this request may have timed out (slot
            // cleared, continuation resumed) and a NEW request armed the slot.
            // Only our own waiter may be failed here — identity, not presence.
            guard let current = waiter, current.generation == g else { return }
            waiter = nil
            continuation.resume(throwing: PocketError.transferFailed("\(error)"))
        }
    }

    /// Fails the in-flight waiter with `error` (timeout on genuine expiry,
    /// `CancellationError` when the deadline was cancelled) — but only the
    /// waiter this deadline belongs to; the actor makes the check-and-clear
    /// atomic. When the waiter is missing (already resolved) or someone
    /// else's, the generation is recorded so a not-yet-armed waiter refuses
    /// to install. (Recording is safe on every path: it only ever blocks the
    /// arming of generation ≤ g, whose own deadline has by then already run.)
    private func expireWaiter(_ command: Command, generation g: Int, throwing error: Error) {
        guard let pending = waiter, pending.generation == g else {
            latestExpiredGeneration = max(latestExpiredGeneration, g)
            return
        }
        waiter = nil
        pending.continuation.resume(throwing: error)
    }

    private func handle(_ response: Response, raw: String) {
        guard var pending = waiter else {
            emitAsEvent(response, raw: raw)
            return
        }

        if response == .unknown {
            waiter = nil
            pending.continuation.resume(throwing: PocketError.unknownCommand(pending.command))
            return
        }

        if let isTerminator = pending.isTerminator {
            if isTerminator(response) {
                waiter = nil
                pending.continuation.resume(returning: pending.collected)
            } else if pending.matches(response) {
                pending.collected.append(response)
                waiter = pending
            } else {
                emitAsEvent(response, raw: raw)
            }
            return
        }

        if pending.matches(response) {
            waiter = nil
            pending.continuation.resume(returning: [response])
        } else {
            emitAsEvent(response, raw: raw)
        }
    }

    /// Unsolicited traffic. `MCU&REC&CON` is ambiguous — as an unsolicited
    /// message it is the recording-started marker, whose timestamp arrives
    /// in the following `MCU&STA&<ts>`.
    ///
    /// Anything not recognised below surfaces as `.unmatchedResponse` with
    /// the frame text verbatim: on real hardware the device has answered in
    /// shapes this client did not script (the `APP&WIFIS` handshake), and
    /// dropping those frames made "unexpected answer" indistinguishable from
    /// "no answer". Observation only — no matching or timeout path changes.
    private func emitAsEvent(_ response: Response, raw: String) {
        switch response {
        case .recordingStarted(let ts):
            let date = Self.dateDirectory(fromTimestamp: ts)
            eventContinuation.yield(.recordingStarted(RecordingID(date: date, timestamp: ts)))
        case .recordingInProgress(let since, let elapsed):
            eventContinuation.yield(.recordingInProgress(since: since, elapsedSeconds: elapsed))
        case .recordingStopped:
            eventContinuation.yield(.recordingStopped)
        case .battery where pendingKeepaliveEchoes > 0:
            // Our own keepalive's `APP&BAT` being answered — expected link
            // filler, absorbed one echo per ping (see `pendingKeepaliveEchoes`).
            pendingKeepaliveEchoes -= 1
        default:
            eventContinuation.yield(.unmatchedResponse(raw))
        }
    }

    /// Session-level diagnostics (e.g. WiFi readiness never observed) ride
    /// the same stream as device-originated events, so every consumer —
    /// including the CLI's event printer — sees them without new plumbing.
    func emitEvent(_ event: DeviceEvent) { eventContinuation.yield(event) }

    private func deliverBulk(_ chunk: Data) { bulkSink?(chunk) }

    private func handleDisconnect() {
        isAuthenticated = false
        // The link is gone: finish the live stream (its consumer would
        // otherwise hang) and release the slot it holds.
        teardownLiveStream()
        if let pending = waiter {
            waiter = nil
            pending.continuation.resume(throwing: PocketError.disconnected)
        }
        eventContinuation.yield(.disconnected)
        // The link is gone for good (transports are single-use), so no later
        // event can exist: finish the stream so a consumer that never calls
        // stop() itself terminates its `for await` instead of blocking
        // forever. The `.disconnected` above is already buffered, so it is
        // still delivered first.
        eventContinuation.finish()
    }

    private func startKeepalive() {
        let interval = keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.sendKeepalivePing()
            }
        }
    }

    /// Fire-and-forget link filler: it never arms a waiter, so it cannot
    /// race a user request into the busy guard — even while one is in
    /// flight. The device's unsolicited MCU&BAT reply is benign on every
    /// route through `handle`: it satisfies an armed battery request (same
    /// reading), is ignored by any other matcher, and is otherwise absorbed
    /// by `emitAsEvent` as this session's own expected echo — never noise,
    /// never disruptive.
    private func sendKeepalivePing() async {
        // Count the owed echo BEFORE the send suspends: on a fast link the
        // reply can reach `handle` before `send` returns to this method.
        pendingKeepaliveEchoes += 1
        do { try await send(.battery) }
        catch { pendingKeepaliveEchoes -= 1 }   // nothing went out; no echo is owed
    }

    /// "20260104101500" → "2026-01-04".
    ///
    /// Device timestamps are normally 14 ASCII digits (YYYYMMDDHHMMSS), but
    /// live hardware has produced other shapes (e.g. "PH260105143000").
    /// Anything that is not exactly 14 ASCII digits passes through verbatim:
    /// slicing a fabricated "date" out of it would silently aim later
    /// APP&U/APP&D commands at a directory that does not exist, and deriving
    /// one from the wall clock would guess (wrongly, around midnight or under
    /// clock skew) while hiding that anything was unusual. The raw string is
    /// honest, deterministic, and visibly not a date; the true directory for
    /// such a recording is recoverable via listDates()/listRecordings(on:).
    static func dateDirectory(fromTimestamp ts: String) -> String {
        let digits = Array(ts.utf8)
        guard digits.count == 14,
              digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return ts
        }
        let y = ts.prefix(4)
        let m = ts.dropFirst(4).prefix(2)
        let d = ts.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }
}

extension Command {
    var isAuth: Bool { if case .auth = self { true } else { false } }
}
