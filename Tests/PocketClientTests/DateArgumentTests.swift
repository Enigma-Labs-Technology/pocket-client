// pocket-client/Tests/PocketClientTests/DateArgumentTests.swift
//
// The 2026-07-28 defect, pinned from both ends.
//
// `pocket-cli sync-wifi 20260728 2` printed "no recordings on 20260728 — nothing
// to sync" against a device holding eight recordings that day: the argument went
// on the wire unchecked, the recorder answered an unrecognised directory with an
// empty listing, and the client reported that as a fact about the device.
//
// So two properties are asserted here, and they are different properties:
//
//   - `RecordingDate.normalize` reads what a person typed, in isolation;
//   - `lookUpRecordings(forDate:)` — the real call site — proves a refused date
//     produces **no frame at all**, by inspecting the transport's send log. That
//     is the assertion that fails if the validation is ever lifted out of the
//     lookup; a pure-function test alone would not notice.
//
// Every date here is synthetic (January 2026), per this tree's convention: no
// real recording timestamps in a public repository.
import Foundation
import Testing
@testable import PocketClient

private func authedSession(_ t: FakeTransport) async throws -> PocketSession {
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let s = PocketSession(transport: t, sessionKey: "K")
    try await s.start()
    return s
}

/// Unwraps a refusal, or fails naming what arrived instead.
private func refusal(_ result: RecordingDate.Normalization,
                     _ input: String) -> String? {
    guard case .refused(let reason) = result else {
        Issue.record("expected '\(input)' to be refused, got \(result)")
        return nil
    }
    return reason
}

// MARK: - Reading the argument

@Test func theDashedFormThatListPrintsIsAcceptedUnchanged() {
    #expect(RecordingDate.normalize("2026-01-04") == .date("2026-01-04"))
    // A quoted shell argument can carry padding; that is not a malformed date.
    #expect(RecordingDate.normalize("  2026-01-04 ") == .date("2026-01-04"))
}

/// The compact form is what a person gets by slicing the date off a recording ID
/// `pocket-cli list` printed, so it is normalised rather than refused — and this
/// is the exact argument that produced the defect.
@Test func theCompactFormIsNormalisedRatherThanRefused() {
    #expect(RecordingDate.normalize("20260104") == .date("2026-01-04"))
    #expect(RecordingDate.normalize("20261231") == .date("2026-12-31"))
}

@Test func aMalformedDateIsRefusedByNameAndCarriesBothFormsThatWork() {
    for input in ["2026-1-4", "2026/01/04", "2026.01.04", "04-01-2026",
                  "yesterday", "202601040", "2026-01-04T10", ""] {
        guard let reason = refusal(RecordingDate.normalize(input), input) else { continue }
        // Echo what was given (except for the empty argument, which has nothing
        // to echo) and name the way out, every time.
        if !input.isEmpty { #expect(reason.contains(input)) }
        #expect(reason.contains("YYYY-MM-DD"))
        #expect(reason.contains("YYYYMMDD"))
        #expect(reason.contains("Nothing was sent to the device"))
    }
}

/// A whole 14-digit recording ID handed over as the date is the likeliest way to
/// get here, so it is answered with the date it visibly contains — not with the
/// grammar.
@Test func aRecordingTimestampPassedAsADateIsNamedAsOneAndSliced() throws {
    let reason = try #require(refusal(RecordingDate.normalize("20260104101500"),
                                      "20260104101500"))
    #expect(reason.contains("recording timestamp"))
    #expect(reason.contains("2026-01-04"))
    #expect(reason.contains("Nothing was sent to the device"))
}

/// Well-formed digits that name a day which does not exist. The device would
/// answer these with the same empty listing as any other unknown directory.
@Test func impossibleCalendarDatesAreRefused() {
    for input in ["2026-02-30", "20260230", "2026-13-01", "20261301",
                  "2026-00-10", "2026-01-00", "2026-01-32", "2026-02-29"] {
        _ = refusal(RecordingDate.normalize(input), input)
    }
    // …and the leap day that does exist is not collateral damage.
    #expect(RecordingDate.normalize("2024-02-29") == .date("2024-02-29"))
    #expect(RecordingDate.normalize("20240229") == .date("2024-02-29"))
}

// MARK: - The real call site

/// **The mutation guard.** Remove the `RecordingDate.normalize` switch from
/// `PocketSession.lookUpRecordings(forDate:)` and this test fails: the malformed
/// date reaches the wire, the scripted `MCU&LIST&0` comes back — exactly what
/// hardware does with a directory it does not recognise — and the run reports an
/// empty device instead of a bad argument.
@Test func aDateTheDeviceCouldNotParseNeverReachesTheRadio() async throws {
    let t = FakeTransport()
    // The device's real behaviour for an unrecognised directory: an empty
    // listing, not an error. Scripted so that a lifted validation fails on the
    // assertion below rather than on a request timeout.
    t.script["APP&LIST&2026-1-4"] = ["MCU&LIST&0"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-04", "MCU&DIRS_SUM&1"]
    let session = try await authedSession(t)

    let lookup = try await session.lookUpRecordings(forDate: "2026-1-4")

    guard case .refused(let reason) = lookup else {
        Issue.record("expected .refused, got \(lookup)")
        await session.stop()
        return
    }
    #expect(reason.contains("2026-1-4"))
    #expect(reason.contains("YYYY-MM-DD"))
    // The whole point: no listing frame of any kind went out.
    #expect(!t.sent.contains { $0.hasPrefix("APP&LIST") })
    await session.stop()
}

/// The reported invocation, end to end: `20260104` now reaches the device as the
/// directory it means, and the day's recordings come back.
@Test func theCompactFormReachesTheDeviceAsTheDashedDirectory() async throws {
    let t = FakeTransport()
    t.script["APP&LIST&2026-01-04"] = [
        "MCU&F&2026-01-04&20260104100000&12",
        "MCU&F&2026-01-04&20260104101500&3",
        "MCU&LIST&2",
    ]
    let session = try await authedSession(t)

    let lookup = try await session.lookUpRecordings(forDate: "20260104")

    guard case .found(let date, let recordings) = lookup else {
        Issue.record("expected .found, got \(lookup)")
        await session.stop()
        return
    }
    #expect(date == "2026-01-04")
    #expect(recordings.map(\.id.timestamp) == ["20260104100000", "20260104101500"])
    #expect(t.sent.contains("APP&LIST&2026-01-04"))
    #expect(!t.sent.contains("APP&LIST&20260104"))
    // A populated day costs exactly one listing round trip: the dates query is
    // for the empty case only.
    #expect(!t.sent.contains("APP&LIST_DIRS"))
    await session.stop()
}

/// "The device has no such date" is not "the device has no recordings", and the
/// device can say which — so it is asked.
@Test func aDateTheDeviceDoesNotHaveIsAnsweredWithTheDatesItDoesHave() async throws {
    let t = FakeTransport()
    t.script["APP&LIST&2026-01-09"] = ["MCU&LIST&0"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-03", "MCU&DIRS&2026-01-04",
                                 "MCU&DIRS_SUM&2"]
    let session = try await authedSession(t)

    let lookup = try await session.lookUpRecordings(forDate: "2026-01-09")

    guard case .empty(let date, let explanation) = lookup else {
        Issue.record("expected .empty, got \(lookup)")
        await session.stop()
        return
    }
    #expect(date == "2026-01-09")
    #expect(explanation.contains("no such date"))
    #expect(explanation.contains("2026-01-03, 2026-01-04"))
    // The old text told the user to go run another command; the answer is here.
    #expect(!explanation.contains("try `pocket-cli list`"))
    #expect(t.sent.contains("APP&LIST_DIRS"))
    await session.stop()
}

/// The other empty: the device lists the date and still serves no files for it.
/// A real day that is empty is a different finding from a date the device has
/// never heard of, and the text must not conflate them.
@Test func aDateTheDeviceListsButServesNoFilesForIsReportedAsThat() async throws {
    let t = FakeTransport()
    t.script["APP&LIST&2026-01-04"] = ["MCU&LIST&0"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-04", "MCU&DIRS_SUM&1"]
    let session = try await authedSession(t)

    let lookup = try await session.lookUpRecordings(forDate: "2026-01-04")

    guard case .empty(_, let explanation) = lookup else {
        Issue.record("expected .empty, got \(lookup)")
        await session.stop()
        return
    }
    #expect(explanation.contains("does list 2026-01-04 as a date it has"))
    #expect(!explanation.contains("no such date"))
    await session.stop()
}

/// And the third: nothing on the device at all, which is not about the date.
@Test func aDeviceWithNoDatesAtAllSaysSoInsteadOfBlamingTheArgument() async throws {
    let t = FakeTransport()
    t.script["APP&LIST&2026-01-04"] = ["MCU&LIST&0"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS_SUM&0"]
    let session = try await authedSession(t)

    let lookup = try await session.lookUpRecordings(forDate: "2026-01-04")

    guard case .empty(_, let explanation) = lookup else {
        Issue.record("expected .empty, got \(lookup)")
        await session.stop()
        return
    }
    #expect(explanation.contains("none anywhere on this device"))
    #expect(explanation.contains("APP&LIST_DIRS listed no dates at all"))
    await session.stop()
}

// MARK: - The same trap one level down

/// `download`'s timestamp cannot be validated by grammar — the device has
/// produced IDs that are not 14 digits — so the day's own listing is printed as
/// the authority, and it can never read as "your device has nothing".
@Test func anUnmatchedTimestampNamesTheOnesThatDoExistOnThatDate() {
    let onThatDate = [
        RecordingInfo(id: RecordingID(date: "2026-01-04", timestamp: "20260104100000"),
                      durationSeconds: 12),
        RecordingInfo(id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
                      durationSeconds: 3),
    ]

    let text = RecordingDate.noSuchRecordingText(timestamp: "20260104999999",
                                                 date: "2026-01-04",
                                                 onThatDate: onThatDate)

    #expect(text.contains("no recording 20260104999999 on 2026-01-04"))
    #expect(text.contains("2 recording(s)"))
    #expect(text.contains("20260104100000, 20260104101500"))
    #expect(!text.contains("none"))
}
