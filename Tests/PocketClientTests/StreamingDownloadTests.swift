// pocket-client/Tests/PocketClientTests/StreamingDownloadTests.swift
//
// The streaming download API: bytes land in a file as they arrive instead of
// accumulating in `Data`. Every invariant of the in-memory path must hold —
// byte-count-driven completion, announced-count + FF F3 integrity, the
// exclusive transfer slot, prompt cancellation — plus one more: on ANY
// failure, no file may survive at (or near) the destination. A half-written
// file that looks like a recording is worse than no file.
import Foundation
import Network
import Testing
@testable import PocketClient

private let recording = RecordingInfo(
    id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
    durationSeconds: 3)

private let largeRecording = RecordingInfo(
    id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
    durationSeconds: 400)   // ~1.6 MB estimated → `.auto` picks WiFi

/// A fresh directory per test, so "no file left behind" is provable by
/// listing it — leftovers from other tests cannot contaminate the check,
/// and the streaming path's hidden temp companion would be visible here
/// if any failure path ever stranded one.
private func makeScratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("streaming-download-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func contents(of dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path)
}

/// A session whose fake device serves the golden recording over BLE bulk.
private func scriptedBLESession(serving payload: Data,
                                announcing announced: Int) async throws -> (FakeTransport, PocketSession) {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(announced)"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(payload)
        transport.emitResponse("MCU&OFF")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()
    return (t, session)
}

@Test func streamingBLEDownloadWritesTheGoldenFileByteIdentically() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let (_, session) = try await scriptedBLESession(serving: golden, announcing: golden.count)
    let collector = ProgressCollector()
    try await session.downloadOverBLE(recording, to: destination) { collector.record($0) }

    #expect(try Data(contentsOf: destination) == golden)
    // Progress carries the same guarantees as the in-memory path.
    let values = collector.values
    #expect(!values.isEmpty)
    #expect(values == values.sorted())
    #expect(values.last == 1.0)
    // The temp companion was renamed into place, not left beside the file.
    #expect(try contents(of: dir) == ["rec.mp3"])
    await session.stop()
}

@Test func streamingTruncatedTransferThrowsSizeMismatchAndLeavesNoFile() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let (_, session) = try await scriptedBLESession(serving: Data(golden.prefix(9_000)),
                                                    announcing: golden.count)

    await #expect(throws: PocketError.sizeMismatch(expected: golden.count, received: 9_000)) {
        try await session.downloadOverBLE(recording, to: destination,
                                          idleTimeout: .milliseconds(200))
    }
    #expect(try contents(of: dir).isEmpty)   // neither the file nor its temp survived
    await session.stop()
}

@Test func streamingNonMP3PayloadIsRejectedAndLeavesNoFile() async throws {
    let junk = Data(repeating: 0x41, count: 64)
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let (_, session) = try await scriptedBLESession(serving: junk, announcing: junk.count)

    await #expect(throws: PocketError.notMP3) {
        try await session.downloadOverBLE(recording, to: destination)
    }
    #expect(try contents(of: dir).isEmpty)
    await session.stop()
}

/// A failed re-download must not damage what a previous successful download
/// put at the destination: the bytes stream into the temp companion, so the
/// existing file is replaced only after validation passes — never before.
@Test func streamingFailureLeavesAPreexistingDestinationUntouched() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")
    let previous = Data([0xFF, 0xF3, 0x01, 0x02])
    try previous.write(to: destination)

    let (_, session) = try await scriptedBLESession(serving: Data(golden.prefix(9_000)),
                                                    announcing: golden.count)

    await #expect(throws: PocketError.sizeMismatch(expected: golden.count, received: 9_000)) {
        try await session.downloadOverBLE(recording, to: destination,
                                          idleTimeout: .milliseconds(200))
    }
    #expect(try Data(contentsOf: destination) == previous)   // untouched
    #expect(try contents(of: dir) == ["rec.mp3"])            // and no temp beside it
    await session.stop()
}

/// Re-downloading over an existing file replaces it — the same outcome
/// `Data.write(to:)` gave the in-memory consumer — atomically.
@Test func streamingDownloadReplacesAnExistingDestination() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")
    try Data([0x00, 0x01]).write(to: destination)

    let (_, session) = try await scriptedBLESession(serving: golden, announcing: golden.count)
    try await session.downloadOverBLE(recording, to: destination)

    #expect(try Data(contentsOf: destination) == golden)
    #expect(try contents(of: dir) == ["rec.mp3"])
    await session.stop()
}

@Test func streamingCancellationLeavesNoFileAndReleasesTheSlot() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(golden.count)"]
    let (transferring, transferringContinuation) = AsyncStream<Void>.makeStream()
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden.prefix(244))   // one chunk, then stall
        transferringContinuation.yield(())
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let download = Task { try await session.downloadOverBLE(recording, to: destination) }
    var gate = transferring.makeAsyncIterator()
    _ = await gate.next()
    // Give the size response time to unwind so the chunk has landed and the
    // download is inside its transfer phase, not the request phase.
    try await Task.sleep(for: .milliseconds(100))

    let clock = ContinuousClock()
    let cancelled = clock.now
    download.cancel()
    await #expect(throws: CancellationError.self) {
        try await download.value
    }
    // Well under the 5 s idle timeout: cancellation, not idle expiry.
    #expect(clock.now - cancelled < .seconds(1))
    // The partial temp file did not survive the cancellation.
    #expect(try contents(of: dir).isEmpty)

    // Sink and transfer slot were released: a fresh streaming download to the
    // same destination succeeds byte-identically.
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
    }
    try await session.downloadOverBLE(recording, to: destination)
    #expect(try Data(contentsOf: destination) == golden)
    #expect(try contents(of: dir) == ["rec.mp3"])
    await session.stop()
}

// MARK: - WiFi streaming

/// The WiFi streaming path over the loopback TCP server, including the
/// field-observed trailer: surplus bytes past the announced length must be
/// surfaced as a diagnostic and must never reach the file.
@Test func streamingWiFiDownloadKeepsTheTrailerOutOfTheFile() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let trailer = Data("MCU&WIFIC\n".utf8)   // 10 bytes — the field-observed surplus length
    let server = try LoopbackServer(payload: golden + trailer)
    defer { server.stop() }
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    scriptWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    try await session.downloadOverWiFi(recording,
                                       to: destination,
                                       endpointOverride: server.endpoint,
                                       joiner: joiner,
                                       readiness: fastReadiness)

    // Exactly the announced bytes on disk — the trailer stayed off the file.
    #expect(try Data(contentsOf: destination) == golden)
    #expect(try contents(of: dir) == ["rec.mp3"])
    #expect(joiner.box.left == 1)

    // The surplus was surfaced on the event stream, not silently dropped.
    await session.stop()   // finishes the stream so the drain below terminates
    var surfaced: [DeviceEvent] = []
    for await event in session.events {
        if case .wifiTrailerReceived = event { surfaced.append(event) }
    }
    #expect(surfaced == [.wifiTrailerReceived(byteCount: trailer.count, preview: trailer)])
}

@Test func streamingWiFiShortStreamFailsAsSizeMismatchAndLeavesNoFile() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: Data(golden.prefix(9_000)))
    defer { server.stop() }
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    scriptWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    await #expect(throws: PocketError.sizeMismatch(expected: golden.count, received: 9_000)) {
        try await session.downloadOverWiFi(recording,
                                           to: destination,
                                           endpointOverride: server.endpoint,
                                           joiner: joiner,
                                           readiness: fastReadiness)
    }
    #expect(try contents(of: dir).isEmpty)
    #expect(joiner.box.left == 1)   // cleanup ran despite the failure
    // The failure path released the exclusive transfer slot.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

/// The device-level streaming entry point shares the `.auto` routing policy
/// with the in-memory one: a failed WiFi attempt degrades to BLE, and the
/// file still lands validated at the destination.
@Test func streamingAutoModeFallsBackToBLEAndStillWritesTheFile() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("rec.mp3")

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
        transport.emitResponse("MCU&OFF")
    }
    let device = PocketDevice(transport: t, sessionKey: "K",
                              joiner: RecordingJoiner(shouldFail: true))
    try await device.connect()

    try await device.download(largeRecording, to: destination, via: .auto)

    #expect(try Data(contentsOf: destination) == golden)   // WiFi failed, BLE served it
    #expect(try contents(of: dir) == ["rec.mp3"])
    await device.disconnect()
}
