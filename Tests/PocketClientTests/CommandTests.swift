import Foundation
import Testing
@testable import PocketClient

@Test func encodesAuth() {
    #expect(Command.auth("ExampleKey000000").wireFormat == "APP&SK&ExampleKey000000")
}

@Test func encodesSimpleQueries() {
    #expect(Command.battery.wireFormat == "APP&BAT")
    #expect(Command.firmware.wireFormat == "APP&FW")
    #expect(Command.macAddress.wireFormat == "APP&MAC")
    #expect(Command.wifiFirmware.wireFormat == "APP&WF")
    #expect(Command.storage.wireFormat == "APP&SPACE")
    #expect(Command.sliderQuery.wireFormat == "APP&REC&SECEN")
    #expect(Command.recordingState.wireFormat == "APP&STE")
    #expect(Command.listDates.wireFormat == "APP&LIST_DIRS")
}

@Test func encodesRecordControl() {
    #expect(Command.startRecording.wireFormat == "APP&STA")
    #expect(Command.stopRecording.wireFormat == "APP&STO")
    #expect(Command.pauseRecording.wireFormat == "APP&PAU")
    #expect(Command.resumeRecording.wireFormat == "APP&RESU")
}

@Test func encodesRecordingOperations() {
    let id = RecordingID(date: "2026-01-04", timestamp: "20260104101500")
    #expect(Command.listRecordings(date: "2026-01-04").wireFormat == "APP&LIST&2026-01-04")
    #expect(Command.download(id).wireFormat == "APP&U&2026-01-04&20260104101500")
    #expect(Command.delete(id).wireFormat == "APP&D&2026-01-04&20260104101500")
}

@Test func encodesWiFiCommands() {
    #expect(Command.wifiShutdown.wireFormat == "APP&SHUT")
    #expect(Command.wifiStatus.wireFormat == "APP&WIFIS")
    #expect(Command.wifiCredentials.wireFormat == "APP&WIFI")
    #expect(Command.wifiAccessPointOn.wireFormat == "APP&WIFIO")
    #expect(Command.wifiKeepalive.wireFormat == "APP&WPING")
    #expect(Command.wifiDownload.wireFormat == "APP&U&WIFI")
    #expect(Command.wifiClose.wireFormat == "APP&WIFIC")
}

/// The credentials query is exactly `APP&WIFI` — it must never grow arguments,
/// because `APP&WIFI&CH&<ssid>&<psk>` (forbidden provisioning) differs from it
/// only by what follows the shared prefix.
@Test func wifiCredentialsQueryCarriesNoArguments() {
    let wire = Command.wifiCredentials.wireFormat
    #expect(wire == "APP&WIFI")
    #expect(!wire.contains("CH"))
    #expect(wire.components(separatedBy: "&").count == 2)
}

@Test func encodesClockInUTC() {
    #expect(Command.setClock(Date(timeIntervalSince1970: 0)).wireFormat == "APP&T&19700101000000")
    // 2026-01-04T10:15:00Z
    #expect(Command.setClock(Date(timeIntervalSince1970: 1_767_521_700)).wireFormat
            == "APP&T&20260104101500")
}

@Test func encodedIsUTF8OfWireFormat() {
    let c = Command.battery
    #expect(c.encoded == Data("APP&BAT".utf8))
}

/// Safety rail: destructive commands must be unrepresentable.
///
/// The command list is compiler-enforced, not manually maintained:
/// `next(after:)` switches over `Command` with NO default, so a new case
/// refuses to compile until it is spliced into the walk — which routes it
/// through these assertions. (A hand-kept array would let a new case escape
/// the rail silently.)
@Test func noDestructiveCommandsExist() {
    var visited: [Command] = []
    var current: Command? = firstCommandInWalk
    while let command = current {
        visited.append(command)
        current = next(after: command)
    }
    // Exact, not a floor: the `next(after:)` switch forces a new case to be
    // *mentioned*, but only reaching it via the chain runs the assertions
    // below. An exact count also fails if a future edit orphans a branch,
    // splicing a case out of the walk while leaving it compiling.
    #expect(visited.count == 24)   // every case in Command.swift, walked once
    for command in visited {
        let wire = command.wireFormat
        #expect(!wire.contains("OTA"))
        #expect(!wire.contains("WOTA"))
        #expect(!wire.contains("BLE&RESET"))
        #expect(!wire.contains("WIFI&CH"))
        // The provisioning/mode-switch family is `APP&WIFI&…`; the safe
        // credentials query is bare `APP&WIFI`. No representable command may
        // ever extend that prefix.
        #expect(!wire.hasPrefix("APP&WIFI&"))
    }
}

/// The device-wipe frame must stay unrepresentable as a `Command`. The CLI's
/// `reset` builds it as raw bytes at its single call site precisely so the
/// typed API cannot produce it — but `PocketTransport.send(Data)` is public,
/// so the type system alone cannot make the frame unsendable by linking code.
/// This rail (over the same compiler-forced exhaustive walk as
/// `noDestructiveCommandsExist`) plus the single CLI call site IS the
/// guarantee; state it no more strongly than that.
@Test func deviceResetFrameIsNotRepresentableAsACommand() {
    let wipeFrame = "APP&BLE&RESET"
    var current: Command? = firstCommandInWalk
    while let command = current {
        #expect(command.wireFormat != wipeFrame)
        #expect(command.encoded != Data(wipeFrame.utf8))
        current = next(after: command)
    }
}

private let firstCommandInWalk = Command.auth("k")

/// One representative per `Command` case, chained: each case names its
/// successor, the last returns nil. No `default`, so the compiler rejects a
/// new `Command` case until it joins the walk — the mechanism that keeps
/// `noDestructiveCommandsExist` exhaustive as the enum grows.
private func next(after command: Command) -> Command? {
    switch command {
    case .auth:            .battery
    case .battery:         .firmware
    case .firmware:        .macAddress
    case .macAddress:      .wifiFirmware
    case .wifiFirmware:    .storage
    case .storage:         .setClock(Date(timeIntervalSince1970: 0))
    case .setClock:        .sliderQuery
    case .sliderQuery:     .recordingState
    case .recordingState:  .startRecording
    case .startRecording:  .stopRecording
    case .stopRecording:   .pauseRecording
    case .pauseRecording:  .resumeRecording
    case .resumeRecording: .listDates
    case .listDates:       .listRecordings(date: "2026-01-04")
    case .listRecordings:  .download(RecordingID(date: "d", timestamp: "t"))
    case .download:        .delete(RecordingID(date: "d", timestamp: "t"))
    case .delete:          .wifiShutdown
    case .wifiShutdown:    .wifiStatus
    case .wifiStatus:      .wifiCredentials
    case .wifiCredentials: .wifiAccessPointOn
    case .wifiAccessPointOn: .wifiKeepalive
    case .wifiKeepalive:   .wifiDownload
    case .wifiDownload:    .wifiClose
    case .wifiClose:       nil
    }
}
