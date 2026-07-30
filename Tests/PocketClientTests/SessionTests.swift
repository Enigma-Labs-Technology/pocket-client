// pocket-client/Tests/PocketClientTests/SessionTests.swift
import Foundation
import Testing
@testable import PocketClient

private func makeSession(_ t: FakeTransport, key: String = "ExampleKey000000") -> PocketSession {
    PocketSession(transport: t, sessionKey: key)
}

private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var value = 0
    /// Counts only APP&BAT frames observed after APP&STE has hit the wire, so
    /// "keepalive ticks fired during the armed window" holds by construction
    /// even if the runner stalls and early ticks land before the request arms.
    func observe(_ wire: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if wire == "APP&STE" { armed = true }
        guard armed, wire == "APP&BAT" else { return 0 }
        value += 1
        return value
    }
}

@Test func handshakeSendsKeyAndSucceeds() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    let session = makeSession(t)

    try await session.start()

    #expect(t.sent.first == "APP&SK&ExampleKey000000")
    await session.stop()
}

@Test func handshakeRejectionSurfacesAuthRejected() async throws {
    let t = FakeTransport()
    t.script["APP&SK&wrong-key-000000"] = ["MCU&SK&ERR"]
    let session = makeSession(t, key: "wrong-key-000000")

    await #expect(throws: PocketError.authRejected) {
        try await session.start()
    }
    await session.stop()
}

@Test func requestCorrelatesTheMatchingResponse() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&BAT&64"]
    let session = makeSession(t)
    try await session.start()

    let response = try await session.request(.battery) { if case .battery = $0 { true } else { false } }

    #expect(response == .battery(64))
    await session.stop()
}

@Test func requestTimesOutWhenDeviceIsSilent() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    let session = makeSession(t)
    try await session.start()

    await #expect(throws: PocketError.timeout(.battery)) {
        _ = try await session.request(.battery, timeout: .milliseconds(80)) {
            if case .battery = $0 { true } else { false }
        }
    }
    await session.stop()
}

@Test func unknownCommandResponseThrows() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    t.script["APP&PAU"] = ["MCU&UNKNOWN"]
    let session = makeSession(t)
    try await session.start()

    await #expect(throws: PocketError.unknownCommand(.pauseRecording)) {
        _ = try await session.request(.pauseRecording, timeout: .milliseconds(200)) {
            if case .recordingStopped = $0 { true } else { false }
        }
    }
    await session.stop()
}

@Test func collectingRequestGathersUntilTerminator() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    t.script["APP&LIST_DIRS"] = ["MCU&DIRS&2026-01-02", "MCU&DIRS&2026-01-03",
                                 "MCU&DIRS&2026-01-04", "MCU&DIRS_SUM&3"]
    let session = makeSession(t)
    try await session.start()

    let entries = try await session.requestCollecting(
        .listDates,
        element: { if case .dateEntry = $0 { true } else { false } },
        terminator: { if case .dateSummary = $0 { true } else { false } })

    #expect(entries == [.dateEntry("2026-01-02"), .dateEntry("2026-01-03"), .dateEntry("2026-01-04")])
    await session.stop()
}

@Test func sendFailureSurfacesErrorOnceAndSessionRecovers() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&BAT&64"]
    let session = makeSession(t)
    try await session.start()

    t.sendError = PocketError.transferFailed("GATT write failed")
    await #expect(throws: (any Error).self) {
        _ = try await session.request(.battery, timeout: .milliseconds(200)) {
            if case .battery = $0 { true } else { false }
        }
    }

    t.sendError = nil
    let response = try await session.request(.battery, timeout: .milliseconds(500)) {
        if case .battery = $0 { true } else { false }
    }
    #expect(response == .battery(64))
    await session.stop()
}

@Test func secondRequestWhileOneIsInFlightFailsFastWithBusy() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    // APP&STE is deliberately unscripted: the device stays silent.
    let session = makeSession(t)
    try await session.start()

    let (armed, armedContinuation) = AsyncStream<Void>.makeStream()
    t.onSend = { wire, _ in if wire == "APP&STE" { armedContinuation.yield(()) } }

    let first = Task {
        try await session.request(.recordingState, timeout: .milliseconds(500)) {
            if case .recordingState = $0 { true } else { false }
        }
    }
    var armedEvents = armed.makeAsyncIterator()
    _ = await armedEvents.next()   // first request's waiter is now armed

    await #expect(throws: PocketError.busy("request already in flight")) {
        _ = try await session.request(.battery, timeout: .milliseconds(500)) {
            if case .battery = $0 { true } else { false }
        }
    }

    await #expect(throws: PocketError.timeout(.recordingState)) {
        _ = try await first.value
    }
    await session.stop()
}

/// Waiter identity (Task 4 review obligation): a send that fails only
/// *after* its request already timed out must not touch whatever waiter now
/// occupies the slot. The interleaving is driven deterministically: A arms
/// and its send suspends in the gate; A times out (slot cleared, A resumed);
/// B arms; the gate releases and A's send throws late. Identity-blind
/// cleanup would clear B's waiter and resume A's already-resumed
/// continuation — a fatal double resume. With the generation guard the late
/// failure is a no-op: A saw exactly one timeout, no trap, and B completes
/// normally. The same generation flows through `expireWaiter`, so its
/// identity check rides the timeout in this test too.
@Test func lateSendFailureAfterTimeoutLeavesTheNextRequestUndisturbed() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let sendEntered = AsyncGate()
    let releaseSend = AsyncGate()
    t.beforeSendCompletes = { sendEntered.open(); await releaseSend.wait() }

    let first = Task {
        try await session.request(.recordingState, timeout: .milliseconds(100)) {
            if case .recordingState = $0 { true } else { false }
        }
    }
    await sendEntered.wait()   // A's waiter is armed; its send is suspended

    // A times out exactly once while its send is still suspended.
    await #expect(throws: PocketError.timeout(.recordingState)) { try await first.value }

    // Arm B (APP&BAT deliberately unscripted, so it stays in flight).
    t.beforeSendCompletes = nil
    let (armedB, armedBContinuation) = AsyncStream<Void>.makeStream()
    t.onSend = { wire, _ in if wire == "APP&BAT" { armedBContinuation.yield(()) } }
    let second = Task {
        try await session.request(.battery, timeout: .seconds(5)) {
            if case .battery = $0 { true } else { false }
        }
    }
    var armed = armedB.makeAsyncIterator()
    _ = await armed.next()     // B's waiter now occupies the slot A once held

    // Release A's suspended send and make it throw late; give the late catch
    // time to run on the actor before B's reply resolves the slot (in the
    // buggy identity-blind version this window is where the trap fires).
    t.sendError = PocketError.transferFailed("late GATT failure")
    releaseSend.open()
    try await Task.sleep(for: .milliseconds(100))

    // B is untouched: it still answers normally.
    t.sendError = nil
    t.emitResponse("MCU&BAT&64")
    #expect(try await second.value == .battery(64))
    await session.stop()
}

/// Caller cancellation with a waiter armed against a silent device — the
/// field shape of a SwiftUI `.task` or sync-engine cancellation mid-request.
/// The session's timeout child must fail the armed waiter with
/// `CancellationError` instead of skipping the expiry: a checked
/// continuation is never resumed by cancellation alone, and one left pending
/// wedges `perform`'s task group forever — the caller hangs past every
/// timeout and the occupied slot fails all later requests with `.busy`.
///
/// The request's own timeout is put ten minutes out of reach so that the promptness
/// is proved by what happens rather than measured on the wall clock: a waiter that
/// only unwinds when its timeout expires cannot finish inside this test's
/// one-minute limit. The stopwatch this used to carry — under a second, against a
/// 30 s timeout — measured the machine as much as the code.
@Test(.timeLimit(.minutes(1)))
func cancellingAnArmedRequestReturnsPromptlyAndFreesTheSlot() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&BAT&64"]
    // APP&STE deliberately unscripted: the device stays silent forever.
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let (armed, armedContinuation) = AsyncStream<Void>.makeStream()
    t.onSend = { wire, _ in if wire == "APP&STE" { armedContinuation.yield(()) } }

    let request = Task {
        try await session.request(.recordingState, timeout: .seconds(600)) {
            if case .recordingState = $0 { true } else { false }
        }
    }
    var armedEvents = armed.makeAsyncIterator()
    _ = await armedEvents.next()   // the waiter is installed before the frame hits the wire

    request.cancel()
    await #expect(throws: CancellationError.self) { _ = try await request.value }

    // The slot is free again: the next request answers instead of `.busy`.
    let response = try await session.request(.battery) {
        if case .battery = $0 { true } else { false }
    }
    #expect(response == .battery(64))
    await session.stop()
}

/// The 30 s keepalive's own `MCU&BAT` echo is expected link filler, not a
/// device anomaly: it must be absorbed instead of surfacing as
/// `.unmatchedResponse` noise every interval forever — while genuinely
/// unexpected frames keep flowing (that diagnostic is load-bearing). The
/// genuine frame is emitted only after three echoes are already on the
/// response stream, so ordering proves absorption: were echoes surfacing,
/// one would be delivered first.
@Test func keepaliveEchoesAreAbsorbedWhileGenuineFramesStillSurface() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&BAT&64"]   // the device answers every keepalive ping
    let session = PocketSession(transport: t, sessionKey: "K",
                                keepaliveInterval: .milliseconds(20))
    try await session.start()

    let ticks = Counter()
    t.onSend = { wire, transport in
        guard wire == "APP&BAT", ticks.next() == 3 else { return }
        transport.emitResponse("MCU&WIFIS&0")
    }

    var iterator = session.events.makeAsyncIterator()
    #expect(await iterator.next() == .unmatchedResponse("MCU&WIFIS&0"))
    await session.stop()
}

@Test func keepaliveTicksDuringInFlightRequestAreHarmless() async throws {
    let t = FakeTransport()
    t.script["APP&SK&ExampleKey000000"] = ["MCU&SK&OK"]
    // APP&STE is deliberately unscripted: the fake answers it only once the
    // keepalive has put three APP&BAT frames on the wire while the request
    // is armed — the exact window where the old keepalive raced user requests.
    let session = PocketSession(transport: t, sessionKey: "ExampleKey000000",
                                keepaliveInterval: .milliseconds(50))
    try await session.start()

    let ticks = TickCounter()
    t.onSend = { wire, transport in
        if ticks.observe(wire) == 3 {
            transport.emitResponse("MCU&STE&1")
        }
    }

    // Must complete normally: no PocketError.busy, no timeout.
    let response = try await session.request(.recordingState, timeout: .seconds(5)) {
        if case .recordingState = $0 { true } else { false }
    }

    #expect(response == .recordingState(true))
    await session.stop()
    // Read `sent` only after stop(): the keepalive is no longer ticking.
    #expect(t.sent.filter { $0 == "APP&BAT" }.count >= 3)
}
