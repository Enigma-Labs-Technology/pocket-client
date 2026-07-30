// pocket-client/Tests/PocketClientTests/DownloadTests.swift
import Foundation
import Testing
@testable import PocketClient

private let recording = RecordingInfo(
    id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
    durationSeconds: 3)

@Test func downloadsGoldenRecordingByteIdentically() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
        transport.emitResponse("MCU&OFF")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverBLE(recording)

    #expect(data == golden)
    #expect(data.count == FakeTransport.goldenSize)
    await session.stop()
}

/// The device's response and data channels are separate characteristics with no
/// ordering guarantee: MCU&OFF can land before the tail of the file.
@Test func offMarkerArrivingEarlyDoesNotTruncate() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden.prefix(10_000))
        transport.emitResponse("MCU&OFF")            // early
        transport.emitBulkChunked(golden.dropFirst(10_000))
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverBLE(recording)

    #expect(data == golden)
    await session.stop()
}

@Test func truncatedTransferThrowsSizeMismatch() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden.prefix(9_000))
        transport.emitResponse("MCU&OFF")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    await #expect(throws: PocketError.sizeMismatch(expected: FakeTransport.goldenSize, received: 9000)) {
        _ = try await session.downloadOverBLE(recording, idleTimeout: .milliseconds(200))
    }
    await session.stop()
}

@Test func nonMP3PayloadIsRejected() async throws {
    let junk = Data(repeating: 0x41, count: 64)
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&64"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(junk)
        transport.emitResponse("MCU&OFF")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    await #expect(throws: PocketError.notMP3) {
        _ = try await session.downloadOverBLE(recording)
    }
    await session.stop()
}

/// Live hardware holds a 0 s / 0-byte recording. Without a dedicated guard,
/// an announced size of 0 sails through the byte-count check (0 == 0) and
/// dies in the sync-word check as `.notMP3` — which misdiagnoses an empty
/// file as channel corruption. It must fail fast as `.emptyRecording`,
/// before any transfer machinery runs, and release the transfer slot.
@Test func zeroByteRecordingFailsFastAsEmptyRecordingOverBLE() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&0"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    await #expect(throws: PocketError.emptyRecording) {
        _ = try await session.downloadOverBLE(recording)
    }

    // The failure path released the exclusive transfer slot.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

@Test func progressIsMonotonicAndEndsAtOne() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
        transport.emitResponse("MCU&OFF")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let collector = ProgressCollector()
    _ = try await session.downloadOverBLE(recording) { collector.record($0) }

    let values = collector.values
    #expect(!values.isEmpty)
    #expect(values == values.sorted())
    #expect(values.last == 1.0)
    await session.stop()
}

/// A transfer spends most of its life with no request armed, so the session's
/// `.busy` request guard alone cannot protect it — the transfer slot must.
@Test func concurrentDownloadFailsFastWithBusyAndDoesNotDisturbFirst() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    let (transferring, transferringContinuation) = AsyncStream<Void>.makeStream()
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden.prefix(10_000))   // withhold the tail
        transferringContinuation.yield(())
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let first = Task { try await session.downloadOverBLE(recording) }
    var gate = transferring.makeAsyncIterator()
    _ = await gate.next()   // APP&U is on the wire, so the slot is claimed

    await #expect(throws: PocketError.busy("transfer already in progress")) {
        _ = try await session.downloadOverBLE(recording)
    }

    // Release the tail: the first transfer must complete byte-identically,
    // proving the rejected second call never touched its sink or buffer.
    t.emitBulkChunked(golden.dropFirst(10_000))
    let data = try await first.value
    #expect(data == golden)
    await session.stop()
}

/// Cancellation ends the download *itself*, rather than the idle timeout ending
/// it a few seconds later and cancellation merely being what was in the air.
///
/// Proved causally rather than by the stopwatch. This used to read the wall clock
/// and assert the cancel took under a second against a 5 s idle timeout — a
/// measurement of how loaded the machine is as much as of the code. Instead the
/// idle timeout is put ten minutes out of reach: a download that only notices
/// cancellation when it expires cannot finish inside the test's own one-minute
/// limit, so the distinction is made by what happens rather than by how fast.
@Test(.timeLimit(.minutes(1)))
func cancellationFinishesPromptlyAndReleasesTheSession() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    let (transferring, transferringContinuation) = AsyncStream<Void>.makeStream()
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden.prefix(244))   // one chunk, then stall
        transferringContinuation.yield(())
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    // Ten minutes: far past anything this test can wait for, so an idle expiry
    // cannot be what ends the download below.
    let download = Task { try await session.downloadOverBLE(recording,
                                                            idleTimeout: .seconds(600)) }
    var gate = transferring.makeAsyncIterator()
    _ = await gate.next()
    // Give the size response time to unwind so the chunk has landed and the
    // download is inside its transfer phase, not the request phase.
    try await Task.sleep(for: .milliseconds(100))

    download.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await download.value
    }

    // Sink and transfer slot were released: a fresh download succeeds.
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
    }
    let data = try await session.downloadOverBLE(recording)
    #expect(data == golden)
    await session.stop()
}

final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
