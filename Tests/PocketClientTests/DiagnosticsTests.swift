// pocket-client/Tests/PocketClientTests/DiagnosticsTests.swift
//
// Field diagnostics (hardware run 2026-07-24): the device answered APP&WIFIS
// in a shape the client did not script, and the session dropped the frame —
// indistinguishable from silence. These tests pin the fix: every frame that
// matches nothing surfaces as `.unmatchedResponse` (verbatim), and the
// `pocket-cli raw` probe can only ever emit frames from a fixed allowlist.
import Foundation
import Testing
@testable import PocketClient

// MARK: - Unmatched responses surface as events

/// The exact field failure: no request in flight, the device sends a frame
/// the parser understands (`MCU&WIFIS&0`) but nothing is armed to match —
/// it must surface verbatim instead of vanishing.
@Test func unsolicitedParsedFrameSurfacesAsUnmatchedEvent() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    t.emitResponse("MCU&WIFIS&0")

    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .unmatchedResponse("MCU&WIFIS&0"))
    await session.stop()
}

/// Frames the parser cannot classify (`.unparsed`) must keep their raw text
/// verbatim — they are precisely the evidence a protocol postmortem needs.
@Test func unparsedFrameSurfacesVerbatim() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    t.emitResponse("WIFI_READY:192.168.200.1")   // not MCU&-prefixed at all

    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .unmatchedResponse("WIFI_READY:192.168.200.1"))
    await session.stop()
}

/// Only line-framing whitespace is stripped; the frame text itself is intact.
@Test func unmatchedEventTrimsOnlyFramingWhitespace() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    t.emitResponse("MCU&WIFIS&3\r\n")

    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .unmatchedResponse("MCU&WIFIS&3"))
    await session.stop()
}

/// Observation only: a non-matching frame arriving while a request is armed
/// surfaces as an event AND the request still completes with its real answer
/// — surfacing must not consume, redirect, or fail anything.
@Test func unmatchedFrameDuringArmedRequestIsObservedWithoutDisturbingIt() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&WIFIS&0", "MCU&BAT&64"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let response = try await session.request(.battery) {
        if case .battery = $0 { true } else { false }
    }

    #expect(response == .battery(64))
    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .unmatchedResponse("MCU&WIFIS&0"))
    await session.stop()
}

/// Same guarantee on the collecting (terminator) path: a stray frame inside
/// a list surfaces as an event and never pollutes the collected elements.
@Test func unmatchedFrameDuringCollectingRequestIsObservedWithoutPollutingIt() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-04", "MCU&WIFIS&0", "MCU&DIRS_SUM&1"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let dates = try await session.listDates()

    #expect(dates == ["2026-01-04"])
    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .unmatchedResponse("MCU&WIFIS&0"))
    await session.stop()
}

/// The two known unsolicited shapes keep their structured events — the
/// unmatched fallback must not swallow them.
@Test func knownUnsolicitedShapesStillMapToStructuredEvents() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    t.emitResponse("MCU&STA&20260105120000")
    t.emitResponse("MCU&RT&20260105115900&65")

    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() ==
            .recordingStarted(RecordingID(date: "2026-01-05", timestamp: "20260105120000")))
    #expect(await iterator.next() == .recordingInProgress(since: "20260105115900", elapsedSeconds: 65))
    await session.stop()
}

// MARK: - RawProbe allowlist

/// The complete verb → frame table, pinned frame by frame: `raw` can emit
/// these thirteen byte sequences and nothing else.
@Test func rawProbeMapsEveryAllowlistedVerbToItsFixedFrame() {
    let expected: [String: String] = [
        "WIFIS":     "APP&WIFIS",
        "WIFI":      "APP&WIFI",
        "SHUT":      "APP&SHUT",
        "WIFIC":     "APP&WIFIC",
        "WPING":     "APP&WPING",
        "BAT":       "APP&BAT",
        "FW":        "APP&FW",
        "MAC":       "APP&MAC",
        "WF":        "APP&WF",
        "SPACE":     "APP&SPACE",
        "STE":       "APP&STE",
        "REC&SECEN": "APP&REC&SECEN",
        "LIST_DIRS": "APP&LIST_DIRS",
    ]
    #expect(Set(RawProbe.allowedVerbs) == Set(expected.keys))
    for (verb, frame) in expected {
        #expect(RawProbe.command(forVerb: verb)?.wireFormat == frame)
    }
}

@Test func rawProbeVerbsAreCaseInsensitive() {
    #expect(RawProbe.command(forVerb: "wifis") == .wifiStatus)
    #expect(RawProbe.command(forVerb: "rec&secen") == .sliderQuery)
}

/// Everything outside the table is refused — including every destructive or
/// state-changing family the safety rail exists for.
@Test func rawProbeRejectsForbiddenAndUnknownVerbs() {
    let forbidden = [
        "OTA", "WOTA", "OTA&GO",                       // firmware flashing
        "BLE", "BLE&NAME&X",                           // rebinding
        "WIFI&CH", "WIFI&CH&6",                        // WiFi provisioning
        "WIFI&SWITCH", "WIFID",                        // WiFi mode games
        "WIFIO",                                       // AP start — state-changing, not a probe
        "PING",                                        // not a real command (no capture shows it)
        "SK", "SK&0123456789ABCDEF",                   // re-auth / key games
        "T&20260105000000",                            // clock writes
        "D&2026-01-04&20260104100000",                 // deletion
        "U&WIFI", "U&2026-01-04&20260104100000",       // transfer staging
        "STA", "STO",                                  // recording control is not a probe
        "", "&", "WIFIS&EXTRA", "APP&WIFIS", "MCU&WIFIS",
    ]
    for verb in forbidden {
        #expect(RawProbe.command(forVerb: verb) == nil, "'\(verb)' must be refused")
    }
}

/// The allowlisted `WIFI` probe is the bare credentials query and can never
/// leak into the forbidden provisioning family that shares its prefix.
@Test func rawProbeWiFiVerbIsTheBareCredentialsQuery() {
    #expect(RawProbe.command(forVerb: "WIFI") == .wifiCredentials)
    #expect(RawProbe.command(forVerb: "WIFI")?.wireFormat == "APP&WIFI")
    #expect(RawProbe.command(forVerb: "WIFI&CH&myssid&mypsk") == nil)
}
