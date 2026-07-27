// pocket-client/Tests/PocketClientTests/EventsTests.swift
import Foundation
import Testing
@testable import PocketClient

@Test func startRecordingReturnsTheNewRecordingID() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&STA"] = ["MCU&REC&CON", "MCU&STA&20260105120000"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let id = try await session.startRecording()

    #expect(id == RecordingID(date: "2026-01-05", timestamp: "20260105120000"))
    await session.stop()
}

@Test func stopRecordingAwaitsAcknowledgement() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&STO"] = ["MCU&STO"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    try await session.stopRecording()

    #expect(t.sent.contains("APP&STO"))
    await session.stop()
}

@Test func recordingInProgressAtConnectSurfacesAsEvent() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()
    let events = session.events

    t.emitResponse("MCU&RT&20260105115900&65")

    var iterator = events.makeAsyncIterator()
    let event = await iterator.next()
    #expect(event == .recordingInProgress(since: "20260105115900", elapsedSeconds: 65))
    await session.stop()
}

/// An `MCU&STO` with no armed waiter (a remote stop's ack landing after its
/// request timed out) surfaces as `.recordingStopped`, not as unmatched
/// noise. NOT the stop-detection path — a device-button stop sends nothing
/// at all; clients poll `APP&STE` for that.
@Test func strayStopAckSurfacesAsRecordingStoppedEvent() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    t.emitResponse("MCU&STO")

    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .recordingStopped)
    await session.stop()
}

@Test func liveAudioYieldsBulkFramesWhileRecording() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let stream = try await session.liveAudio()
    t.emitBulk(Data([0xFF, 0xF3, 0x48, 0xC4]))
    t.emitBulk(Data([0x01, 0x02]))

    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    #expect(first == Data([0xFF, 0xF3, 0x48, 0xC4]))
    #expect(second == Data([0x01, 0x02]))
    await session.stop()
}

/// Link loss must FINISH the events stream, not just yield `.disconnected`:
/// a consumer iterating `for await` (that never calls `disconnect()` itself)
/// has to see the final event and then terminate, instead of blocking
/// forever on a stream nobody will ever feed again.
@Test func linkLossFinishesTheEventsStreamAfterDeliveringDisconnected() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let consumer = Task { () -> [DeviceEvent] in
        var seen: [DeviceEvent] = []
        for await event in session.events { seen.append(event) }
        return seen
    }

    let clock = ContinuousClock()
    let began = clock.now
    t.emitResponse("MCU&WIFIS&0")   // one genuine event before the drop
    t.finish()                      // then the BLE link dies

    let events = await consumer.value   // must terminate, not block forever
    #expect(clock.now - began < .seconds(1))
    #expect(events == [.unmatchedResponse("MCU&WIFIS&0"), .disconnected])
    await session.stop()
}

/// The events buffer is bounded at `PocketSession.eventBufferDepth`, keeping
/// the NEWEST events: with no consumer attached, a flood of frames must not
/// grow memory without bound, and what survives is the most recent state —
/// including the final `.disconnected`, which oldest-first dropping can
/// never evict.
@Test func eventsBufferIsBoundedAndKeepsTheNewest() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&BAT&64"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    // No consumer: 100 unmatched frames pile into the buffer.
    for n in 0..<100 { t.emitResponse("MCU&FRAME&\(n)") }
    // Barrier: the response stream is ordered, so once this reply has been
    // handled, every frame above has been handled too.
    _ = try await session.request(.battery) { if case .battery = $0 { true } else { false } }

    t.finish()   // link loss delivers .disconnected (evicting one more) and finishes

    // Deterministic barrier before draining: `handleDisconnect` runs as one
    // synchronous actor job and is the only thing that clears
    // `isAuthenticated` here — once it reads false, the `.disconnected`
    // yield (and its eviction) and the finish have both already happened.
    while await session.isAuthenticated { await Task.yield() }

    let depth = PocketSession.eventBufferDepth
    var seen: [String] = []
    var last: DeviceEvent?
    for await event in session.events {   // terminates because the stream finished
        last = event
        if case .unmatchedResponse(let frame) = event { seen.append(frame) }
    }
    #expect(seen.count == depth - 1)                   // depth minus the .disconnected slot
    #expect(seen.first == "MCU&FRAME&\(100 - (depth - 1))")   // oldest dropped …
    #expect(seen.last == "MCU&FRAME&99")               // … newest kept
    #expect(last == .disconnected)
    await session.stop()
}

// MARK: - Timestamp → date-directory mapping

@Test func dateDirectoryMapsDeviceTimestamps() {
    #expect(PocketSession.dateDirectory(fromTimestamp: "20260104101500") == "2026-01-04")
}

/// Live hardware produced the recording ID "PH260105143000" — IDs are NOT
/// always 14 digits. Prefix arithmetic on such an ID yields a garbage date
/// ("PH26-01-05") that would aim later APP&U/APP&D commands at a directory
/// that does not exist. Anything that is not exactly 14 ASCII digits must
/// pass through verbatim instead.
@Test func dateDirectoryKeepsNonNumericTimestampsVerbatim() {
    #expect(PocketSession.dateDirectory(fromTimestamp: "PH260105143000") == "PH260105143000")
    #expect(PocketSession.dateDirectory(fromTimestamp: "2026010519") == "2026010519")   // 10 digits
    #expect(PocketSession.dateDirectory(fromTimestamp: "") == "")
}

/// End-to-end: a device-initiated recording with a non-standard ID surfaces
/// the raw string, not a fabricated date.
@Test func startRecordingWithNonNumericTimestampKeepsTheRawID() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&STA"] = ["MCU&REC&CON", "MCU&STA&PH260105143000"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let id = try await session.startRecording()

    #expect(id == RecordingID(date: "PH260105143000", timestamp: "PH260105143000"))
    await session.stop()
}

// MARK: - Pause/resume response handling

/// Firmware 1.7 rejects `APP&PAU` with `MCU&UNKNOWN` (probed against the real
/// device 2026-07-25), which is why no `pauseRecording()` API exists. This pins
/// only how the CLIENT surfaces such a reply (`PocketError.unknownCommand`) —
/// the fake always answers `MCU&UNKNOWN`, so no firmware change can ever make
/// this test fail. The re-test signal for future firmware is running
/// `pocket-cli probe-unverified` against real hardware.
@Test func pauseCommandIsRejectedByFirmwareAsUnknown() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&PAU"] = ["MCU&UNKNOWN"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    await #expect(throws: PocketError.unknownCommand(.pauseRecording)) {
        _ = try await session.request(.pauseRecording, timeout: .milliseconds(200)) { _ in true }
    }
    await session.stop()
}

// MARK: - Bulk-channel exclusion

private let recording = RecordingInfo(
    id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
    durationSeconds: 3)

/// Live audio rides the same bulk channel as file transfers. Starting a live
/// stream mid-download must fail fast and leave the download's sink untouched.
@Test func liveAudioDuringDownloadFailsBusyWithoutDisturbingIt() async throws {
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

    let download = Task { try await session.downloadOverBLE(recording) }
    var gate = transferring.makeAsyncIterator()
    _ = await gate.next()   // APP&U is on the wire, so the slot is claimed

    await #expect(throws: PocketError.busy("transfer already in progress")) {
        _ = try await session.liveAudio()
    }

    // Release the tail: the download completes byte-identically, proving the
    // rejected live stream never installed its sink over the download's.
    t.emitBulkChunked(golden.dropFirst(10_000))
    let data = try await download.value
    #expect(data == golden)
    await session.stop()
}

/// The mirror image: a download attempted while a live stream owns the bulk
/// channel must fail fast, and the live stream keeps receiving frames.
@Test func downloadDuringLiveStreamFailsBusyWithoutDisturbingIt() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let stream = try await session.liveAudio()

    await #expect(throws: PocketError.busy("transfer already in progress")) {
        _ = try await session.downloadOverBLE(recording)
    }
    // The rejected download never sent APP&U and never touched the sink.
    #expect(!t.sent.contains("APP&U&2026-01-04&20260104101500"))

    t.emitBulk(Data([0xAA, 0xBB]))
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == Data([0xAA, 0xBB]))
    await session.stop()
}

/// Terminating the live stream must release the slot and the sink so a
/// subsequent download can run. Consumer-side release rides an off-actor
/// hop; `teardownLiveStream()` is idempotent, so awaiting it afterwards is a
/// deterministic barrier — whichever path won, by the time it returns the
/// slot is free and the download needs no retry.
@Test func endingLiveStreamReleasesTheSlotForDownloads() async throws {
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

    let stream = try await session.liveAudio()
    let consumer = Task { for await _ in stream { } }
    consumer.cancel()   // consumer-side termination schedules the release hop
    _ = await consumer.value

    // The hop alone must perform the release: the teardown witness reaches 1
    // BEFORE the explicit barrier below runs. Deleting the onTermination
    // assignment makes this assertion fail — the hop is load-bearing.
    var hopReleased = false
    for _ in 0..<200 where !hopReleased {
        hopReleased = await session.liveTeardownCount == 1
        await Task.yield()
    }
    #expect(hopReleased)

    await session.teardownLiveStream()   // deterministic barrier (idempotent)
    #expect(await session.liveTeardownCount == 1)   // barrier was a no-op

    let data = try await session.downloadOverBLE(recording)
    #expect(data == golden)
    await session.stop()
}

/// `stop()` must finish an active live stream — a consumer blocked in
/// `for await` ends promptly instead of hanging — and must not leave the
/// dead stream's slot claimed.
@Test func stopFinishesLiveStreamAndReleasesTheSlot() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let stream = try await session.liveAudio()
    let consumer = Task { for await _ in stream { } }

    let clock = ContinuousClock()
    let began = clock.now
    await session.stop()
    _ = await consumer.value   // must complete, not hang on the dead link
    #expect(clock.now - began < .seconds(1))   // well under any timeout

    // Post-stop callers are told the session is over, not handed a dead stream.
    await #expect(throws: PocketError.notAuthenticated) {
        _ = try await session.liveAudio()
    }
    // Direct proof the slot was released rather than left claimed (the auth
    // guard runs first, so the error above alone would not distinguish).
    try await session.beginTransfer()
    await session.endTransfer()
}

/// Link loss (both transport streams end, the `handleDisconnect` path) gives
/// the same guarantee: the consumer's loop terminates promptly and the slot
/// is released rather than left claimed by the dead stream.
@Test func linkLossFinishesLiveStreamAndReleasesTheSlot() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let stream = try await session.liveAudio()
    let consumer = Task { for await _ in stream { } }

    let clock = ContinuousClock()
    let began = clock.now
    t.finish()   // BLE link drops: both characteristic streams end
    _ = await consumer.value   // must complete, not hang on the dead link
    #expect(clock.now - began < .seconds(1))   // well under any timeout

    // notAuthenticated, not .busy: the disconnect tore the session down.
    await #expect(throws: PocketError.notAuthenticated) {
        _ = try await session.liveAudio()
    }
    // Direct proof the slot was released rather than left claimed (the auth
    // guard runs first, so the error above alone would not distinguish).
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}
