// pocket-client/Sources/PocketClient/Session/DownloadReader.swift
import Foundation

/// Coordinates one bulk-channel transfer's completion. The payload bytes
/// live in the transfer's `TransferSink` (which also owns the integrity
/// rules); this class only counts them, because completion is byte-count
/// driven — `MCU&OFF` is only a hint, the response and data channels having
/// no cross-channel ordering guarantee.
///
/// Deliberately a lock-guarded class, not an actor: the session actor calls
/// `note` synchronously from its bulk sink, so chunks are counted in exact
/// stream order. Routing each chunk through a `Task` hop onto an actor was
/// observed reordering chunks (right length, scrambled bytes). Counting also
/// starts before the announced size is known, because the first data chunks
/// can race the `MCU&U&<size>` response.
final class TransferBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var announced: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var lastActivity = ContinuousClock.now

    /// Records the size from `MCU&U&<size>` and re-arms the idle clock:
    /// the transfer proper starts now.
    func announce(_ size: Int) {
        lock.lock()
        announced = size
        lastActivity = .now
        let completion = takeCompletionLocked()
        lock.unlock()
        if let c = completion { c?.resume() }
    }

    /// Counts a chunk. Called synchronously from the session actor's bulk
    /// sink — after the sink consumed the same chunk — so progress callbacks
    /// fire serialised in delivery order: monotonic by construction.
    func note(byteCount: Int, onProgress: (@Sendable (Double) -> Void)?) {
        lock.lock()
        count += byteCount
        lastActivity = .now
        let progress = announced.map { min(1.0, Double(count) / Double(max($0, 1))) }
        let completion = takeCompletionLocked()
        lock.unlock()
        if let progress { onProgress?(progress) }
        if let c = completion { c?.resume() }
    }

    func idleSince() -> Duration {
        lock.lock(); defer { lock.unlock() }
        return .now - lastActivity
    }

    var received: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Suspends until the transfer completes (or `finish` is forced).
    /// The completed-before-armed case is checked inside the continuation
    /// body, so a completion can never slip between check and arm.
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if finished || isCompleteLocked {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    /// Resumes `wait` regardless of how much has arrived. The idle watchdog
    /// calls this on timeout — cancellation never resumes a checked
    /// continuation, so leaving it pending would deadlock the task group.
    /// The `finished` flag also covers a `finish` that lands before `wait`
    /// has armed its continuation.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    private var isCompleteLocked: Bool {
        guard let announced else { return false }
        return count >= announced
    }

    /// Must be called with the lock held. If the byte count just reached the
    /// announced size, marks the transfer finished and returns the pending
    /// continuation (possibly nil) to resume outside the lock.
    private func takeCompletionLocked() -> CheckedContinuation<Void, Never>?? {
        guard !finished, isCompleteLocked else { return nil }
        finished = true
        let c = continuation
        continuation = nil
        return .some(c)
    }
}

extension PocketSession {
    /// Downloads one recording over BLE into memory. Correct and convenient
    /// at the device's observed sizes (≤ ~7 MB); a backlog sync of large
    /// files should prefer the streaming variant below. `idleTimeout` bounds
    /// how long the transfer may stall with no new bulk data before it is
    /// declared failed.
    public func downloadOverBLE(_ recording: RecordingInfo,
                                idleTimeout: Duration = .seconds(5),
                                onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        guard let data = try await downloadOverBLE(recording, into: TransferSink.memory(),
                                                   idleTimeout: idleTimeout,
                                                   onProgress: onProgress) else {
            throw PocketError.transferFailed("internal: memory sink produced no data")
        }
        return data
    }

    /// Streaming variant: writes the bytes to `destination` as they arrive
    /// instead of accumulating them in memory. Same wire flow, same
    /// integrity rules, same failure behaviour — the two shapes share one
    /// transfer implementation — plus the file guarantee: on ANY failure
    /// (including cancellation) nothing appears at `destination`, and a
    /// pre-existing file there is replaced only by a validated download.
    ///
    /// There is no resume: `APP&U&<date>&<ts>` takes no byte offset (no
    /// protocol command does), so a failed transfer restarts from byte zero.
    public func downloadOverBLE(_ recording: RecordingInfo,
                                to destination: URL,
                                idleTimeout: Duration = .seconds(5),
                                onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await downloadOverBLE(recording, into: TransferSink.file(destination: destination),
                                      idleTimeout: idleTimeout, onProgress: onProgress)
    }

    /// The one BLE transfer implementation both public shapes call — where
    /// the payload lands is the sink's business, never this function's, so
    /// the two shapes cannot drift. On any failure the sink is aborted: the
    /// partial payload must not survive looking like a recording.
    private func downloadOverBLE(_ recording: RecordingInfo,
                                 into sink: TransferSink,
                                 idleTimeout: Duration,
                                 onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        do {
            return try await runBLETransfer(recording, sink: sink,
                                            idleTimeout: idleTimeout, onProgress: onProgress)
        } catch {
            sink.abort()
            throw error
        }
    }

    private func runBLETransfer(_ recording: RecordingInfo,
                                sink: TransferSink,
                                idleTimeout: Duration,
                                onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        // One transfer at a time: without this, a second call would overwrite
        // this transfer's sink, feed our remaining chunks into its buffer, and
        // its defer would nil the sink under us. No suspension between the
        // claim and the sink install, so the pair is effectively atomic.
        try beginTransfer()
        // The sink must be live before APP&U goes out: bulk chunks can be
        // delivered before the size response finishes unwinding the request,
        // and chunks that arrive with no sink installed are discarded.
        let buffer = TransferBuffer()
        setBulkSink { chunk in
            sink.consume(chunk)
            buffer.note(byteCount: chunk.count, onProgress: onProgress)
        }
        defer {
            setBulkSink(nil)
            endTransfer()
        }

        let sizeResponse = try await request(.download(recording.id)) {
            if case .transferSize = $0 { true } else { false }
        }
        guard case .transferSize(let announced) = sizeResponse else {
            throw PocketError.unexpectedResponse("expected MCU&U&<size>")
        }
        // 0-second recordings exist on real hardware and announce 0 bytes.
        // Without this guard the empty payload passes the byte-count check
        // (0 == 0) and dies in the sync-word check as `.notMP3` — wrong story.
        guard announced > 0 else { throw PocketError.emptyRecording }
        buffer.announce(announced)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await buffer.wait() }
            group.addTask {
                while true {
                    // On cancellation the sleep returns immediately; without
                    // this check the loop would spin hot until the idle
                    // timeout elapsed and then misreport a size mismatch.
                    if Task.isCancelled {
                        buffer.finish()   // unblock wait() promptly
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                    if buffer.received >= announced { return }
                    if buffer.idleSince() > idleTimeout {
                        buffer.finish()   // unblock wait() despite partial data
                        return
                    }
                }
            }
            _ = await group.next()
            group.cancelAll()
        }

        // A cancelled caller gets CancellationError, not a bogus size error.
        try Task.checkCancellation()
        // The shared integrity rules — exact announced count, FF F3 sync —
        // and, for a file sink, the atomic publish, all live in the sink.
        let data = try sink.finalize(announced: announced)
        onProgress?(1.0)
        return data
    }
}
