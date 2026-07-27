import Foundation
import Testing
@testable import PocketClient

@Test func parsesAuthResults() {
    #expect(Response.parse("MCU&SK&OK") == .authOK)
    #expect(Response.parse("MCU&SK&ERR") == .authError)
}

@Test func parsesStatusResponses() {
    #expect(Response.parse("MCU&BAT&100") == .battery(100))
    #expect(Response.parse("MCU&FW&1.7") == .firmware("1.7"))
    #expect(Response.parse("MCU&MAC&00005e005300") == .macAddress("00005e005300"))
    #expect(Response.parse("MCU&WF&V9") == .wifiFirmware("V9"))
    #expect(Response.parse("MCU&WF&ec9") == .wifiFirmware("ec9"))
    #expect(Response.parse("MCU&SPA&059632&059636") == .storage(StorageInfo(freeMB: 59632, totalMB: 59636)))
    #expect(Response.parse("MCU&T&OK") == .clockSet)
    #expect(Response.parse("MCU&STE&0") == .recordingState(false))
    #expect(Response.parse("MCU&STE&1") == .recordingState(true))
}

@Test func parsesSliderPositions() {
    #expect(Response.parse("MCU&REC&CON") == .sliderPosition(.conversation))
    #expect(Response.parse("MCU&REC&CALL") == .sliderPosition(.call))
}

@Test func parsesRecordingEvents() {
    #expect(Response.parse("MCU&STA&20260104101500") == .recordingStarted("20260104101500"))
    #expect(Response.parse("MCU&STO") == .recordingStopped)
    #expect(Response.parse("MCU&RT&20260104101500&42")
            == .recordingInProgress(since: "20260104101500", elapsedSeconds: 42))
}

@Test func parsesInventoryResponses() {
    #expect(Response.parse("MCU&DIRS&2026-01-04") == .dateEntry("2026-01-04"))
    #expect(Response.parse("MCU&DIRS_SUM&3") == .dateSummary(count: 3))
    let expected = RecordingInfo(
        id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
        durationSeconds: 3)
    #expect(Response.parse("MCU&F&2026-01-04&20260104101500&3") == .fileEntry(expected))
    #expect(Response.parse("MCU&LIST&12") == .listSummary(count: 12))
}

@Test func parsesTransferResponses() {
    // An arbitrary size — this is a pure parser test with no tie to the
    // golden fixture (it previously reused the fixture's byte count, which
    // read as a coupling that never existed).
    #expect(Response.parse("MCU&U&12345") == .transferSize(12345))
    #expect(Response.parse("MCU&OFF") == .transferComplete)
    #expect(Response.parse("MCU&D") == .deleted)
}

@Test func parsesWiFiResponses() {
    #expect(Response.parse("MCU&WIFI&PKT01_EXAMPLE&ExampleK")
            == .wifiCredentials(ssid: "PKT01_EXAMPLE", passphrase: "ExampleK"))
    #expect(Response.parse("MCU&WIFIS&0") == .wifiState(.off))
    #expect(Response.parse("MCU&WIFIS&3") == .wifiState(.accessPointUp))
    #expect(Response.parse("MCU&WIFIS&2") == .wifiState(.clientJoined))
    // Capture-verified: state 1 means the TCP client is connected on :8475,
    // not "transferring" — it is reported before any upload command.
    #expect(Response.parse("MCU&WIFIS&1") == .wifiState(.tcpConnected))
    #expect(Response.parse("MCU&WPING") == .pong)
    #expect(Response.parse("MCU&SHUT") == .shutdownAck)
    #expect(Response.parse("MCU&WIFIO") == .wifiAccessPointOn)
    #expect(Response.parse("MCU&WIFIC") == .wifiClosed)
    // MCU&U&WIFI (ack for the APP&U&WIFI reroute) must not collide with the
    // MCU&U&<size> announcement — WIFI is not a size.
    #expect(Response.parse("MCU&U&WIFI") == .wifiUploadAck)
    #expect(Response.parse("MCU&U&1492892") == .transferSize(1_492_892))
}

@Test func parsesUnknownAndUnparsed() {
    #expect(Response.parse("MCU&UNKNOWN") == .unknown)
    #expect(Response.parse("MCU&WAT&99") == .unparsed("MCU&WAT&99"))
    #expect(Response.parse("garbage") == .unparsed("garbage"))
}

@Test func parsesFromDataAndTrimsWhitespace() {
    #expect(Response.parse(Data("MCU&BAT&87\r\n".utf8)) == .battery(87))
}

@Test func malformedNumericFieldsBecomeUnparsed() {
    #expect(Response.parse("MCU&BAT&abc") == .unparsed("MCU&BAT&abc"))
    #expect(Response.parse("MCU&U&") == .unparsed("MCU&U&"))
}
