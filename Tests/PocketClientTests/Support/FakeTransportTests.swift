// pocket-client/Tests/PocketClientTests/Support/FakeTransportTests.swift
import Foundation
import Testing
@testable import PocketClient

@Test func fakeTransportRecordsSendsAndScriptsReplies() async throws {
    let t = FakeTransport()
    t.script["APP&BAT"] = ["MCU&BAT&91"]
    let responses = t.responseStream()

    try await t.send(Command.battery.encoded)

    #expect(t.sent == ["APP&BAT"])
    var iterator = responses.makeAsyncIterator()
    let first = await iterator.next()
    #expect(Response.parse(first!) == .battery(91))
}

@Test func fakeTransportDeliversBulkChunks() async throws {
    let t = FakeTransport()
    let bulk = t.bulkStream()
    t.emitBulk(Data([0xFF, 0xF3]))
    t.emitBulk(Data([0x48, 0xC4]))
    t.finish()

    var received = Data()
    for await chunk in bulk { received.append(chunk) }
    #expect(received == Data([0xFF, 0xF3, 0x48, 0xC4]))
}

/// Pins the fixture's *shape*, never its exact byte count — the suite derives
/// every announced size from the file itself, so a swapped fixture must not
/// require editing tests. What the transfer path actually depends on is
/// asserted here: the MPEG-2 Layer III sync word it validates, and a payload
/// large enough to keep the truncation tests meaningful.
@Test func goldenFixtureIsAUsableMP3Payload() throws {
    let golden = try FakeTransport.loadGoldenFixture()
    #expect(golden.count == FakeTransport.goldenSize)
    // `FF F3` = MPEG-2 Layer III, no CRC — the exact framing the device emits
    // and the only thing `TransferSink` checks about the payload's contents.
    #expect(golden.prefix(2) == Data([0xFF, 0xF3]))
    // The truncation tests emit `golden.prefix(9_000)` and expect a size
    // mismatch; if a future fixture were smaller than that, those tests would
    // silently stop testing truncation.
    #expect(golden.count > 9_000)
}
