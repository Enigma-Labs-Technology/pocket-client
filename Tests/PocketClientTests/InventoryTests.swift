// pocket-client/Tests/PocketClientTests/InventoryTests.swift
import Foundation
import Testing
@testable import PocketClient

private func authedSession(_ t: FakeTransport) async throws -> PocketSession {
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let s = PocketSession(transport: t, sessionKey: "K")
    try await s.start()
    return s
}

@Test func readsFullDeviceStatus() async throws {
    let t = FakeTransport()
    t.script["APP&BAT"] = ["MCU&BAT&100"]
    t.script["APP&FW"] = ["MCU&FW&1.7"]
    t.script["APP&MAC"] = ["MCU&MAC&00005e005300"]
    t.script["APP&WF"] = ["MCU&WF&V9"]
    t.script["APP&SPACE"] = ["MCU&SPA&059632&059636"]
    t.script["APP&REC&SECEN"] = ["MCU&REC&CON"]
    t.script["APP&STE"] = ["MCU&STE&0"]
    let session = try await authedSession(t)

    let status = try await session.status()

    #expect(status.batteryPercent == 100)
    #expect(status.firmware == "1.7")
    #expect(status.macAddress == "00005e005300")
    #expect(status.wifiFirmware == "V9")
    #expect(status.storage == StorageInfo(freeMB: 59632, totalMB: 59636))
    #expect(status.slider == .conversation)
    #expect(status.isRecording == false)
    await session.stop()
}

/// The narrow poll behind the strip's recording clock: exactly one
/// round-trip, and it is `APP&STE` — the query — never `APP&STA`, which
/// would START a recording on the device it was supposed to be watching.
@Test func isRecordingIsOneRoundTripAndQueriesNotStarts() async throws {
    let t = FakeTransport()
    t.script["APP&STE"] = ["MCU&STE&1"]
    let session = try await authedSession(t)
    let sentBefore = t.sent.count

    #expect(try await session.isRecording() == true)

    #expect(t.sent.suffix(from: sentBefore) == ["APP&STE"])   // one frame, the right one
    #expect(!t.sent.contains("APP&STA"))
    await session.stop()
}

@Test func setsClockInUTC() async throws {
    let t = FakeTransport()
    t.script["APP&T&20260104101500"] = ["MCU&T&OK"]
    let session = try await authedSession(t)

    try await session.setClock(Date(timeIntervalSince1970: 1_767_521_700))   // 2026-01-04T10:15:00Z

    #expect(t.sent.contains("APP&T&20260104101500"))
    await session.stop()
}

@Test func listsDatesAndRecordings() async throws {
    let t = FakeTransport()
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-03", "MCU&DIRS&2026-01-04", "MCU&DIRS_SUM&2"]
    t.script["APP&LIST&2026-01-04"] = [
        "MCU&F&2026-01-04&20260104100000&12",
        "MCU&F&2026-01-04&20260104101500&3",
        "MCU&LIST&2",
    ]
    let session = try await authedSession(t)

    #expect(try await session.listDates() == ["2026-01-03", "2026-01-04"])

    let recordings = try await session.listRecordings(on: "2026-01-04")
    #expect(recordings.count == 2)
    #expect(recordings[1].id.timestamp == "20260104101500")
    #expect(recordings[1].durationSeconds == 3)
    #expect(recordings[1].estimatedBytes == 12000)
    await session.stop()
}

@Test func emptyDayListReturnsNoRecordings() async throws {
    let t = FakeTransport()
    t.script["APP&LIST&2026-01-01"] = ["MCU&LIST&0"]
    let session = try await authedSession(t)

    #expect(try await session.listRecordings(on: "2026-01-01").isEmpty)
    await session.stop()
}

@Test func deleteSendsCommandAndAwaitsAck() async throws {
    let t = FakeTransport()
    let id = RecordingID(date: "2026-01-04", timestamp: "20260104101500")
    t.script["APP&D&2026-01-04&20260104101500"] = ["MCU&D"]
    let session = try await authedSession(t)

    try await session.delete(id)

    #expect(t.sent.contains("APP&D&2026-01-04&20260104101500"))
    await session.stop()
}
