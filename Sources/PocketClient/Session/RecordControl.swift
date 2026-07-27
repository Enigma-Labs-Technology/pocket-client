// pocket-client/Sources/PocketClient/Session/RecordControl.swift
import Foundation

extension PocketSession {
    /// Starts a recording. The device answers with the ambiguous `MCU&REC&CON`
    /// marker followed by `MCU&STA&<timestamp>`; the timestamp is the file key.
    public func startRecording() async throws -> RecordingID {
        let response = try await request(.startRecording) {
            if case .recordingStarted = $0 { true } else { false }
        }
        guard case .recordingStarted(let ts) = response else {
            throw PocketError.unexpectedResponse("expected MCU&STA&<ts>")
        }
        return RecordingID(date: PocketSession.dateDirectory(fromTimestamp: ts), timestamp: ts)
    }

    public func stopRecording() async throws {
        _ = try await request(.stopRecording) { $0 == .recordingStopped }
    }

    // Pause/resume are deliberately absent. `APP&PAU` and `APP&RESU` exist in
    // the official app's string table but were probed against firmware 1.7 on
    // 2026-07-25 and both answered `MCU&UNKNOWN` — this device does not
    // implement them. Shipping methods that always throw would be worse than
    // not offering them. To stop a recording, use `stopRecording()`.

    /// A live audio tap keeps ~2 seconds of 32 kbps audio in ~244-byte BLE
    /// notification chunks. Stale frames are worthless — a stalled consumer
    /// should lose old audio, not accumulate an unbounded backlog.
    static let liveAudioBufferedChunks = 32

    /// MP3 frames streamed by the device while a recording is active.
    ///
    /// The device uses the same bulk channel as file transfers, so the live
    /// stream claims the exclusive transfer slot: starting it during a
    /// download throws `PocketError.busy`, and a download attempted while the
    /// stream is live fails the same way instead of clobbering the sink.
    /// The slot and sink are released when the stream terminates: consumer
    /// side (task cancelled, stream dropped) or session side (`stop()`,
    /// link loss — the stream finishes so `for await` ends promptly).
    ///
    /// On buffer overflow, drops occur at BLE-chunk granularity, not
    /// MP3-frame granularity, so a drop splices the bitstream mid-frame — a
    /// decoder resyncs at the next frame header with an audible glitch,
    /// rather than merely skipping old audio. Drops are not observable by
    /// the consumer; a lossless copy comes from downloading the file
    /// afterwards, not from this tap.
    public func liveAudio() throws -> AsyncStream<Data> {
        guard isAuthenticated else { throw PocketError.notAuthenticated }
        try beginTransfer()
        liveStreamGeneration += 1
        let generation = liveStreamGeneration
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.liveAudioBufferedChunks))
        liveContinuation = continuation
        // Consumer-side termination fires off-actor; hop back so the release
        // is atomic with respect to any download claiming the slot. Until it
        // runs the slot stays held, so no claimant races the sink teardown.
        // The generation check makes a hop that lands after stop()/disconnect
        // already tore this stream down — and a new one started — a no-op.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.finishLiveStream(ifCurrent: generation) }
        }
        // No suspension between the claim above and the install, so the pair
        // is atomic — same contract as downloadOverBLE.
        setBulkSink { continuation.yield($0) }
        return stream
    }

    /// Funnel for the off-actor termination hop; stale generations no-op.
    func finishLiveStream(ifCurrent generation: Int) {
        guard generation == liveStreamGeneration else { return }
        teardownLiveStream()
    }

    /// The single release point for a live stream: finishes it (unblocking a
    /// consumer awaiting the next frame) and restores the bulk channel, all
    /// in one synchronous actor call. Idempotent — the cleared continuation
    /// guards re-entry, so the termination hop, `stop()`, and disconnect can
    /// each call it and exactly one release happens.
    func teardownLiveStream() {
        guard let continuation = liveContinuation else { return }
        liveContinuation = nil
        liveTeardownCount += 1   // witness: a real release, not a no-op entry
        continuation.finish()
        releaseBulkChannel()
    }

    /// Restores the bulk channel after a live stream ends.
    private func releaseBulkChannel() {
        setBulkSink(nil)
        endTransfer()
    }
}
