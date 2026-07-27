// pocket-client/Tests/PocketClientTests/Support/FakeTransport.swift
import Foundation
@testable import PocketClient

/// Replays capture-derived transcripts. Scripted replies fire synchronously
/// on `send`, so tests are deterministic without sleeps.
final class FakeTransport: PocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: AsyncStream<Data>
    private let responseContinuation: AsyncStream<Data>.Continuation
    private let bulk: AsyncStream<Data>
    private let bulkContinuation: AsyncStream<Data>.Continuation

    /// Wire-format command → responses emitted when it is sent.
    var script: [String: [String]] = [:]
    /// Called after each send, for tests that need to drive bulk data or delays.
    var onSend: (@Sendable (String, FakeTransport) -> Void)?
    /// When set, `send` records the command, then throws this instead of replying.
    /// Read *after* `beforeSendCompletes`, so a gated test can dictate a
    /// suspended send's outcome while it hangs.
    var sendError: Error?
    /// Async gate awaited inside `send` after the command is recorded and
    /// before the outcome is decided — lets a test hold a send suspended
    /// across a timeout and release it late.
    var beforeSendCompletes: (@Sendable () async -> Void)?
    /// Lock-guarded snapshots: the session's keepalive task appends to the
    /// send log concurrently with test-side reads, so raw storage access
    /// would race. Tests read these accessors; only `send`/`disconnect`
    /// write the storage (under the same lock).
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    var didDisconnect: Bool { lock.lock(); defer { lock.unlock() }; return _didDisconnect }
    private var _sent: [String] = []
    private var _didDisconnect = false

    init() {
        (responses, responseContinuation) = AsyncStream<Data>.makeStream()
        (bulk, bulkContinuation) = AsyncStream<Data>.makeStream()
    }

    func send(_ data: Data) async throws {
        let wire = String(decoding: data, as: UTF8.self)
        let (replies, gate) = recordSend(wire)
        if let gate { await gate() }
        if let failure = currentSendError() { throw failure }
        for reply in replies { responseContinuation.yield(Data(reply.utf8)) }
        onSend?(wire, self)
    }

    private func recordSend(_ wire: String) -> ([String], (@Sendable () async -> Void)?) {
        lock.lock()
        _sent.append(wire)
        let replies = script[wire] ?? []
        let gate = beforeSendCompletes
        lock.unlock()
        return (replies, gate)
    }

    private func currentSendError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return sendError
    }

    func responseStream() -> AsyncStream<Data> { responses }
    func bulkStream() -> AsyncStream<Data> { bulk }

    func emitResponse(_ text: String) { responseContinuation.yield(Data(text.utf8)) }
    func emitBulk(_ data: Data) { bulkContinuation.yield(data) }
    func finish() {
        responseContinuation.finish()
        bulkContinuation.finish()
    }

    func disconnect() async {
        markDisconnected()
        finish()
    }

    private func markDisconnected() {
        lock.lock(); _didDisconnect = true; lock.unlock()
    }

    /// Emits `data` the way the device does: ~244-byte notifications, short final chunk.
    /// Iterates from `startIndex`, so Data slices (e.g. `dropFirst`) are safe to pass.
    func emitBulkChunked(_ data: Data, chunkSize: Int = 244) {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunkSize, data.endIndex)
            emitBulk(data.subdata(in: offset..<end))
            offset = end
        }
    }

    /// A synthetic stand-in for a device recording: a 300→2500 Hz sine sweep
    /// encoded exactly as the hardware encodes — MPEG-2 Layer III, 32 kbps,
    /// 16 kHz, mono, raw elementary stream with no ID3 or Xing header, so it
    /// begins with the `FF F3` sync word the transfer path validates.
    ///
    /// It is deliberately NOT a real recording. Nothing about the download,
    /// chunking, or integrity paths cares what the audio contains, and a
    /// fixture that is somebody's voice is a fixture that cannot be published.
    static func loadGoldenFixture() throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/golden", withExtension: "mp3")
        guard let url else { throw PocketError.transferFailed("golden.mp3 fixture missing") }
        return try Data(contentsOf: url)
    }

    /// The fixture's byte count, read from the fixture itself.
    ///
    /// Every scripted `MCU&U&<size>` announcement and every size assertion in
    /// the suite derives from this rather than repeating a literal. That is
    /// the point: swapping `Fixtures/golden.mp3` for a different payload
    /// requires no test edits and cannot leave a stale magic number behind to
    /// drift against the real file.
    static let goldenSize: Int = {
        guard let data = try? loadGoldenFixture() else {
            fatalError("golden.mp3 fixture missing or unreadable")
        }
        return data.count
    }()
}
