// pocket-client/Tests/PocketClientTests/WiFiBatchTests.swift
//
// One access-point session for several recordings.
//
// The device's answer to a second `APP&U&<date>&<ts>` on a live AP has never
// been observed on hardware — the capture the protocol was decoded from covered
// a single-file sync — so the batch attempts reuse and must fall back cleanly.
// BOTH branches of that unknown are pinned here:
//
//  - a fake device that serves a second selection (reuse works): one handshake,
//    one join, one close, and the saving is real;
//  - a fake device that refuses one (two shapes: `MCU&UNKNOWN` to the selection,
//    and `MCU&WIFIS&0` in the gap poll): the session is torn down properly, the
//    remaining recordings are still delivered, and no AP is left broadcasting.
//
// Plus the two guarantees that hold whichever way the unknown falls: a failure
// on recording N never loses recordings 1…N-1, and every exit path closes the
// access point.
import Foundation
import Network
import Testing
@testable import PocketClient

/// Serves one scripted payload per TCP connection, in order — the shape a
/// batched WiFi run produces, where the device closes the socket at `MCU&OFF`
/// (TCP FIN at the same instant, per the capture) and the next recording opens a
/// fresh one. Connections past `overrides` get `payload`, so a test scripts only
/// the connection it cares about.
final class SequencedLoopbackServer: @unchecked Sendable {
    /// Connection counter, kept in its own object so the accept handler never
    /// captures a partially initialised server.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var served: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private let listener: NWListener
    private let ledger: Ledger
    let port: UInt16

    /// `beforeSend` runs with the 1-based connection index before that
    /// connection's payload is written — how a test holds a transfer open.
    init(payload: Data,
         overrides: [Int: Data] = [:],
         beforeSend: (@Sendable (Int) async -> Void)? = nil) throws {
        let ledger = Ledger()
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            let index = ledger.next()
            connection.start(queue: .global())
            let body = overrides[index] ?? payload
            Task {
                await beforeSend?(index)
                connection.send(content: body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: .global())
        // `listener.port` echoes the requested port (0 for `.any`) until the
        // bind completes, so 0 means "not resolved yet", not a real port.
        var resolved: UInt16?
        for _ in 0..<200 where resolved == nil {
            if let p = listener.port?.rawValue, p != 0 {
                resolved = p
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        guard let p = resolved else { throw PocketError.transferFailed("listener never bound") }
        self.ledger = ledger
        self.listener = listener
        self.port = p
    }

    var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    /// How many TCP connections the run opened — one per transfer attempt,
    /// including an attempt the device refused after the socket was up.
    var connectionCount: Int { ledger.served }

    func stop() { listener.cancel() }
}

/// `count` recordings in one day's directory, each large enough that `.auto`
/// would pick WiFi. Distinct timestamps: the selection frame is what
/// distinguishes them on the wire, not their bytes.
func wifiBatchRecordings(_ count: Int) -> [RecordingInfo] {
    (0..<count).map { index in
        RecordingInfo(id: RecordingID(date: "2026-01-04",
                                      timestamp: String(format: "202601041015%02d", index)),
                      durationSeconds: 400)
    }
}

/// The frames a batched run needs: the shared session handshake plus one
/// selection per recording. A test that wants to drive a selection itself
/// clears that key (`t.script[…] = nil`) and answers from `onSend`.
func scriptWiFiBatchConversation(on t: FakeTransport,
                                 recordings: [RecordingInfo],
                                 announcing announced: Int = FakeTransport.goldenSize) {
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&SHUT"] = []            // no reply on an idle device (live-probe verified)
    t.script["APP&WIFI"] = ["MCU&WIFI&PKT01_EXAMPLE&ExampleK"]
    t.script["APP&WIFIO"] = ["MCU&WIFIO"]
    t.script["APP&WPING"] = ["MCU&WPING"]
    // The capture shows the reroute acked as MCU&U&WIFI followed by a repeat of
    // the size announcement; the repeat matches nothing and must be tolerated.
    t.script["APP&U&WIFI"] = ["MCU&U&WIFI", "MCU&U&\(announced)"]
    t.script["APP&WIFIC"] = ["MCU&WIFIC"]
    for recording in recordings {
        t.script[selectionFrame(recording)] = ["MCU&U&\(announced)"]
    }
}

func selectionFrame(_ recording: RecordingInfo) -> String {
    "APP&U&\(recording.id.date)&\(recording.id.timestamp)"
}

/// Whether the fake device's access point is up, and how many `APP&WIFIS` polls
/// it has answered since it came up.
private final class FakeAccessPoint: @unchecked Sendable {
    private let lock = NSLock()
    private var up = false
    private var polls = 0
    func started() { lock.lock(); up = true; polls = 0; lock.unlock() }
    func closed() { lock.lock(); up = false; lock.unlock() }
    var isDown: Bool { lock.lock(); defer { lock.unlock() }; return !up }
    func nextPoll() -> Int { lock.lock(); defer { lock.unlock() }; polls += 1; return polls }
}

/// A `MCU&WIFIS&<n>` oracle that tracks the fake device's own access point, which
/// is the part a batch restart depends on: **after `APP&WIFIC` the device reports
/// its WiFi off (`MCU&WIFIS&0`) until `APP&WIFIO` starts it again.** A fake that
/// kept answering `1` after being closed would let a restart send `APP&WIFIO`
/// into a state no real device would be in, and `awaitWiFiOff` would have nothing
/// to wait for.
///
/// While the AP is up, `progression` decides — counting polls from each
/// `APP&WIFIO`, so a restarted session starts counting again. Returning `nil`
/// makes the device stay silent for that poll. `also` handles any other frame the
/// test wants to answer itself.
private func scriptWiFiStateOracle(on t: FakeTransport,
                                   progression: @escaping @Sendable (Int) -> String?,
                                   also: (@Sendable (String, FakeTransport) -> Void)? = nil) {
    let ap = FakeAccessPoint()
    t.onSend = { wire, transport in
        switch wire {
        case "APP&WIFIO":
            ap.started()
        case "APP&WIFIC":
            ap.closed()
        case "APP&WIFIS":
            // A poll while the AP is down does not consume a progression step:
            // the pre-flight query of every session lands here.
            if ap.isDown {
                transport.emitResponse("MCU&WIFIS&0")
            } else if let reply = progression(ap.nextPoll()) {
                transport.emitResponse(reply)
            }
        default:
            break
        }
        also?(wire, transport)
    }
}

/// The capture's healthy progression from each `APP&WIFIO`: `3` (AP up), `2`
/// (client associated), then `1` (TCP connected) for every later poll — which is
/// also what the batch's gap poll must accept as "the session is still there".
private let healthyWiFiProgression: @Sendable (Int) -> String? = { poll in
    switch poll {
    case 1:  "MCU&WIFIS&3"
    case 2:  "MCU&WIFIS&2"
    default: "MCU&WIFIS&1"
    }
}

private func scriptHealthyWIFIStateMachine(on t: FakeTransport) {
    scriptWiFiStateOracle(on: t, progression: healthyWiFiProgression)
}

private func makeScratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wifi-batch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Branch one: the device serves a second selection

/// The optimistic branch of the unknown. Three recordings, one access point:
/// one handshake, ONE join (which is what makes the macOS manual path prompt
/// once instead of three times), one close.
@Test func aBatchThatCanReuseTheSessionOpensTheAccessPointOnce() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    scriptHealthyWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    #expect(result.isComplete)
    #expect(result.stopped == nil)
    #expect(result.delivered.map(\.recording) == recordings)
    #expect(result.delivered.map(\.sessionUse) == [.openedSession, .reusedSession, .reusedSession])
    #expect(result.didReuseSession)
    #expect(result.refusals.isEmpty)
    #expect(result.sessionsOpened == 1)
    #expect(result.delivered.allSatisfy { $0.data == golden })
    #expect(result.delivered.allSatisfy { $0.byteCount == FakeTransport.goldenSize })

    // ONE join and ONE leave for three recordings — the whole point.
    #expect(joiner.box.joined == ["PKT01_EXAMPLE"])
    #expect(joiner.box.left == 1)
    // The AP handshake ran once: one credentials query, one AP start.
    #expect(t.sent.filter { $0 == "APP&WIFI" }.count == 1)
    #expect(t.sent.filter { $0 == "APP&WIFIO" }.count == 1)
    // And the session closed once, with the vendor app's double WIFIC.
    #expect(t.sent.filter { $0 == "APP&WIFIC" }.count == 2)
    // Three selections and three reroutes on one live AP — the device served a
    // second and third `APP&U&<date>&<ts>`, which is the unverified part.
    for recording in recordings {
        #expect(t.sent.filter { $0 == selectionFrame(recording) }.count == 1)
    }
    #expect(t.sent.filter { $0 == "APP&U&WIFI" }.count == 3)
    // One socket per recording: the device closes it at MCU&OFF, so the AP and
    // the association carry over, never the connection.
    #expect(server.connectionCount == 3)
    #expect(!t.sent.contains("APP&PING"))   // never a real command
    await session.stop()
}

/// The same run through the streaming destination: three validated files, still
/// one session, and nothing left beside them.
@Test func aBatchStreamsEachRecordingToItsOwnValidatedFile() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    scriptHealthyWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let result = try await session.downloadOverWiFi(
        recordings,
        into: .files { dir.appendingPathComponent("\($0.id.timestamp).mp3") },
        endpointOverride: server.endpoint,
        joiner: RecordingJoiner(shouldFail: false),
        readiness: fastReadiness)

    #expect(result.isComplete)
    #expect(result.sessionsOpened == 1)
    // A streaming destination returns no bytes; they are already on disk.
    #expect(result.delivered.allSatisfy { $0.data == nil })
    for recording in recordings {
        let file = dir.appendingPathComponent("\(recording.id.timestamp).mp3")
        #expect(try Data(contentsOf: file) == golden)
    }
    // Exactly three files: no temp companion survived any recording.
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            == recordings.map { "\($0.id.timestamp).mp3" }.sorted())
    await session.stop()
}

/// Per-recording progress is reported against the recording it belongs to, and
/// every recording finishes at 1.0.
@Test func aBatchReportsProgressPerRecording() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(2)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    scriptHealthyWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let seen = BatchProgressLog()
    _ = try await session.downloadOverWiFi(recordings,
                                           endpointOverride: server.endpoint,
                                           joiner: RecordingJoiner(shouldFail: false),
                                           readiness: fastReadiness,
                                           onProgress: { seen.record($0, $1) })

    for recording in recordings {
        let values = seen.values(for: recording.id)
        #expect(!values.isEmpty)
        #expect(values == values.sorted())
        #expect(values.last == 1.0)
    }
    await session.stop()
}

/// Progress samples grouped by recording, thread-safe: the TCP reader delivers
/// them off the session's executor.
final class BatchProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(RecordingID, Double)] = []
    func record(_ id: RecordingID, _ fraction: Double) {
        lock.lock(); samples.append((id, fraction)); lock.unlock()
    }
    func values(for id: RecordingID) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return samples.filter { $0.0 == id }.map(\.1)
    }
}

// MARK: - Branch two: the device refuses a second selection

/// The pessimistic branch, shape one: the device answers `MCU&UNKNOWN` to a
/// second `APP&U&<date>&<ts>` while its AP is up.
///
/// The refusal must be caught before any payload byte of that recording flowed,
/// the session torn down properly, and the recording served on a fresh one — and
/// then the batch must stop attempting reuse, because a doomed attempt plus a
/// teardown per recording would be worse than the behaviour it falls back to.
/// Every recording still arrives, and no AP is left broadcasting.
@Test func aRefusedSecondSelectionRestartsTheSessionAndStillDeliversEverything() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    // The second recording's selection is driven from `onSend` instead: refused
    // the first time it is asked (on the live session), served the second time
    // (after the restart).
    let secondSelection = selectionFrame(recordings[1])
    t.script[secondSelection] = nil

    let asks = Counter()
    scriptWiFiStateOracle(on: t, progression: healthyWiFiProgression) { wire, transport in
        guard wire == secondSelection else { return }
        transport.emitResponse(asks.next() == 1
                               ? "MCU&UNKNOWN"
                               : "MCU&U&\(FakeTransport.goldenSize)")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    // Nothing was lost: all three recordings arrived, byte-identical.
    #expect(result.isComplete)
    #expect(result.delivered.map(\.recording) == recordings)
    #expect(result.delivered.allSatisfy { $0.data == golden })

    // The refusal is reported, not swallowed — this is the experiment's answer.
    #expect(!result.didReuseSession)
    #expect(result.refusals.count == 1)
    #expect(result.refusals[0].contains("would not serve another recording on the live session"))
    #expect(result.refusals[0].contains("MCU&UNKNOWN"))
    #expect(result.sessionsOpened == 3)

    // Recording 1 opened the session; recording 2 discovered the refusal and
    // restarted; recording 3 did not re-attempt reuse — it opened its own.
    #expect(result.delivered[0].sessionUse == .openedSession)
    if case .restartedSession = result.delivered[1].sessionUse {} else {
        Issue.record("recording 2 should report a restarted session, got \(result.delivered[1].sessionUse)")
    }
    #expect(result.delivered[2].sessionUse == .ownSession)

    // One session per recording, exactly today's behaviour — and every one of
    // them was joined, closed, and left.
    #expect(joiner.box.joined == ["PKT01_EXAMPLE", "PKT01_EXAMPLE", "PKT01_EXAMPLE"])
    #expect(joiner.box.left == 3)
    #expect(t.sent.filter { $0 == "APP&WIFIO" }.count == 3)
    // No AP left up: the refused session was aborted (SHUT + one WIFIC) and the
    // two that completed closed with the vendor app's double WIFIC.
    #expect(t.sent.filter { $0 == "APP&WIFIC" }.count == 5)
    // The refused attempt asked twice in total for that recording.
    #expect(t.sent.filter { $0 == secondSelection }.count == 2)
    // The reroute never went out for the refused attempt: three reroutes for
    // three delivered recordings, not four.
    #expect(t.sent.filter { $0 == "APP&U&WIFI" }.count == 3)
    // Four sockets for three recordings: the refusal is only visible AFTER the
    // connect, so the refused attempt does open one. Which is exactly why the
    // connect gets its own do/catch in `transferOneRecording` — from the moment
    // it returns, every exit cancels the connection, or a run would leak one
    // socket per refusal.
    #expect(server.connectionCount == 4)

    // The exclusive transfer slot came back.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

/// The pessimistic branch, shape two — and the likeliest one: after `MCU&OFF`
/// the device closes its own WiFi session, so the gap poll before the next
/// recording sees `MCU&WIFIS&0`. Caught before a socket is even opened for that
/// recording, and the reason says exactly what the device reported.
@Test func aSessionTheDeviceClosedItselfIsDetectedByTheGapPollAndRestarted() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(2)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)

    // Polls are counted from each APP&WIFIO, so the restarted session repeats
    // 1 → 2 and never reaches the poll that reports the session gone.
    scriptWiFiStateOracle(on: t) { poll in
        switch poll {
        case 1:  "MCU&WIFIS&2"   // client associated
        case 2:  "MCU&WIFIS&1"   // recording 1: TCP connected
        default: "MCU&WIFIS&0"   // the gap poll: the device closed its own session
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    #expect(result.isComplete)
    #expect(result.delivered.count == 2)
    #expect(result.refusals.count == 1)
    #expect(result.refusals[0].contains("MCU&WIFIS&0"))
    #expect(result.refusals[0].contains("closed the session itself"))
    #expect(!result.didReuseSession)
    // Detected before a socket was opened for recording 2: two connections for
    // two recordings, not three.
    #expect(server.connectionCount == 2)
    #expect(joiner.box.left == 2)
    #expect(t.sent.filter { $0 == "APP&WIFIO" }.count == 2)
    await session.stop()
}

/// A host that disassociated between recordings — on iOS the ordinary
/// consequence of `joinOnce`, which is what made per-recording sessions prompt
/// the user over and over. The device still reports its AP up, with no client:
/// `MCU&WIFIS&3`. Restarting is what re-joins.
@Test func aHostThatLeftTheNetworkIsDetectedAsAnUnassociatedAP() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(2)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)

    scriptWiFiStateOracle(on: t) { poll in
        switch poll {
        case 1:  "MCU&WIFIS&2"   // client associated
        case 2:  "MCU&WIFIS&1"   // recording 1 confirmation
        default: "MCU&WIFIS&3"   // the gap poll: AP up, nobody on it
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    #expect(result.isComplete)
    #expect(result.delivered.count == 2)
    #expect(result.refusals.count == 1)
    #expect(result.refusals[0].contains("MCU&WIFIS&3"))
    #expect(result.refusals[0].contains("this host left the network"))
    // Two joins: the restart is what puts this host back on the network.
    #expect(joiner.box.joined.count == 2)
    #expect(joiner.box.left == 2)
    await session.stop()
}

/// A restart is the only place in this protocol that closes an access point and
/// immediately reopens one, so it is the only place that could ask the device to
/// start an AP that has not finished coming down. Before every reopen the client
/// waits for `MCU&WIFIS&0` — evidence that it is actually down, not a guessed
/// sleep — and that poll must land **after** `APP&WIFIC` and **before** the next
/// `APP&WIFIO`.
///
/// The first session is exempt: it has nothing to wait for, and adding a frame
/// there would depart from the capture-verified sequence.
@Test func aRestartWaitsForTheDeviceToReportItsAccessPointOffBeforeReopening() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(2)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    scriptWiFiStateOracle(on: t) { poll in
        switch poll {
        case 1:  "MCU&WIFIS&2"
        case 2:  "MCU&WIFIS&1"
        default: "MCU&WIFIS&0"   // gap poll: the device closed its own session
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: RecordingJoiner(shouldFail: false),
                                                    readiness: fastReadiness)

    #expect(result.isComplete)
    #expect(result.refusals.count == 1)

    // The exact restart sequence, pinned. The settle poll is the APP&WIFIS
    // immediately after the teardown's APP&WIFIC and BEFORE the reopen's own
    // APP&SHUT — note that asserting merely "some APP&WIFIS between the close and
    // the next APP&WIFIO" would be satisfied by the reopen's pre-flight query and
    // would pass with the wait removed entirely.
    let starts = t.sent.indices.filter { t.sent[$0] == "APP&WIFIO" }
    #expect(starts.count == 2)
    let firstClose = try #require(t.sent.firstIndex(of: "APP&WIFIC"))
    #expect(firstClose < starts[1])
    #expect(Array(t.sent[firstClose...starts[1]]) == [
        "APP&WIFIC",   // the teardown's close (its APP&SHUT precedes this)
        "APP&WIFIS",   // the settle poll — answered MCU&WIFIS&0: it really is down
        "APP&SHUT",    // and only now the next session's steps 1–4
        "APP&WIFIS",
        "APP&WIFI",
        "APP&WIFIO",
    ])
    // One extra round-trip when the device is prompt, which is the whole cost.
    #expect(t.sent[firstClose..<starts[1]].filter { $0 == "APP&WIFIS" }.count == 2)

    // The FIRST session opened with no such wait: before the first APP&WIFIO the
    // only APP&WIFIS is the capture's pre-flight query, and no APP&WIFIC precedes
    // it at all.
    #expect(t.sent[..<starts[0]].filter { $0 == "APP&WIFIS" }.count == 1)
    #expect(!t.sent[..<starts[0]].contains("APP&WIFIC"))
    await session.stop()
}

/// And when the device never reports itself off, the run says so instead of
/// pressing on. `APP&WIFIO` must not go out a second time: reopening on top of an
/// access point in an unknown state is exactly how a flaky *fallback* would get
/// misread as the device refusing session reuse — the one thing the hardware run
/// is meant to establish.
@Test func aRestartThatNeverSeesTheAccessPointGoOffStopsInsteadOfReopening() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    // A device that always claims a TCP client is connected — including after it
    // was told to close, which is the state this must not build on. `1` is
    // accepted by the association wait and by the gap poll, so nothing else in
    // the flow stumbles; only the post-teardown wait has no answer.
    t.script["APP&WIFIS"] = ["MCU&WIFIS&1"]
    // The second recording is refused on the live session, so a restart is
    // attempted — and it is the restart that must refuse to proceed.
    t.script[selectionFrame(recordings[1])] = ["MCU&UNKNOWN"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(
        recordings,
        endpointOverride: server.endpoint,
        joiner: joiner,
        // Bounds the settle wait as well, so this resolves promptly.
        readiness: WiFiReadiness(timeout: .milliseconds(300),
                                 pollInterval: .milliseconds(5),
                                 pingInterval: .seconds(60)))

    // Recording 1 survived; the run stopped naming recording 2 and why.
    #expect(result.delivered.count == 1)
    #expect(result.delivered[0].recording == recordings[0])
    let stopped = try #require(result.stopped)
    #expect(stopped.recording == recordings[1])
    #expect(stopped.reason.contains("did not report its WiFi off (MCU&WIFIS&0)"))
    #expect(stopped.reason.contains("last state: MCU&WIFIS&1"))
    #expect(stopped.remaining == [recordings[2]])

    // The point: exactly ONE access point was ever started. The restart stopped
    // rather than sending APP&WIFIO into a state it could not describe.
    #expect(t.sent.filter { $0 == "APP&WIFIO" }.count == 1)
    // And the one it did start was closed and left behind properly.
    #expect(t.sent.contains("APP&WIFIC"))
    #expect(joiner.box.joined.count == 1)
    #expect(joiner.box.left == 1)
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

/// Silence is not evidence. A firmware that stops answering `APP&WIFIS`
/// must not be read as having closed its session — the selection decides.
@Test func aGapPollThatGoesUnansweredDoesNotCountAsARefusal() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(2)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)

    scriptWiFiStateOracle(on: t) { poll in
        switch poll {
        case 1:  "MCU&WIFIS&2"   // client associated
        case 2:  "MCU&WIFIS&1"   // recording 1 confirmation
        case 3:  nil             // the gap poll: no answer at all
        default: "MCU&WIFIS&1"
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    // Reuse went ahead on the strength of the selection succeeding.
    #expect(result.isComplete)
    #expect(result.didReuseSession)
    #expect(result.refusals.isEmpty)
    #expect(result.sessionsOpened == 1)
    #expect(joiner.box.joined.count == 1)
    await session.stop()
}

// MARK: - A failure mid-batch keeps what came before it

/// The requirement stated plainly: a failure on recording N must not lose
/// recordings 1…N-1. The run stops there, reports what it delivered, names the
/// recording that stopped it, leaves the rest untouched for the caller to decide
/// about — and closes the access point.
@Test func aFailureMidBatchKeepsTheEarlierRecordingsAndClosesTheAP() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    // The second recording's socket delivers a truncated stream.
    let server = try SequencedLoopbackServer(payload: golden,
                                             overrides: [2: Data(golden.prefix(9_000))])
    defer { server.stop() }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    scriptHealthyWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    // Recording 1 survived the failure of recording 2, byte-identically.
    #expect(!result.isComplete)
    #expect(result.delivered.count == 1)
    #expect(result.delivered[0].recording == recordings[0])
    #expect(result.delivered[0].data == golden)

    // The stop names the recording, the reason, and what was never attempted.
    let stopped = try #require(result.stopped)
    #expect(stopped.recording == recordings[1])
    #expect(stopped.error == .sizeMismatch(expected: FakeTransport.goldenSize, received: 9_000))
    #expect(stopped.reason == "received 9000 of \(FakeTransport.goldenSize) announced bytes")
    #expect(stopped.remaining == [recordings[2]])
    // Recording 3 was never selected — the caller decides about it.
    #expect(!t.sent.contains(selectionFrame(recordings[2])))
    // The summary a harness would print names the failing recording.
    #expect(result.summary.contains(recordings[1].id.timestamp))

    // The AP did not stay up: the failure aborted the session (SHUT + one
    // WIFIC) and left the network.
    #expect(t.sent.filter { $0 == "APP&WIFIC" }.count == 1)
    #expect(joiner.box.left == 1)
    // The exclusive transfer slot came back.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

/// A `.emptyRecording` is a fact about the recording, not a refusal: restarting
/// the session would announce the same 0. It stops the run like any other
/// failure, and the caller can drop it and re-batch the rest — which is what
/// `stopped.error` is for.
@Test func aZeroByteRecordingStopsTheBatchWithoutRestartingTheSession() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try SequencedLoopbackServer(payload: golden)
    defer { server.stop() }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    t.script[selectionFrame(recordings[1])] = ["MCU&U&0"]
    scriptHealthyWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi(recordings,
                                                    endpointOverride: server.endpoint,
                                                    joiner: joiner,
                                                    readiness: fastReadiness)

    #expect(result.delivered.count == 1)
    let stopped = try #require(result.stopped)
    #expect(stopped.recording == recordings[1])
    #expect(stopped.error == .emptyRecording)
    // Never mistaken for the device refusing a second selection: one session,
    // no restart, and no reroute for the empty selection.
    #expect(result.refusals.isEmpty)
    #expect(t.sent.filter { $0 == "APP&WIFIO" }.count == 1)
    #expect(t.sent.filter { $0 == "APP&U&WIFI" }.count == 1)
    #expect(joiner.box.left == 1)
    await session.stop()
}

/// A session that cannot be opened at all stops the run before anything is
/// delivered, and the reason is the join failure's — diagnosis included.
@Test func aBatchThatCannotOpenASessionStopsOnTheFirstRecording() async throws {
    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let result = try await session.downloadOverWiFi(recordings,
                                                    joiner: RecordingJoiner(shouldFail: true),
                                                    readiness: fastReadiness)

    #expect(result.delivered.isEmpty)
    let stopped = try #require(result.stopped)
    #expect(stopped.recording == recordings[0])
    #expect(stopped.reason.contains("could not join the device's WiFi AP: test — "))
    #expect(stopped.remaining == Array(recordings.dropFirst()))
    // The AP was started before the join could fail, so it was closed again.
    #expect(t.sent.filter { $0 == "APP&WIFIC" }.count == 1)
    // No selection was ever made.
    #expect(!t.sent.contains(selectionFrame(recordings[0])))
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

// MARK: - Cancellation, exclusivity, and the empty batch

/// Cancelling mid-batch is the caller's, not a WiFi failure: it surfaces as
/// `CancellationError` and still closes the access point.
@Test func cancellingMidBatchClosesTheAccessPointAndLeavesNoFile() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let reachedSecond = AsyncGate()
    let never = AsyncGate()
    let server = try SequencedLoopbackServer(payload: golden, beforeSend: { index in
        guard index == 2 else { return }
        reachedSecond.open()
        await never.wait()   // recording 2 hangs with its socket open
    })
    defer { server.stop() }
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let recordings = wifiBatchRecordings(3)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    scriptHealthyWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let batch = Task {
        try await session.downloadOverWiFi(
            recordings,
            into: .files { dir.appendingPathComponent("\($0.id.timestamp).mp3") },
            endpointOverride: server.endpoint,
            joiner: joiner,
            readiness: fastReadiness)
    }
    await reachedSecond.wait()

    let clock = ContinuousClock()
    let cancelled = clock.now
    batch.cancel()
    await #expect(throws: CancellationError.self) { _ = try await batch.value }
    // Well under the 10 s stall timeout: cancellation, not idle expiry.
    #expect(clock.now - cancelled < .seconds(2))

    // Recording 1 is on disk and validated; recording 2 left nothing at all,
    // not even its temp companion.
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            == ["\(recordings[0].id.timestamp).mp3"])
    // The AP was closed and the network left despite the cancellation.
    #expect(t.sent.contains("APP&WIFIC"))
    #expect(joiner.box.left == 1)
    try await session.beginTransfer()
    await session.endTransfer()
    never.open()
    await session.stop()
}

/// The batch rides the same exclusive transfer slot as everything else: rejected
/// before any WiFi control traffic goes out.
@Test func aBatchDuringALiveStreamFailsBusyWithoutTouchingTheWire() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()
    _ = try await session.liveAudio()

    await #expect(throws: PocketError.busy("transfer already in progress")) {
        _ = try await session.downloadOverWiFi(wifiBatchRecordings(2),
                                               joiner: RecordingJoiner(shouldFail: false))
    }
    #expect(!t.sent.contains("APP&SHUT"))
    await session.stop()
}

/// An empty batch never touches the radio — it must not start an access point
/// for nothing.
@Test func anEmptyBatchIsANoOpThatNeverStartsTheAccessPoint() async throws {
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: [])
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let result = try await session.downloadOverWiFi([], joiner: joiner)

    #expect(result.isComplete)
    #expect(result.delivered.isEmpty)
    #expect(result.sessionsOpened == 0)
    #expect(!result.didReuseSession)
    #expect(joiner.box.joined.isEmpty)
    #expect(t.sent == ["APP&SK&K"])   // handshake only
    // The slot was never claimed.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

// MARK: - The keepalive spans the whole session

/// `APP&WPING` used to cover one stretch — the TCP connect — because a session
/// lasted one transfer. A batch adds stretches nothing else covers, so the
/// keepalive is now session-scoped and gated on `ActivityMonitor.idleSince()`.
///
/// Pinned deterministically rather than sampled: the loopback server holds
/// recording 1's payload until a `APP&WPING` is seen *after* the reroute
/// (`APP&U&WIFI`). By then `connectKeepingLinkAlive`'s own pinger has been
/// cancelled — its task group ended when the connect returned — so the only
/// possible source is the session keepalive.
@Test func theWiFiKeepaliveRunsForTheWholeSessionNotJustTheConnect() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let rerouted = AsyncGate()
    let pingedAfterReroute = AsyncGate()
    let server = try SequencedLoopbackServer(payload: golden, beforeSend: { index in
        guard index == 1 else { return }
        await pingedAfterReroute.wait()
    })
    defer { server.stop() }

    let recordings = wifiBatchRecordings(2)
    let t = FakeTransport()
    scriptWiFiBatchConversation(on: t, recordings: recordings)
    let polls = Counter()
    t.onSend = { wire, transport in
        switch wire {
        case "APP&WIFIS":
            switch polls.next() {
            case 1:  transport.emitResponse("MCU&WIFIS&0")
            case 2:  transport.emitResponse("MCU&WIFIS&2")
            default: transport.emitResponse("MCU&WIFIS&1")
            }
        case "APP&U&WIFI":
            rerouted.open()
        case "APP&WPING":
            if rerouted.isOpen { pingedAfterReroute.open() }
        default:
            break
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let result = try await session.downloadOverWiFi(
        recordings,
        endpointOverride: server.endpoint,
        joiner: RecordingJoiner(shouldFail: false),
        readiness: WiFiReadiness(timeout: .seconds(10),
                                 pollInterval: .milliseconds(5),
                                 pingInterval: .milliseconds(40)))

    // The run only completed because a keepalive fired while the transfer sat
    // idle — the server was holding the payload until one did.
    #expect(result.isComplete)
    #expect(result.delivered.count == 2)
    let reroute = t.sent.firstIndex(of: "APP&U&WIFI")!
    let pingAfter = t.sent[reroute...].contains("APP&WPING")
    #expect(pingAfter)
    #expect(!t.sent.contains("APP&PING"))   // still not a real command

    // The keepalive is fire-and-forget so it can never hold the session's single
    // request slot — a `.busy` there would look like the device refusing a
    // second selection. Its `MCU&WPING` echoes are absorbed rather than left to
    // bury the genuine unmatched-frame diagnostic.
    await session.stop()
    var unmatched: [String] = []
    for await event in session.events {
        if case .unmatchedResponse(let frame) = event { unmatched.append(frame) }
    }
    #expect(!unmatched.contains("MCU&WPING"))
}
