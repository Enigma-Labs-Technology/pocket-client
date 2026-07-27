// pocket-client/Tests/PocketClientTests/DeviceTests.swift
import Foundation
import Testing
@testable import PocketClient

@Test func deviceExposesTheFullFlowOverAFakeTransport() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-04", "MCU&DIRS_SUM&1"]
    t.script["APP&LIST&2026-01-04"] = ["MCU&F&2026-01-04&20260104101500&3", "MCU&LIST&1"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    t.script["APP&D&2026-01-04&20260104101500"] = ["MCU&D"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
        transport.emitResponse("MCU&OFF")
    }

    let device = PocketDevice(transport: t, sessionKey: "ExampleKey000000")
    try await device.connect()

    let dates = try await device.listDates()
    #expect(dates == ["2026-01-04"])

    let recordings = try await device.listRecordings(on: "2026-01-04")
    #expect(recordings.count == 1)

    let data = try await device.download(recordings[0], via: .ble)
    #expect(data == golden)

    try await device.delete(recordings[0].id)
    #expect(t.sent.contains("APP&D&2026-01-04&20260104101500"))

    await device.disconnect()
}

@Test func autoModeChoosesBLEForShortRecordings() {
    let short = RecordingInfo(id: RecordingID(date: "d", timestamp: "t"), durationSeconds: 60)
    let long = RecordingInfo(id: RecordingID(date: "d", timestamp: "t"), durationSeconds: 600)
    #expect(short.estimatedBytes == 240_000)
    #expect(TransferMode.resolve(.auto, for: short) == .ble)
    #expect(TransferMode.resolve(.auto, for: long) == .wifi)
    #expect(TransferMode.resolve(.ble, for: long) == .ble)
    #expect(TransferMode.resolve(.wifi, for: short) == .wifi)
}

/// A failed `connect()` must tear the session down, not just mark the façade
/// closed: the transport link is dropped and `events` finishes, so nobody
/// hangs iterating events of a device that never came up. (Task 8 review.)
@Test func failedConnectTearsDownSessionAndFinishesEvents() async throws {
    let t = FakeTransport()
    t.script["APP&SK&BAD"] = ["MCU&SK&ERR"]
    let device = PocketDevice(transport: t, sessionKey: "BAD")

    await #expect(throws: PocketError.authRejected) { try await device.connect() }

    #expect(t.didDisconnect)
    let clock = ContinuousClock()
    let began = clock.now
    for await _ in device.events { }   // must complete promptly, not hang
    #expect(clock.now - began < .seconds(1))

    // The instance is spent, exactly like after a disconnect().
    await #expect(throws: PocketError.disconnected) { try await device.connect() }
}

/// A second `connect()` inside the handshake window must be refused at the
/// façade without touching the session: a second `start()` would spawn a
/// second consume loop on the same single-consumer response stream and split
/// its payloads arbitrarily between the two. (Task 8 review.)
@Test func concurrentConnectDuringHandshakeIsRefusedBusy() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let handshakeEntered = AsyncGate()
    let releaseHandshake = AsyncGate()
    t.beforeSendCompletes = { handshakeEntered.open(); await releaseHandshake.wait() }
    let device = PocketDevice(transport: t, sessionKey: "K")

    let first = Task { try await device.connect() }
    await handshakeEntered.wait()   // first connect is mid-handshake

    await #expect(throws: PocketError.busy("connect already in progress")) {
        try await device.connect()
    }

    t.beforeSendCompletes = nil
    releaseHandshake.open()
    try await first.value           // the first connect completes normally
    #expect(t.sent.filter { $0 == "APP&SK&K" }.count == 1)
    await device.disconnect()
}

/// Lifecycle decision (Task 7 review obligation): `PocketDevice` is
/// single-use. `disconnect()` finishes the transport's single-consumer
/// streams, so a reused session's consume loop is dead — rather than
/// silently half-working, reconnection through the same instance is
/// rejected loudly and callers construct a fresh transport + device.
@Test func deviceIsSingleUseAfterDisconnect() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let device = PocketDevice(transport: t, sessionKey: "K")
    try await device.connect()

    // Connecting an already-connected device is refused, not re-handshaken.
    await #expect(throws: PocketError.busy("already connected")) {
        try await device.connect()
    }

    await device.disconnect()
    await device.disconnect()   // idempotent

    // The streams are finished; a reconnection could never authenticate.
    await #expect(throws: PocketError.disconnected) {
        try await device.connect()
    }
}
