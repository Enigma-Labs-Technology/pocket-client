// pocket-client/Sources/PocketClient/PocketDevice.swift
import Foundation

extension TransferMode {
    /// `.auto` must decide before the size is announced, so it estimates from
    /// duration at the device's fixed 32 kbps: WiFi above 1 MB, BLE otherwise.
    static let autoThresholdBytes = 1_048_576

    static func resolve(_ mode: TransferMode, for recording: RecordingInfo) -> TransferMode {
        switch mode {
        case .ble, .wifi: return mode
        case .auto: return recording.estimatedBytes > autoThresholdBytes ? .wifi : .ble
        }
    }
}

/// The package's public entry point: one `PocketDevice` per BLE link.
///
/// Lifecycle — deliberately single-use: `connect()` succeeds at most once.
/// `disconnect()` (and a failed `connect()`, which also tears the session
/// down) finishes the transport's single-consumer streams, which kills the
/// session's consume loops for good, so reconnection through the same
/// instance could never work and is rejected loudly instead: `connect()`
/// throws `PocketError.disconnected` once the instance is spent, and
/// `PocketError.busy` while a connect is in flight or the device is
/// connected. To reconnect, build a fresh transport and a fresh
/// `PocketDevice`.
public actor PocketDevice {
    private enum Lifecycle { case idle, connecting, connected, closed }

    private let session: PocketSession
    private let joiner: HotspotJoining
    private var lifecycle = Lifecycle.idle

    /// `joiner` performs the WiFi hotspot join for `.wifi`/`.auto` downloads.
    /// The default joins programmatically on iOS; the macOS CLI passes
    /// `ManualHotspotJoiner()` instead.
    public init(transport: PocketTransport,
                sessionKey: String,
                joiner: HotspotJoining = SystemHotspotJoiner()) {
        self.session = PocketSession(transport: transport, sessionKey: sessionKey)
        self.joiner = joiner
    }

    /// Unsolicited device traffic: recordings started on-device, link loss,
    /// observational frames.
    ///
    /// Single-consumer: one shared `AsyncStream` backs this property — a
    /// second concurrent `for await` splits events between the two iterators
    /// nondeterministically. Hand the stream to exactly one consumer and fan
    /// out from there. It buffers the newest 64 events and finishes after
    /// the final `.disconnected` on link loss, or on `disconnect()`.
    public nonisolated var events: AsyncStream<DeviceEvent> { session.events }

    /// Starts the session and performs the mandatory SK handshake.
    /// Single-shot — see the lifecycle note on the type.
    public func connect() async throws {
        switch lifecycle {
        // `.connecting` must be its own state: a second connect() inside the
        // handshake window would call session.start() again and spawn a
        // second consume loop on the same single-consumer response stream,
        // which splits payloads arbitrarily between the two iterators.
        case .connecting: throw PocketError.busy("connect already in progress")
        case .connected: throw PocketError.busy("already connected")
        case .closed: throw PocketError.disconnected
        case .idle: break
        }
        lifecycle = .connecting
        do {
            try await session.start()
        } catch {
            // The failed attempt consumed the transport's single-consumer
            // streams, so the instance is spent — and the session must be
            // torn down HERE: it drops the transport link, ends the consume
            // tasks, and finishes `events` so nobody hangs iterating them.
            // (`disconnect()` no-ops from `.closed`, so nothing later would.)
            lifecycle = .closed
            await session.stop()
            throw error
        }
        guard lifecycle == .connecting else {
            // A disconnect() raced the handshake and won: it already ran
            // session.stop(); the device must stay closed, not resurrect.
            throw PocketError.disconnected
        }
        lifecycle = .connected
    }

    /// Ends the session and closes the link for good. Idempotent.
    public func disconnect() async {
        guard lifecycle != .closed else { return }
        lifecycle = .closed
        await session.stop()
    }

    public func status() async throws -> DeviceStatus { try await session.status() }
    /// One round-trip (`APP&STE`), for polling — see `PocketSession.isRecording()`.
    public func isRecording() async throws -> Bool { try await session.isRecording() }
    public func setClock(_ date: Date = Date()) async throws { try await session.setClock(date) }
    public func listDates() async throws -> [String] { try await session.listDates() }
    public func listRecordings(on date: String) async throws -> [RecordingInfo] {
        try await session.listRecordings(on: date)
    }
    public func delete(_ id: RecordingID) async throws { try await session.delete(id) }

    /// Downloads into memory. Convenient at the device's observed sizes
    /// (≤ ~7 MB); a backlog sync of large recordings should prefer the
    /// streaming variant below, which never holds the whole file.
    public func download(_ recording: RecordingInfo,
                         via mode: TransferMode = .auto,
                         onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        try await routedDownload(recording, mode: mode,
            wifi: { try await self.session.downloadOverWiFi(recording, joiner: self.joiner,
                                                            onProgress: onProgress) },
            ble: { try await self.session.downloadOverBLE(recording, onProgress: onProgress) })
    }

    /// Streaming variant: writes the bytes to `destination` as they arrive
    /// instead of returning `Data`. Same routing, same integrity rules; on
    /// ANY failure (including cancellation) nothing appears at `destination`
    /// — the bytes stream into a hidden temp companion that is atomically
    /// renamed into place only after validation passes.
    ///
    /// There is no resume: `APP&U&<date>&<ts>` takes no byte offset (no
    /// protocol command does), so a failed transfer restarts from byte zero
    /// — streaming saves memory, not re-transfer time.
    public func download(_ recording: RecordingInfo,
                         to destination: URL,
                         via mode: TransferMode = .auto,
                         onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await routedDownload(recording, mode: mode,
            wifi: { try await self.session.downloadOverWiFi(recording, to: destination,
                                                            joiner: self.joiner,
                                                            onProgress: onProgress) },
            ble: { try await self.session.downloadOverBLE(recording, to: destination,
                                                          onProgress: onProgress) })
    }

    /// Transfers several recordings over **one** access-point session instead of
    /// one session per recording — see
    /// `PocketSession.downloadOverWiFi(_:into:endpointOverride:joiner:idleTimeout:readiness:onProgress:)`
    /// for the full contract. Uses this device's joiner, so on macOS the
    /// operator is asked to join the network once for the whole batch.
    ///
    /// **`unverified`:** whether the device will serve a second
    /// `APP&U&<date>&<ts>` while its AP is still up has never been observed on
    /// hardware. The run attempts it and falls back to one session per recording
    /// the moment the device refuses, so the worst case is exactly what calling
    /// `download(_:via: .wifi)` in a loop does today.
    /// `WiFiBatchResult.didReuseSession` says which happened.
    ///
    /// WiFi only, and deliberately: there is no BLE fallback and no `.auto`
    /// here. A batch exists to avoid repeating the AP handshake, which BLE does
    /// not have, and silently syncing 350 MB over a ~35 KB/s link is not a
    /// fallback anyone would choose on the caller's behalf. Read
    /// `WiFiBatchResult.stopped` and decide.
    public func downloadOverWiFi(
        _ recordings: [RecordingInfo],
        into destination: WiFiBatchDestination = .memory,
        idleTimeout: Duration = .seconds(10),
        readiness: WiFiReadiness = WiFiReadiness(),
        onProgress: (@Sendable (RecordingID, Double) -> Void)? = nil
    ) async throws -> WiFiBatchResult {
        try await session.downloadOverWiFi(recordings, into: destination, joiner: joiner,
                                           idleTimeout: idleTimeout, readiness: readiness,
                                           onProgress: onProgress)
    }

    /// The `.auto` routing policy both download shapes share — one place, so
    /// the fallback rules cannot drift: WiFi first when the mode resolves
    /// there, degrading to BLE only for `.auto`, and never for caller
    /// cancellation or an empty recording. (A failed WiFi attempt cleans up
    /// after itself — including any partial file — before BLE retries.)
    private func routedDownload<T: Sendable>(_ recording: RecordingInfo,
                                             mode: TransferMode,
                                             wifi: () async throws -> T,
                                             ble: () async throws -> T) async throws -> T {
        if TransferMode.resolve(mode, for: recording) == .wifi {
            do {
                return try await wifi()
            } catch let cancellation as CancellationError {
                throw cancellation   // a cancelled caller is not a WiFi failure
            } catch PocketError.emptyRecording {
                // Not a transport failure: the device has no bytes to serve,
                // so a BLE retry would fail identically, only slower.
                throw PocketError.emptyRecording
            } catch {
                // Explicit .wifi surfaces the failure; .auto degrades to
                // slow-but-working BLE.
                guard mode == .auto else { throw error }
            }
        }
        return try await ble()
    }

    public func startRecording() async throws -> RecordingID { try await session.startRecording() }
    public func stopRecording() async throws { try await session.stopRecording() }
    // No pause/resume: firmware 1.7 answers `MCU&UNKNOWN` to `APP&PAU` and
    // `APP&RESU` (probed 2026-07-25). See RecordControl.swift.
    /// Throws `PocketError.busy` while a download holds the bulk channel and
    /// `PocketError.notAuthenticated` before `connect()` — the live stream
    /// claims the session's exclusive transfer slot, shared with downloads.
    public func liveAudio() async throws -> AsyncStream<Data> { try await session.liveAudio() }
}
