// pocket-client/Tests/PocketClientTests/WiFiTransferTests.swift
//
// The control flow scripted here is the capture-verified sequence decoded
// from an HCI snoop of one complete app-driven sync:
// SHUT → WIFIS → WIFI (credentials reply) → WIFIO
// (AP start) → WIFIS polls to 2 → TCP connect (WIFIS 1) → U&<date>&<ts>
// selection → U&WIFI reroute → raw bytes on TCP → WIFIC ×2.
import Foundation
import Network
import Testing
@testable import PocketClient

/// Serves `payload` to the first TCP client, mimicking the device's raw push.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(payload: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
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
        port = p
    }

    var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    func stop() { listener.cancel() }
}

/// Thread-safe call counter for driving per-send response progressions.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

struct RecordingJoiner: HotspotJoining, @unchecked Sendable {
    let shouldFail: Bool
    final class Box: @unchecked Sendable { var joined: [String] = []; var left = 0 }
    let box = Box()

    func join(ssid: String, passphrase: String) async throws {
        if shouldFail { throw PocketError.wifiJoinFailed("test") }
        box.joined.append(ssid)
    }
    func leave() async { box.left += 1 }
}

private let recording = RecordingInfo(
    id: RecordingID(date: "2026-01-04", timestamp: "20260104101500"),
    durationSeconds: 400)   // ~1.6 MB estimated → .auto picks WiFi

/// Readiness tuning for tests: fast polls, pings effectively off.
/// (Internal, not private: StreamingDownloadTests drives the same flow.)
let fastReadiness = WiFiReadiness(timeout: .seconds(5),
                                  pollInterval: .milliseconds(10),
                                  pingInterval: .seconds(60))

/// The scripted request/response pairs common to every WiFi flow test —
/// everything except the `APP&WIFIS` state progression, which is per-test.
/// (Internal, not private: StreamingDownloadTests drives the same flow.)
func scriptWiFiConversation(on t: FakeTransport) {
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&SHUT"] = []            // no reply on an idle device (live-probe verified)
    t.script["APP&WIFI"] = ["MCU&WIFI&PKT01_EXAMPLE&ExampleK"]
    t.script["APP&WIFIO"] = ["MCU&WIFIO"]
    t.script["APP&WPING"] = ["MCU&WPING"]
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&\(FakeTransport.goldenSize)"]
    // The capture shows the reroute acked as MCU&U&WIFI followed by a repeat
    // of the size announcement; the repeat must be tolerated (it surfaces as
    // an observational event, matching nothing).
    t.script["APP&U&WIFI"] = ["MCU&U&WIFI", "MCU&U&\(FakeTransport.goldenSize)"]
    t.script["APP&WIFIC"] = ["MCU&WIFIC"]
}

/// Scripts the `MCU&WIFIS&<n>` machine as the capture shows it: `0` for the
/// pre-flight query, `3` (AP up) for `apUpPolls` polls, then `2` (client
/// associated), then `1` (TCP connected) for every later poll.
/// (Internal, not private: StreamingDownloadTests drives the same flow.)
func scriptWIFIStateMachine(on t: FakeTransport, apUpPolls: Int = 1) {
    let calls = Counter()
    t.onSend = { wire, transport in
        guard wire == "APP&WIFIS" else { return }
        switch calls.next() {
        case 1:                              transport.emitResponse("MCU&WIFIS&0")
        case let n where n <= 1 + apUpPolls: transport.emitResponse("MCU&WIFIS&3")
        case 2 + apUpPolls:                  transport.emitResponse("MCU&WIFIS&2")
        default:                             transport.emitResponse("MCU&WIFIS&1")
        }
    }
}

@Test func wifiTransferRunsTheFullControlFlowAndFetchesBytes() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    let calls = Counter()
    t.onSend = { wire, transport in
        switch wire {
        case "APP&WIFIS":
            switch calls.next() {
            case 1:  transport.emitResponse("MCU&WIFIS&0")   // pre-flight: WiFi off
            case 2:  transport.emitResponse("MCU&WIFIS&3")   // after WIFIO: AP up
            case 3:  transport.emitResponse("MCU&WIFIS&2")   // phone associated
            default: transport.emitResponse("MCU&WIFIS&1")   // TCP client connected
            }
        case "APP&U&2026-01-04&20260104101500":
            // Selection briefly restarts BLE bulk (capture: ~15 KB leak out
            // before APP&U&WIFI reroutes it) — it must be discarded, never
            // mixed into the TCP-fetched file.
            transport.emitBulkChunked(Data(repeating: 0xEE, count: 1_000))
        default:
            break
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: joiner,
        readiness: fastReadiness)

    #expect(data == golden)
    #expect(joiner.box.joined == ["PKT01_EXAMPLE"])
    #expect(joiner.box.left == 1)

    // The exact frame order of the capture-verified sequence, end to end.
    #expect(t.sent == [
        "APP&SK&K",
        "APP&SHUT",                          // abort anything in flight (no reply)
        "APP&WIFIS",                         // pre-flight state query → 0
        "APP&WIFI",                          // credentials request → MCU&WIFI&<ssid>&<psk>
        "APP&WIFIO",                         // AP start — THIS is what precedes AP-up
        "APP&WIFIS",                         // poll → 3 (AP up)
        "APP&WIFIS",                         // poll → 2 (client associated)
        "APP&WIFIS",                         // post-connect confirmation → 1 (TCP connected)
        "APP&U&2026-01-04&20260104101500",   // recording selection …
        "APP&U&WIFI",                        // … then the reroute modifier
        "APP&WIFIC",
        "APP&WIFIC",
    ])
    // The invariants spelled out, independent of the full-array pin:
    // 1. APP&U&WIFI is a modifier — the selection must precede it.
    #expect(t.sent.firstIndex(of: "APP&U&2026-01-04&20260104101500")! <
            t.sent.firstIndex(of: "APP&U&WIFI")!)
    // 2. Credentials query and AP start are distinct steps, in that order,
    //    and both precede every readiness poll that observed the AP.
    let wifio = t.sent.firstIndex(of: "APP&WIFIO")!
    #expect(t.sent.firstIndex(of: "APP&WIFI")! < wifio)
    #expect(t.sent.lastIndex(of: "APP&WIFIS")! > wifio)
    // 3. APP&PING is not a real command and must never touch the wire.
    #expect(!t.sent.contains("APP&PING"))
    await session.stop()
}

/// While the association is pending, `APP&WPING` keepalives must flow so the
/// BLE link cannot idle out during a slow (possibly human-paced) join. The
/// keepalive frame is APP&WPING — APP&PING appears in no capture.
@Test func wpingKeepalivesFlowWhileWaitingForWiFiReadiness() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    scriptWIFIStateMachine(on: t, apUpPolls: 3)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: RecordingJoiner(shouldFail: false),
        readiness: WiFiReadiness(timeout: .seconds(5),
                                 pollInterval: .milliseconds(5),
                                 pingInterval: .zero))

    #expect(data == golden)
    #expect(t.sent.contains("APP&WPING"))
    #expect(!t.sent.contains("APP&PING"))
    await session.stop()
}

/// Lenient readiness: if the device never reports a joined client, the
/// transfer proceeds anyway after the bounded wait — but the fact is surfaced
/// on the event stream so the CLI (and the hardware checkpoint) can see it.
@Test func readinessTimeoutProceedsAnywayAndReportsNotObserved() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    let calls = Counter()
    t.onSend = { wire, transport in
        guard wire == "APP&WIFIS" else { return }
        // Off once, then forever "AP up, nobody joined".
        transport.emitResponse(calls.next() == 1 ? "MCU&WIFIS&0" : "MCU&WIFIS&3")
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: RecordingJoiner(shouldFail: false),
        readiness: WiFiReadiness(timeout: .milliseconds(50),
                                 pollInterval: .milliseconds(5),
                                 pingInterval: .seconds(60)))

    #expect(data == golden)   // lenient: the transfer still ran
    var events = session.events.makeAsyncIterator()
    #expect(await events.next() == .wifiReadinessNotObserved)
    await session.stop()
}

@Test func wifiJoinFailurePropagates() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    // The joiner's own text still leads the message; the diagnosis (asserted on
    // in its own tests below) is appended to it.
    var detail: String?
    do {
        _ = try await session.downloadOverWiFi(recording,
                                               endpointOverride: nil,
                                               joiner: RecordingJoiner(shouldFail: true))
        Issue.record("expected the join to fail")
    } catch PocketError.wifiJoinFailed(let thrown) {
        detail = thrown
    }
    #expect(detail?.hasPrefix("test — ") == true)
    // The AP was started (WIFIO went out) before the join could fail …
    #expect(t.sent.contains("APP&WIFIO"))
    // … so the failure closed it (best effort) instead of leaving it
    // broadcasting into the BLE fallback that this failure triggers.
    #expect(t.sent.filter { $0 == "APP&WIFIC" }.count == 1)
    // No selection was ever made on the failed attempt.
    #expect(!t.sent.contains("APP&U&2026-01-04&20260104101500"))
    #expect(!t.sent.contains("APP&U&WIFI"))
    // The failure path released the exclusive transfer slot.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

@Test func autoModeFallsBackToBLEWhenWiFiFails() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    t.onSend = { wire, transport in
        guard wire == "APP&U&2026-01-04&20260104101500" else { return }
        transport.emitBulkChunked(golden)
        transport.emitResponse("MCU&OFF")
    }
    let device = PocketDevice(transport: t, sessionKey: "K",
                              joiner: RecordingJoiner(shouldFail: true))
    try await device.connect()

    let data = try await device.download(recording, via: .auto)

    #expect(data == golden)   // WiFi failed, BLE served it
    await device.disconnect()
}

/// Explicit `.wifi` must surface the failure — the BLE fallback is `.auto` only.
@Test func explicitWiFiModeSurfacesTheFailureInsteadOfFallingBack() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    let device = PocketDevice(transport: t, sessionKey: "K",
                              joiner: RecordingJoiner(shouldFail: true))
    try await device.connect()

    var detail: String?
    do {
        _ = try await device.download(recording, via: .wifi)
        Issue.record("expected the join failure to surface")
    } catch PocketError.wifiJoinFailed(let thrown) {
        detail = thrown
    }
    #expect(detail?.hasPrefix("test — ") == true)
    // No BLE download was attempted.
    #expect(!t.sent.contains("APP&U&2026-01-04&20260104101500"))
    await device.disconnect()
}

/// WiFi transfers ride the same exclusive slot as BLE downloads and the live
/// stream: a WiFi transfer during a live stream must fail fast, before any
/// control traffic goes out.
@Test func wifiDownloadDuringLiveStreamFailsBusyWithoutTouchingTheWire() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let stream = try await session.liveAudio()

    await #expect(throws: PocketError.busy("transfer already in progress")) {
        _ = try await session.downloadOverWiFi(recording,
                                               endpointOverride: nil,
                                               joiner: RecordingJoiner(shouldFail: false))
    }
    #expect(!t.sent.contains("APP&SHUT"))   // rejected before any WiFi control traffic

    // The live stream is undisturbed.
    t.emitBulk(Data([0xAA, 0xBB]))
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == Data([0xAA, 0xBB]))
    await session.stop()
}

/// The WiFi flow must fail fast as `.emptyRecording` when the device announces
/// 0 bytes for the selection — before `APP&U&WIFI` tells it to serve the
/// socket — and must still close the AP and restore the operator's WiFi.
@Test func wifiZeroByteRecordingFailsFastAndStillLeavesTheAP() async throws {
    // The TCP connect precedes the selection in the real sequence, so the
    // endpoint must accept a connection even though no bytes ever flow.
    let server = try LoopbackServer(payload: Data())
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&U&2026-01-04&20260104101500"] = ["MCU&U&0"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    await #expect(throws: PocketError.emptyRecording) {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: server.endpoint,
                                               joiner: joiner, readiness: fastReadiness)
    }

    #expect(joiner.box.joined.count == 1)
    #expect(joiner.box.left == 1)   // cleanup ran despite the failure
    // The reroute modifier never went out for an empty selection.
    #expect(!t.sent.contains("APP&U&WIFI"))
    // Best-effort abort + close on the failure path (SHUT: initial + abort;
    // WIFIC: once, not the success path's two).
    #expect(t.sent.filter { $0 == "APP&SHUT" }.count == 2)
    #expect(t.sent.filter { $0 == "APP&WIFIC" }.count == 1)
    // The failure path released the exclusive transfer slot.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

/// TCP-ready cancels the WPING keepalive child while its request is armed
/// against a silent device — the winner-cancellation twin of the caller-
/// cancellation deadlock: the session's timeout child must fail the armed
/// waiter with `CancellationError` instead of leaving its continuation
/// pending, which wedged `connectKeepingLinkAlive` forever — holding the
/// transfer slot with the AP up. The injected `connect` completes only once
/// a WPING is on the wire, so the race is pinned, not sampled.
@Test func tcpReadyWhileAWpingRequestIsArmedDoesNotWedgeTheConnect() async throws {
    let t = FakeTransport()
    t.script["APP&SK&K"] = ["MCU&SK&OK"]
    t.script["APP&BAT"] = ["MCU&BAT&64"]
    // APP&WPING deliberately unscripted: the ping request arms and stays
    // unanswered, like a device that has stopped replying mid-join.
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let pingArmed = AsyncGate()
    t.onSend = { wire, _ in if wire == "APP&WPING" { pingArmed.open() } }

    let clock = ContinuousClock()
    let began = clock.now
    let connection = try await session.connectKeepingLinkAlive(
        to: WiFiEndpoint.default,
        readiness: WiFiReadiness(timeout: .seconds(30),
                                 pollInterval: .milliseconds(10),
                                 pingInterval: .milliseconds(10)),
        connect: { endpoint, _, _ in
            await pingArmed.wait()   // "ready" fires while the ping is armed
            return NWConnection(to: endpoint, using: .tcp)   // stand-in; never started
        })
    connection.cancel()
    // Prompt: well under the 2 s WPING request timeout and the 30 s connect
    // budget — the armed waiter was failed by cancellation, not waited out.
    #expect(clock.now - began < .seconds(1))

    // The request slot came back: a later request answers instead of `.busy`.
    let response = try await session.request(.battery) {
        if case .battery = $0 { true } else { false }
    }
    #expect(response == .battery(64))
    await session.stop()
}

// MARK: - Trailer past the announced length

/// Live hardware appends a short trailer to the TCP stream after the file
/// (10 surplus bytes observed in the field). The announced size is
/// authoritative — the BLE download of the same recording is byte-identical
/// at exactly that length — so the fetch must return exactly the announced
/// bytes and surface the surplus for diagnosis: not an error, not payload,
/// and never silently dropped. Two trailers: a plausible ASCII close frame
/// with CRLF, and the 10-byte surplus length seen on hardware.
@Test(arguments: [
    Data("MCU&OFF\r\n".utf8),     // realistic ASCII completion frame + CRLF (9 bytes)
    Data("MCU&WIFIC\n".utf8),     // 10 bytes — the field-observed surplus length
]) func wifiTransferTrimsToAnnouncedLengthAndSurfacesTheTrailer(trailer: Data) async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden + trailer)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    scriptWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: RecordingJoiner(shouldFail: false),
        readiness: fastReadiness)

    // Exactly the announced bytes, byte-identical to the golden fixture.
    #expect(data.count == FakeTransport.goldenSize)
    #expect(data == golden)

    // The surplus was surfaced on the event stream, not silently dropped.
    await session.stop()   // finishes the stream so the drain below terminates
    var surfaced: [DeviceEvent] = []
    for await event in session.events {
        if case .wifiTrailerReceived = event { surfaced.append(event) }
    }
    #expect(surfaced == [.wifiTrailerReceived(byteCount: trailer.count, preview: trailer)])
}

/// The retained surplus is bounded: a pathological peer that streams garbage
/// past the announced length yields a capped preview plus a true total count,
/// never an unbounded buffer.
@Test func tcpFetchCapsRetainedSurplusAtThePreviewLimit() async throws {
    let file = Data([0xFF, 0xF3]) + Data(repeating: 0xF3, count: 498)
    let surplus = Data((0..<200).map { UInt8($0 % 251) })
    let server = try LoopbackServer(payload: file + surplus)
    defer { server.stop() }

    let sink = TransferSink.memory()
    let connection = try await TCPFetch.connect(to: server.endpoint, timeout: .seconds(5))
    let received = try await TCPFetch.receive(on: connection, expected: file.count,
                                              idleTimeout: .seconds(5), into: sink,
                                              onProgress: nil)

    #expect(try sink.finalize(announced: file.count) == file)   // never more than announced
    #expect(received.surplusCount == surplus.count)             // full count reported …
    #expect(received.surplusPreview == surplus.prefix(TCPFetch.surplusPreviewLimit))   // … bytes capped
}

/// A stream that ends short of the announced length is still an under-read
/// failure — trimming applies to surplus only, never to truncation.
@Test func wifiTransferShortStreamStillFailsAsSizeMismatch() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: Data(golden.prefix(9000)))
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    scriptWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    await #expect(throws: PocketError.sizeMismatch(expected: FakeTransport.goldenSize, received: 9000)) {
        _ = try await session.downloadOverWiFi(recording,
                                               endpointOverride: server.endpoint,
                                               joiner: joiner,
                                               readiness: fastReadiness)
    }
    #expect(joiner.box.left == 1)   // cleanup ran despite the failure
    // The failure path released the exclusive transfer slot.
    try await session.beginTransfer()
    await session.endTransfer()
    await session.stop()
}

// MARK: - A failed join names its own most likely cause
//
// Rotating the session key rotates the AP password with it (VERIFIED on
// hardware 2026-07-28), so every host that has joined the AP before holds a
// stale credential — and both platforms report that as "unable to join", which
// is indistinguishable from the AP being down. These tests pin the one thing
// the package can add: the session key implies the AP password, so it can say
// whether the *device* is self-consistent.

/// The scripted device reports `ExampleK`; this key implies exactly that.
private let matchingKey = "ExampleKey000000"
/// 16 chars, and its first 8 (`RotatedK`) are NOT what the device reports.
private let disagreeingKey = "RotatedKey000000"

/// Nothing listens on port 1, so a connect there refuses immediately.
private let deadEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                               port: NWEndpoint.Port(rawValue: 1)!)

/// Readiness short enough that the association wait and the TCP connect both
/// resolve inside a test run.
private let briefReadiness = WiFiReadiness(timeout: .milliseconds(100),
                                           pollInterval: .milliseconds(5),
                                           pingInterval: .seconds(60))

@Test func theDiagnosisComparesTheReportedPasswordAgainstWhatTheKeyImplies() {
    #expect(WiFiJoinDiagnosis.of(reportedPassphrase: "ExampleK", derivedFromKey: "ExampleK")
            == .deviceCredentialsCurrent)
    #expect(WiFiJoinDiagnosis.of(reportedPassphrase: "ExampleK", derivedFromKey: "RotatedK")
            == .reportedPassphraseDiffers)
    // No key long enough to derive from: no comparison, and no pretending.
    #expect(WiFiJoinDiagnosis.of(reportedPassphrase: "ExampleK", derivedFromKey: nil)
            == .notComparable)

    // Each verdict must read differently — being able to tell them apart is the
    // entire point — and every one of them must name the manual repair, which
    // is the only repair there is.
    let texts = WiFiJoinDiagnosis.allCases.map { $0.guidance(ssid: "PKT01_EXAMPLE") }
    #expect(Set(texts).count == WiFiJoinDiagnosis.allCases.count)
    #expect(texts.allSatisfy { $0.contains("Forget PKT01_EXAMPLE in Wi-Fi settings") })
    #expect(texts.allSatisfy { $0.contains("Neither iOS nor macOS exposes an API") })
}

/// The key-derived password is `key[:8]`, and a key too short to derive from
/// yields nil rather than a comparison that would mean nothing.
@Test func theKeyImpliedAPPasswordIsTheFirstEightCharactersOfTheKey() async {
    let real = PocketSession(transport: FakeTransport(), sessionKey: matchingKey)
    #expect(await real.apPassphraseImpliedByKey == "ExampleK")
    let tooShort = PocketSession(transport: FakeTransport(), sessionKey: "K")
    #expect(await tooShort.apPassphraseImpliedByKey == nil)
}

/// PSK matches the key: the device is self-consistent, so the error says the
/// fault is this host's saved network — a much stronger statement than
/// "join failed".
@Test func aJoinFailureWithMatchingCredentialsBlamesTheHostsSavedNetwork() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()

    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: nil,
                                               joiner: RecordingJoiner(shouldFail: true))
        Issue.record("expected the join to fail")
    } catch PocketError.wifiJoinFailed(let thrown) {
        detail = thrown
    }

    #expect(detail.hasPrefix("test — "))   // the joiner's own text survives
    #expect(detail.contains("exactly what this session's key implies"))
    #expect(detail.contains("so the device's own credentials are current"))
    #expect(detail.contains("Forget PKT01_EXAMPLE in Wi-Fi settings"))
    // No credential is ever in the message: it must stay safe to paste into a
    // bug report.
    #expect(!detail.contains("ExampleK"))
    await session.stop()
}

/// PSK does not match the key. That is a finding about the firmware, NOT an
/// error and not this failure's cause: the join used the device's value, the
/// flow is unchanged, and the message says so instead of claiming the
/// credentials were confirmed.
@Test func aJoinFailureWithADisagreeingPasswordReportsItWithoutTreatingItAsTheFault() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(disagreeingKey)"] = ["MCU&SK&OK"]
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]
    let session = PocketSession(transport: t, sessionKey: disagreeingKey)
    try await session.start()

    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: nil,
                                               joiner: RecordingJoiner(shouldFail: true))
        Issue.record("expected the join to fail")
    } catch PocketError.wifiJoinFailed(let thrown) {
        detail = thrown
    }

    #expect(detail.hasPrefix("test — "))
    #expect(detail.contains("is not this session key's first 8 characters"))
    #expect(detail.contains("the join used the device's value, which is authoritative"))
    #expect(detail.contains("a firmware finding to record, not this failure's cause"))
    // Distinct guidance from the matching case — that is what makes it a
    // diagnosis rather than decoration.
    #expect(!detail.contains("exactly what this session's key implies"))
    // Still just a join failure, with the same repair offered.
    #expect(detail.contains("Forget PKT01_EXAMPLE in Wi-Fi settings"))
    await session.stop()
}

/// A synthetic host — what `getifaddrs` would have said. The one thing a hermetic
/// test cannot do is give the machine a real Wi-Fi interface on the recorder's
/// subnet, and the *absence* of such an interface is precisely what the pre-flight
/// has to get right, so the enumeration is a seam.
/// (Internal, not private: WiFiBatchTests presents the same hosts.)
func hostHolding(_ addresses: (interface: String, address: String)...) -> HostInterfaceLister {
    let held = addresses.map {
        HostInterfaceAddress(interfaceName: $0.interface, address: $0.address)
    }
    return { held }
}

/// The seam above is synthetic by necessity, so the real enumeration needs one
/// assertion of its own or the flag could be read from the wrong field and no test
/// would notice.
///
/// Loopback is the only interface every machine has and the only one whose state
/// is knowable without a radio: `lo0` is always up, always running, and always
/// holds `127.0.0.1`. That is enough to prove `IFF_RUNNING` is being read at all
/// and is not, say, `IFF_UP` a second time — which would make the whole
/// stale-address check answer "running" forever.
@Test func theSystemEnumerationReportsLoopbackAsRunningWithItsRealAddress() throws {
    let held = HostInterfaces.systemIPv4Addresses()
    let loopback = try #require(held.first { $0.interfaceName == "lo0" },
                                "every machine has lo0")
    #expect(loopback.address == "127.0.0.1")
    #expect(loopback.linkIsRunning)
}

/// The wired-default-route probe reads `NWPathMonitor`, so what it answers on any
/// given machine is that machine's business — but it must answer, promptly, and
/// never hang a transfer waiting for a monitor that has nothing to say.
@Test func theWiredDefaultRouteProbeAnswersWithinItsBound() async throws {
    let clock = ContinuousClock()
    let started = clock.now
    _ = await HostInterfaces.defaultPathIsWired(within: .milliseconds(200))
    // Generous against CI scheduling, and still far short of the 30 s connect it
    // sits in front of.
    #expect(clock.now - started < .seconds(3))
}

/// The same seam with `IFF_RUNNING` stated per interface — the one piece of
/// evidence that can contradict an address, and the condition macOS leaves behind
/// when a Wi-Fi interface disassociates but keeps its layer-3 configuration.
/// (Internal, not private: WiFiBatchTests presents the same hosts.)
func hostHoldingLinks(
    _ addresses: (interface: String, address: String, running: Bool)...
) -> HostInterfaceLister {
    let held = addresses.map {
        HostInterfaceAddress(interfaceName: $0.interface, address: $0.address,
                             linkIsRunning: $0.running)
    }
    return { held }
}

/// The macOS shape of the failure, and the pre-flight that ends it: no interface
/// on this host holds an address on the device's subnet, so this host is not on
/// the access point — a statement about *this process*, which `MCU&WIFIS&2` is
/// not (hardware confirmed a Mac auto-joining a remembered network satisfies that
/// check while proving nothing about this client).
///
/// That used to be a 30 s wait ending in a timeout that named nothing. It now
/// says so without attempting the connect at all, and names the network to join.
@Test func aHostOnNoneOfTheDevicesSubnetIsToldToJoinInsteadOfWaitingOutTheTimeout() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)   // the device even reports a client (2)
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()
    // A mesh VPN's utun carrying a default route, and a wired LAN. Neither is on
    // the loopback subnet this test's endpoint lives on — so, as far as this
    // process is concerned, this host is not on the recorder's network.
    await session.setHostInterfaces(hostHolding(("utun4", "100.64.0.2"),
                                                ("en1", "10.0.1.23")))

    let joiner = RecordingJoiner(shouldFail: false)
    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                               joiner: joiner, readiness: briefReadiness)
        Issue.record("expected the TCP connect to fail")
    } catch PocketError.transferFailed(let thrown) {
        detail = thrown
    }

    // Not attempted, rather than attempted and waited out — which is the whole
    // behaviour change, stated in the message itself.
    #expect(detail.contains("wifi tcp connect not attempted"))
    #expect(!detail.contains("timed out"))
    #expect(detail.contains("no interface on this host holds an address on the device's 127.0.0.0/24"))
    // The device said 2, and this host's own interfaces outrank that.
    #expect(detail.contains("THIS HOST is not on PKT01_EXAMPLE"))
    #expect(detail.contains("Join PKT01_EXAMPLE and run this again"))
    // A join this host silently failed is a stale saved password, so the repair
    // for one is the repair offered here.
    #expect(detail.contains("Forget PKT01_EXAMPLE in Wi-Fi settings"))
    // What the host DOES hold is named, so the reader can see what was looked at
    // — but reduced to its /24, because sync-wifi transcripts get pasted into a
    // public protocol reference and somebody's mesh address does not belong there.
    #expect(detail.contains("utun4 100.64.0.x"))
    #expect(detail.contains("en1 10.0.1.x"))
    #expect(!detail.contains("100.64.0.2"))
    #expect(!detail.contains("10.0.1.23"))
    #expect(joiner.box.left == 1)   // the AP was still left on the failure path
    await session.stop()
}

/// The counterpart: this host DOES hold an address on the endpoint's subnet, on a
/// running link, and nothing observed contradicts it — so what is left is the
/// path, and the failure quotes the reason Network.framework gave for not being
/// able to take it.
///
/// What this message must NOT do is overclaim, which for two releases it did: it
/// declared the association, the credentials and the access point's lifetime all
/// "settled and out of the picture" on the strength of an address, on the
/// reasoning that "a device that had closed its AP would not still be leasing
/// this address". macOS keeps the address after disassociating, so that reasoning
/// was false and the confident sentence built on it sent a hardware session
/// looking in the wrong place. Its absence is asserted below.
///
/// The reason is real, not injected: nothing listens on port 1, and a refused
/// connect on this platform surfaces as `.waiting(ECONNREFUSED)` — a non-terminal
/// state whose error the old handler discarded with `default: break`.
@Test func aConnectFailureFromAHostOnTheSubnetNamesTheInterfaceAndWhatTheFrameworkSaid()
    async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)   // reaches MCU&WIFIS&2
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()
    // The host layout that broke macOS: a tunnel with a default route alongside
    // the interface that actually reaches the endpoint.
    await session.setHostInterfaces(hostHolding(("utun4", "100.64.0.2"),
                                                ("lo0", "127.0.0.1")))

    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                               joiner: RecordingJoiner(shouldFail: false),
                                               readiness: briefReadiness)
        Issue.record("expected the TCP connect to fail")
    } catch PocketError.transferFailed(let thrown) {
        detail = thrown
    }

    #expect(detail.contains("wifi tcp connect"))   // the original symptom is kept
    // THE fix for defect 1: `.waiting(NWError)`'s payload reaches the message.
    // Reverting the capture leaves the timeout naming nothing, exactly as before.
    #expect(detail.contains("Network.framework's last reason:"))
    #expect(detail.contains("Connection refused"))
    // The interface that reaches the endpoint was chosen, and not the tunnel.
    #expect(detail.contains("lo0 holds 127.0.0.1 on the device's 127.0.0.0/24"))
    #expect(!detail.contains("utun4"))
    #expect(detail.contains("this host is CONFIGURED to reach the device directly "
                            + "(lo0 holds 127.0.0.1 on the device's subnet, and its link is "
                            + "running)"))
    // Neither of the two stories hardware has already eliminated.
    #expect(!detail.contains("Forget"))
    #expect(!detail.contains("The access point's lifetime"))
    // And none of the three claims an address cannot support. Each of these was
    // in the shipped text; each was wrong.
    #expect(!detail.contains("settled and out of the picture"))
    #expect(!detail.contains("would not still be leasing"))
    #expect(!detail.contains("the association and the credentials are settled"))
    await session.stop()
}

// MARK: - Ethernet, warned about before the join rather than after the failure
//
// Every macOS Wi-Fi transfer up to 2026-07-30 failed, and the cause turned out to
// be a network cable. The recorder's access point offers no internet; with a
// wired link carrying the default route, macOS associates with it and then drops
// the association, leaving address, netmask, route and ARP entry in place — so
// the host looks joined from every angle this process can see and nothing reaches
// the device. Unplugging Ethernet was what made the first transfer work.
//
// It cost several hardware rounds to find, so the operator is told at the moment
// they can act on it: in the join instructions, above the Wi-Fi steps.

/// The instructions are built as a value rather than written straight to stdout
/// precisely so this can be asserted. The Ethernet paragraph leads, names the
/// action, and says what it costs to skip — and it is absent when there is no
/// wired default route to warn about, because a warning that is always printed is
/// one nobody reads.
@Test func theJoinInstructionsWarnAboutEthernetOnlyWhenAWiredDefaultRouteExists() throws {
    let warned = ManualHotspotJoiner.instructions(ssid: "PKT01_EXAMPLE",
                                                  passphrase: "ExampleK",
                                                  wiredDefaultRoute: true)
    #expect(warned.contains("UNPLUG ETHERNET FIRST"))
    #expect(warned.contains("offers no internet"))
    #expect(warned.contains("silently DROP the"))
    #expect(warned.contains("keeping the address, the route and the ARP entry"))
    // Above the Wi-Fi steps: the point is that it is acted on before the join,
    // not read afterwards in a failure report.
    let unplug = try #require(warned.range(of: "UNPLUG ETHERNET FIRST"))
    let joinStep = try #require(warned.range(of: "Open System Settings > Wi-Fi"))
    #expect(unplug.lowerBound < joinStep.lowerBound)

    let quiet = ManualHotspotJoiner.instructions(ssid: "PKT01_EXAMPLE",
                                                 passphrase: "ExampleK",
                                                 wiredDefaultRoute: false)
    #expect(!quiet.contains("UNPLUG ETHERNET"))
    #expect(!quiet.contains("Ethernet"))
    // Everything else the operator needs is unchanged either way.
    for text in [warned, quiet] {
        #expect(text.contains("Join the network named:  PKT01_EXAMPLE"))
        #expect(text.contains("waiting for return…"))
    }
}

/// And the joiner asks before it prints, so the warning is part of the
/// instructions rather than a line racing them from somewhere else. The real
/// answer comes from `NWPathMonitor` and therefore from whatever network the test
/// machine is on, so the probe is a seam.
@Test func theJoinerConsultsTheWiredDefaultRouteBeforePrompting() async throws {
    let asked = Counter()
    let joiner = ManualHotspotJoiner(wiredDefaultRoute: { _ = asked.next(); return false })
    // `readLine()` on a closed/empty stdin returns nil immediately under the test
    // runner, so this does not block.
    try await joiner.join(ssid: "PKT01_EXAMPLE", passphrase: "ExampleK")
    #expect(asked.next() == 2)   // 1 for the join, and this call is the 2nd
}

/// The defect the 2026-07-30 hardware session exposed, in the smallest form that
/// reproduces it: an interface holding an address on the device's subnet while the
/// link under it is NOT running.
///
/// That is what macOS leaves behind after a Wi-Fi interface disassociates — it
/// keeps the address, the netmask, the route and the ARP entry — so *every* run
/// that ever joined the recorder leaves a configuration that satisfies the
/// pre-flight, and it is most likely to be stale exactly when somebody is testing
/// repeatedly. The pre-flight still pins the interface (there is no other
/// candidate, and pinning is what makes the framework answer promptly), but the
/// diagnosis must say the address is a leftover instead of declaring the
/// association settled.
@Test func anAddressOnALinkThatIsNotRunningIsReportedAsALeftoverNotAnAssociation()
    async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)   // the device even reports a client (2)
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()
    await session.setHostInterfaces(hostHoldingLinks(("lo0", "127.0.0.1", false)))

    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                               joiner: RecordingJoiner(shouldFail: false),
                                               readiness: briefReadiness)
        Issue.record("expected the TCP connect to fail")
    } catch PocketError.transferFailed(let thrown) {
        detail = thrown
    }

    // The address is named, and immediately disowned as evidence.
    #expect(detail.contains("lo0 holds 127.0.0.1 on the device's subnet, but that address is NOT "
                            + "evidence that this host is on PKT01_EXAMPLE"))
    #expect(detail.contains("lo0 is UP but not RUNNING"))
    #expect(detail.contains("macOS keeps the address, the netmask, the route and the ARP entry"))
    #expect(detail.contains("Rejoin PKT01_EXAMPLE and run this again"))
    // The repair that cost a whole hardware session to find.
    #expect(detail.contains("If a network cable is plugged into this Mac, unplug it"))
    // And never the sentence this replaces.
    #expect(!detail.contains("settled and out of the picture"))
    #expect(!detail.contains("would not still be leasing"))
    await session.stop()
}

/// The other way an address is contradicted, and the one that was accurate
/// throughout the failing hardware run while this package's own prose was not:
/// Network.framework reporting `ENETDOWN` for a connection it was **required** to
/// carry on the interface holding that address.
///
/// Read only when the constraint was actually applied. Unpinned, `ENETDOWN` could
/// be about some other interface; pinned to an interface that holds an address on
/// the destination's own `/24`, "the destination is unreachable from here" is
/// excluded by construction, so what is left is the interface not being on a
/// network. Driven through `WiFiConnectDiagnosis` directly — the state sequence a
/// failing run produces, with no radio.
@Test func networkFrameworksOwnDownNetworkReasonOutranksThisPackagesInference() throws {
    let running = HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2")
    let down = String(describing: NWError.posix(.ENETDOWN))

    // Pinned to that interface, ENETDOWN says the interface is not on a network.
    let verdict = try #require(WiFiConnectDiagnosis.contradictionOfAddress(
        running, waitingReason: down, interfaceWasRequired: true))
    #expect(verdict.contains("Network.framework reported the network down"))
    #expect(verdict.contains("required to carry on en0"))
    #expect(verdict.contains("it means the interface is not on a network"))

    // Unpinned it says nothing about THIS interface, so it is not read: an
    // unconstrained connection's ENETDOWN can be about any path the framework
    // considered.
    #expect(WiFiConnectDiagnosis.contradictionOfAddress(
        running, waitingReason: down, interfaceWasRequired: false) == nil)

    // The neighbours it must not swallow: a host that answered, and a route with
    // nothing on the other end. Both leave the address uncontradicted.
    for reason in [NWError.posix(.ECONNREFUSED), NWError.posix(.EHOSTUNREACH)] {
        #expect(WiFiConnectDiagnosis.contradictionOfAddress(
            running, waitingReason: String(describing: reason),
            interfaceWasRequired: true) == nil)
    }
    // And silence is not evidence either — the framework giving no reason at all
    // is a finding, never a licence to declare the host unassociated.
    #expect(WiFiConnectDiagnosis.contradictionOfAddress(
        running, waitingReason: nil, interfaceWasRequired: true) == nil)

    // The link flag needs no framework reason at all, and outranks a benign one.
    let stalled = HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2",
                                       linkIsRunning: false)
    #expect(WiFiConnectDiagnosis.contradictionOfAddress(
        stalled, waitingReason: nil, interfaceWasRequired: false)?
        .contains("UP but not RUNNING") == true)
}

/// The verbose channel. `.waiting` repeats as conditions change, so the thrown
/// message keeps the most recent reason and the whole transition sequence goes to
/// the event stream, where a harness transcript picks it up.
@Test func theConnectPathEventCarriesEveryStateTheAttemptPassedThrough() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()
    await session.setHostInterfaces(hostHolding(("lo0", "127.0.0.1")))

    _ = try? await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                            joiner: RecordingJoiner(shouldFail: false),
                                            readiness: briefReadiness)
    await session.stop()   // finishes the stream so the drain below terminates

    var reported: [String] = []
    for await event in session.events {
        if case .wifiConnectPath(let line) = event { reported.append(line) }
    }
    // One line before the attempt saying what this host made it decide …
    #expect(reported.contains { $0.contains("wifi tcp connect will require lo0") })
    // … and one after it with every state, in order, each `.waiting` carrying the
    // reason the thrown message quotes only once.
    let path = try #require(reported.first { $0.contains("states:") })
    #expect(path.contains("preparing"))
    #expect(path.contains("waiting("))
    #expect(path.contains("Connection refused"))
}

/// The watcher directly, with the exact state sequence a failing run produces —
/// no radio, no access point. `.waiting` repeats, so the *most recent* reason is
/// the diagnosis the message carries and the sequence keeps all of them.
@Test func theConnectWatcherKeepsTheLastWaitingReasonAndTheWholeSequence() throws {
    let watcher = WiFiConnectWatcher()
    #expect(watcher.observe(.setup) == .keepWaiting)
    #expect(watcher.observe(.preparing) == .keepWaiting)
    #expect(watcher.observe(.waiting(.posix(.EHOSTUNREACH))) == .keepWaiting)
    #expect(watcher.observe(.preparing) == .keepWaiting)
    #expect(watcher.observe(.waiting(.posix(.ENETDOWN))) == .keepWaiting)

    let reason = try #require(watcher.lastWaitingReason)
    #expect(reason.contains("Network is down"))
    // The POSIX code is kept, not flattened to a localised sentence: ENETDOWN (50)
    // is a path with no usable route, EHOSTUNREACH (65) is a route with nothing on
    // the far end, and telling those apart is the point.
    #expect(reason.contains("50"))
    #expect(watcher.transitions == ["setup", "preparing",
                                    "waiting(\(String(describing: NWError.posix(.EHOSTUNREACH))))",
                                    "preparing",
                                    "waiting(\(String(describing: NWError.posix(.ENETDOWN))))"])

    let pin = WiFiPathPin.interface(
        HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2"),
        deviceSubnet: "192.168.200", alsoOnSubnet: [])
    let failure = watcher.failure("wifi tcp connect timed out after 30.0 seconds",
                                  pin: pin, pinnedInterface: "en0")
    // The message: the symptom, the interface required, the latest reason — and
    // not the superseded one, which would read as the current state of the world.
    #expect(failure.detail.hasPrefix("wifi tcp connect timed out after 30.0 seconds — "))
    #expect(failure.detail.contains("the connection required en0, which holds 192.168.200.2 "
                                    + "on the device's 192.168.200.0/24"))
    #expect(failure.detail.contains("Network is down"))
    #expect(!failure.detail.contains("No route to host"))
    // The verbose line keeps both, in the order they happened.
    #expect(failure.pathReport.contains("No route to host"))
    #expect(failure.pathReport.contains("Network is down"))
    #expect(failure.pathReport.contains("setup -> preparing -> waiting("))
}

/// The terminal states the watcher must still resolve, and the shape of the
/// symptom it hands each of them.
@Test func theConnectWatcherResolvesTheTerminalStates() {
    #expect(WiFiConnectWatcher().observe(.ready) == .ready)
    #expect(WiFiConnectWatcher().observe(.cancelled) == .cancelled)
    let failed = WiFiConnectWatcher().observe(.failed(.posix(.ECONNREFUSED)))
    guard case .failed(let symptom) = failed else {
        Issue.record("expected .failed to be terminal")
        return
    }
    #expect(symptom.hasPrefix("wifi tcp connect failed: "))
    // A connect that never reached `.waiting` has no reason to report, and says
    // so rather than inventing one — which is itself the signature of
    // Network.framework's path evaluation failing silently.
    let watcher = WiFiConnectWatcher()
    _ = watcher.observe(.preparing)
    #expect(watcher.lastWaitingReason == nil)
    #expect(watcher.failure("wifi tcp connect timed out after 30.0 seconds",
                            pin: .noSubnetToCompare,
                            pinnedInterface: nil).detail.contains("last reason") == false)
}

/// The choice itself: the device's address is a fixed constant on a directly
/// connected `/24`, so the interface holding an address on that `/24` is the one
/// that can reach it — and a tunnel holding a default route is not, however
/// attractive it looks to a path evaluator.
@Test func thePinPicksTheInterfaceHoldingAnAddressOnTheDevicesSubnet() {
    let recorderInterface = HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2")
    let tunnel = HostInterfaceAddress(interfaceName: "utun4", address: "100.64.0.2")
    let wired = HostInterfaceAddress(interfaceName: "en1", address: "10.0.1.23")

    #expect(WiFiPathPin.choose(reaching: WiFiEndpoint.default,
                               among: [tunnel, wired, recorderInterface])
            == .interface(recorderInterface, deviceSubnet: "192.168.200", alsoOnSubnet: []))
    // Nothing on the device's subnet: this host is not on the access point, and
    // the connect must not be attempted at all.
    #expect(WiFiPathPin.choose(reaching: WiFiEndpoint.default, among: [tunnel, wired])
            == .hostNotOnTheDeviceSubnet(deviceSubnet: "192.168.200", held: [tunnel, wired]))
    #expect(WiFiPathPin.choose(reaching: WiFiEndpoint.default, among: [])
            == .hostNotOnTheDeviceSubnet(deviceSubnet: "192.168.200", held: []))
    // Nothing to compare against — a hostname endpoint — leaves it unpinned and
    // reasoning from the device's report alone, exactly as before this existed.
    #expect(WiFiPathPin.choose(reaching: .hostPort(host: "recorder.local", port: 8475),
                               among: [recorderInterface]) == .noSubnetToCompare)
}

/// A tie is real ambiguity, not a free choice: an RFC1918 `/24` is not globally
/// unique, so two interfaces sharing one can be on two different physical
/// networks with only one of them reaching the device — this development host has
/// `en0` and `en7` both on `192.168.1.x` right now. First match wins because it is
/// deterministic, and the losers are carried and named so a transfer that fails
/// because the wrong one was chosen says which others there were.
@Test func aTieOnTheDeviceSubnetIsCarriedAndNamedRatherThanQuietlyResolved() {
    let first = HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2")
    let second = HostInterfaceAddress(interfaceName: "en7", address: "192.168.200.9")
    let pin = WiFiPathPin.choose(reaching: WiFiEndpoint.default, among: [first, second])
    #expect(pin == .interface(first, deviceSubnet: "192.168.200", alsoOnSubnet: [second]))
    #expect(pin.interfaceName == "en0")   // deterministic: enumeration order

    // Named before the attempt …
    #expect(pin.summary.contains("AMBIGUOUS"))
    #expect(pin.summary.contains("en7 192.168.200.9"))
    // … and in the failure, where a reader deciding what to suspect will see it.
    let failure = WiFiConnectWatcher().failure("wifi tcp connect timed out after 30.0 seconds",
                                               pin: pin, pinnedInterface: "en0")
    #expect(failure.detail.contains("it was not the only candidate"))
    #expect(failure.detail.contains("en7 192.168.200.9"))
    // The ordinary case says none of this.
    let unambiguous = WiFiPathPin.choose(reaching: WiFiEndpoint.default, among: [first])
    #expect(!unambiguous.summary.contains("AMBIGUOUS"))
    #expect(!WiFiConnectWatcher().failure("x", pin: unambiguous, pinnedInterface: "en0")
        .detail.contains("not the only candidate"))
}

/// The subnet is derived from `deviceHost`, not written down a second time: a
/// subnet spelled twice is a subnet that can disagree with itself.
@Test func theDeviceSubnetIsDerivedFromTheDeviceHost() throws {
    let subnet = try #require(WiFiEndpoint.deviceSubnet)
    #expect(WiFiEndpoint.deviceHost.hasPrefix(subnet + "."))
    #expect(WiFiEndpoint.clientSubnet == subnet + ".x")
    #expect(WiFiEndpoint.ipv4SubnetPrefix(of: "10.0.0.7") == "10.0.0")
    #expect(WiFiEndpoint.ipv4SubnetPrefix(of: "192.168.300.1") == nil)   // 300 is not an octet
    #expect(WiFiEndpoint.ipv4SubnetPrefix(of: "recorder.local") == nil)
    #expect(WiFiEndpoint.ipv4Host(of: WiFiEndpoint.default) == WiFiEndpoint.deviceHost)
    #expect(WiFiEndpoint.ipv4Host(of: .hostPort(host: "recorder.local", port: 8475)) == nil)
    #expect(WiFiEndpoint.ipv4Host(of: .unix(path: "/tmp/x")) == nil)
}

/// What the pin builds for Network.framework, and — as importantly — what it does
/// **not** build. `requiredInterface` is the whole pin: measured as strictly
/// enforced on this SDK, unlike `requiredLocalEndpoint`, which was ignored
/// outright. Nothing else is set, so a connection that could not be pinned is a
/// plain `NWParameters.tcp` and nothing more.
@Test func thePinnedParametersRequireTheInterfaceAndConstrainNothingElse() {
    let physical = WiFiPathPin.interface(
        HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2"),
        deviceSubnet: "192.168.200", alsoOnSubnet: [])
    #expect(physical.interfaceName == "en0")
    #expect(WiFiPathPin.noSubnetToCompare.interfaceName == nil)

    // No pin: byte for byte the parameters that shipped before any of this
    // existed. An earlier version prohibited interface *types* here, inferred
    // from the chosen interface's name — an inference that bought nothing where
    // the pin applied and could prohibit the needed interface where it did not,
    // arriving as a silent `.waiting` that reads exactly like the defect being
    // fixed. It is gone, and this is what holds it gone.
    for pin in [WiFiPathPin.noSubnetToCompare, physical] {
        let parameters = pin.tcpParameters(requiring: nil)
        #expect(parameters.requiredInterface == nil)
        #expect(parameters.prohibitedInterfaceTypes == nil)
        #expect(parameters.prohibitedInterfaces == nil)
        #expect(parameters.requiredLocalEndpoint == nil)
    }
}

/// The last mile of the parameter builder, which no synthetic value can reach:
/// `NWInterface` has no public initializer, so the only one that exists comes
/// from a live `NWPath`. What this cannot show is that `connect` *uses* what the
/// builder returns — see `theConnectAppliesThePinToTheSocketItOpens`, which does.
///
/// Passive: `NWPathMonitor` reads the system's own path state and sends nothing.
/// A host that lists no interface at all cannot exercise a pin, and this says so
/// rather than passing while asserting nothing.
@Test func requiringAnInterfaceTheFrameworkListsIsAppliedToTheParameters() async throws {
    let listed = await HostInterfaces.availableInterfaces(within: .milliseconds(500))
    let interface = try #require(
        listed.first,
        "this host lists no available network interface, so the pin cannot be exercised")
    let pin = WiFiPathPin.interface(
        HostInterfaceAddress(interfaceName: interface.name, address: "192.168.200.2"),
        deviceSubnet: "192.168.200", alsoOnSubnet: [])
    #expect(pin.tcpParameters(requiring: interface).requiredInterface == interface)
}

/// **The pin, proved on the socket `TCPFetch.connect` actually opens** — not on
/// the parameters a builder hands back.
///
/// Every other integration test here reaches its endpoint over loopback, and
/// Network.framework does not list the loopback interface, so the chosen
/// interface resolves to nil and the parameters are indistinguishable from a
/// plain `.tcp`. That made the headline fix invisible: reverting the connect to
/// `NWConnection(to: endpoint, using: .tcp)`, or collapsing the interface lookup
/// to nil, passed the entire suite. A test that survives its own mutation is the
/// defect.
///
/// So this observes the pin's *effect* instead. Requiring an interface that
/// cannot carry loopback traffic must make a connect to a live loopback listener
/// fail, while the identical connect with nothing required succeeds — a causal
/// pair, because only a connection that really was constrained can fail against a
/// listener that is demonstrably up. Measured behaviour, not a guess: requiring
/// `en0` of a loopback destination sits in
/// `.waiting(POSIXErrorCode 50: Network is down)`.
@Test func theConnectAppliesThePinToTheSocketItOpens() async throws {
    let server = try LoopbackServer(payload: Data([0xFF, 0xF3]))
    defer { server.stop() }

    // Any interface Network.framework lists. None of them is loopback — that is
    // the whole reason the loopback tests go unpinned — so none of them can carry
    // a connection to 127.0.0.1.
    let listed = await HostInterfaces.availableInterfaces(within: .milliseconds(500))
    let carrier = try #require(
        listed.first { $0.type != .loopback },
        "this host lists no non-loopback interface, so an applied pin cannot be distinguished")

    // Claim that interface holds the endpoint's own address, so `choose` picks it
    // and `connect` is obliged to require it.
    let pin = WiFiPathPin.choose(
        reaching: server.endpoint,
        among: [HostInterfaceAddress(interfaceName: carrier.name, address: "127.0.0.1")])
    #expect(pin.interfaceName == carrier.name)

    // Required interface cannot reach loopback ⇒ no socket, and the failure
    // records which interface was required of it.
    var failure: WiFiConnectFailure?
    do {
        let unexpected = try await TCPFetch.connect(to: server.endpoint,
                                                    timeout: .milliseconds(600), pin: pin)
        unexpected.cancel()
        Issue.record("the connect ignored the required interface and connected anyway")
    } catch let thrown as WiFiConnectFailure {
        failure = thrown
    }
    #expect(try #require(failure).pinnedInterface == carrier.name)

    // The control, and what makes the pair causal: the same endpoint, the same
    // listener, nothing required — connects at once.
    let connected = try await TCPFetch.connect(to: server.endpoint, timeout: .seconds(5),
                                               pin: .noSubnetToCompare)
    connected.cancel()
}

// MARK: - The pre-flight's wait for an address that has not arrived yet
//
// This window is the only thing standing between an iOS join whose DHCP has not
// completed and a hard refusal, and iOS is the path that works today. A
// regression there would be worse than the bug being fixed, so it gets tests that
// go red if it is removed.

/// Readiness that resolves inside a test run and makes the two budgets — the
/// short one for a host that is simply elsewhere, the full one for a join still
/// being refused a lease — far enough apart to tell apart.
private let preFlightReadiness = WiFiReadiness(timeout: .milliseconds(500),
                                               pollInterval: .milliseconds(5),
                                               pingInterval: .seconds(60),
                                               hostAddressWait: .milliseconds(50))

/// The grace window itself: an address that shows up a few looks late — DHCP
/// completing after `NEHotspotConfiguration.apply` has already returned — is
/// waited for, not refused.
@Test func thePreFlightWaitsForAnAddressThatArrivesLate() async {
    let session = PocketSession(transport: FakeTransport(), sessionKey: "K")
    let leased = HostInterfaceAddress(interfaceName: "en0", address: "127.0.0.1")
    let looks = Counter()
    await session.setHostInterfaces { looks.next() < 3 ? [] : [leased] }

    let pin = await session.resolveWiFiPathPin(to: deadEndpoint, readiness: preFlightReadiness)

    #expect(pin == .interface(leased, deviceSubnet: "127.0.0", alsoOnSubnet: []))
    await session.stop()
}

/// And the other side of it: a host that is simply not on the network is answered
/// in `hostAddressWait`, not made to sit out the whole connect budget. The 30 s
/// timeout this replaced is the behaviour being removed.
@Test func thePreFlightGivesUpQuicklyOnAHostThatIsSimplyElsewhere() async {
    let session = PocketSession(transport: FakeTransport(), sessionKey: "K")
    await session.setHostInterfaces(hostHolding(("en1", "10.0.1.23")))

    let clock = ContinuousClock()
    let began = clock.now
    let pin = await session.resolveWiFiPathPin(to: deadEndpoint, readiness: preFlightReadiness)
    let elapsed = clock.now - began

    #expect(pin == .hostNotOnTheDeviceSubnet(
        deviceSubnet: "127.0.0",
        held: [HostInterfaceAddress(interfaceName: "en1", address: "10.0.1.23")]))
    // Comfortably inside the 500 ms connect budget: the short answer was taken.
    #expect(elapsed < .milliseconds(250))
    await session.stop()
}

/// The budget is evidence-driven rather than a timing guess. A self-assigned
/// 169.254 address means this host associated with an access point and is still
/// being refused a lease — a join trying, not a host elsewhere — so it earns the
/// full connect budget instead of the short one. It can never exceed that budget,
/// so this still never waits longer than the connect it replaced.
@Test func thePreFlightKeepsWaitingWhileDHCPIsStillBeingRefused() async {
    let session = PocketSession(transport: FakeTransport(), sessionKey: "K")
    await session.setHostInterfaces(hostHolding(("en0", "169.254.12.34")))

    let clock = ContinuousClock()
    let began = clock.now
    let pin = await session.resolveWiFiPathPin(to: deadEndpoint, readiness: preFlightReadiness)
    let elapsed = clock.now - began

    #expect(pin == .hostNotOnTheDeviceSubnet(
        deviceSubnet: "127.0.0",
        held: [HostInterfaceAddress(interfaceName: "en0", address: "169.254.12.34")]))
    // Well past the 50 ms short budget — it held on for the full 500 ms one.
    #expect(elapsed > .milliseconds(250))
    #expect(elapsed < .seconds(2))
    await session.stop()
}

/// A host in that state is joined — the password was accepted — and unleased. The
/// repair is renewing the lease, and telling somebody to forget the network would
/// send them to re-enter a credential that was never the problem.
@Test func aHostWithOnlyASelfAssignedAddressIsToldToRenewItsLease() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()
    await session.setHostInterfaces(hostHolding(("en0", "169.254.12.34")))

    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                               joiner: RecordingJoiner(shouldFail: false),
                                               readiness: briefReadiness)
        Issue.record("expected the pre-flight to refuse")
    } catch PocketError.transferFailed(let thrown) {
        detail = thrown
    }

    #expect(detail.contains("wifi tcp connect not attempted"))
    #expect(detail.contains("self-assigned 169.254.x.x address on en0"))
    #expect(detail.contains("it DID associate with an access point"))
    #expect(detail.contains("Renew DHCP Lease"))
    // Emphatically not the credential repair: the password was accepted.
    #expect(!detail.contains("Forget"))
    #expect(!detail.contains("Join PKT01_EXAMPLE and run this again"))
    await session.stop()
}

/// Network.framework's own interface list is the only source of `NWInterface`
/// values, and a name it does not list must resolve to nil promptly rather than
/// holding the connect up — the fallback every loopback test here takes, since
/// loopback is legitimately absent from that list.
@Test func anInterfaceNetworkFrameworkDoesNotListResolvesToNilPromptly() async {
    let clock = ContinuousClock()
    let began = clock.now
    let resolved = await HostInterfaces.availableInterface(named: "pocket-nonexistent0",
                                                          within: .milliseconds(200))
    #expect(resolved == nil)
    #expect(clock.now - began < .seconds(2))
}

/// The iOS shape, which works today and must not regress: the process joined the
/// network itself, so an interface of its own holds an address on the device's
/// subnet — and a mesh VPN's utun is up alongside it, exactly the host layout that
/// broke macOS. The transfer completes, pinned to the interface that can reach the
/// endpoint.
@Test func aHostHoldingTheDeviceSubnetAddressStillCompletesTheTransfer() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    scriptWIFIStateMachine(on: t)
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()
    await session.setHostInterfaces(hostHolding(("utun4", "100.64.0.2"),
                                                ("lo0", "127.0.0.1")))

    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: RecordingJoiner(shouldFail: false),
        readiness: fastReadiness)

    #expect(data == golden)
    await session.stop()
    var reported: [String] = []
    for await event in session.events {
        if case .wifiConnectPath(let line) = event { reported.append(line) }
    }
    #expect(reported.contains {
        $0.contains("will require lo0") && $0.contains("127.0.0.1 on the device's 127.0.0.0/24")
    })
    // No failure, so no transition dump — the verbose line is for failures.
    #expect(!reported.contains { $0.contains("states:") })
}

/// Redaction. The message has to say what it looked at, and these transcripts get
/// pasted into a public protocol reference: an address on the device's own subnet
/// is printed in full (that subnet is the recorder's and already written down
/// here), everything else is reduced to its `/24`.
@Test func theHostsOwnAddressesAreReducedToSubnetsExceptOnTheDevicesOwn() {
    let summary = WiFiPathPin.summarize(
        [HostInterfaceAddress(interfaceName: "en0", address: "192.168.200.2"),
         HostInterfaceAddress(interfaceName: "utun4", address: "100.64.0.2"),
         HostInterfaceAddress(interfaceName: "en1", address: "10.0.1.23")],
        deviceSubnet: "192.168.200")
    #expect(summary == "en0 192.168.200.2, utun4 100.64.0.x, en1 10.0.1.x")
    #expect(WiFiPathPin.summarize([], deviceSubnet: "192.168.200") == "no IPv4 address at all")
}

/// The third story the device can tell, and the one that made the earlier
/// diagnosis dangerous: it reported its WiFi **off** while this client was still
/// waiting for the association. The access point came down by itself, so no
/// credential this host holds could have mattered — and blaming one would send
/// the reader to forget a network for nothing.
@Test func aConnectFailureAfterTheDeviceReportedItsWiFiOffBlamesTheAccessPoint() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    t.script["APP&WIFIS"] = ["MCU&WIFIS&0"]   // the AP came down under us
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()

    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                               joiner: RecordingJoiner(shouldFail: false),
                                               readiness: briefReadiness)
        Issue.record("expected the TCP connect to fail")
    } catch PocketError.transferFailed(let thrown) {
        detail = thrown
    }

    #expect(detail.contains("wifi tcp connect"))
    #expect(detail.contains("the device reported its WiFi off (MCU&WIFIS&0)"))
    #expect(detail.contains("that is the device's doing, not a credential this host holds"))
    // The device itself said its AP had gone, which is the one verdict where the
    // lifetime is the subject — and it is now stated as a measurement rather than
    // as this failure's presumed cause.
    #expect(detail.contains("The access point's lifetime is measured, not a mystery"))
    #expect(detail.contains("about 59 s"))
    // Emphatically NOT the credential guidance: the device's own report rules it
    // out, and a confident wrong cause is worse than a bare error.
    #expect(!detail.contains("Forget"))
    #expect(!detail.contains("never reported a client on its AP"))
    await session.stop()
}

/// Every verdict must read differently — telling them apart is the point — and
/// only the two that are consistent with a silently rejected join may reach for
/// the credential repair, which is the mistake this type exists to prevent. The
/// access point's lifetime is now told in exactly one place: the verdict where the
/// device itself reported its WiFi off.
@Test func theConnectDiagnosisTellsItsVerdictsApart() {
    let hostSide = WiFiJoinDiagnosis.allCases.map { WiFiConnectDiagnosis.hostNotOnTheAccessPoint($0) }
    let deviceSide = WiFiJoinDiagnosis.allCases.map { WiFiConnectDiagnosis.nothingEverJoined($0) }
    let pathSide: [WiFiConnectDiagnosis] = [
        .pathUnusableFromThisHost(interface: "en0", address: "192.168.200.2",
                                  interfaceWasRequired: true,
                                  waitingReason: "POSIXErrorCode(rawValue: 50): Network is down"),
        .pathUnusableFromThisHost(interface: "en0", address: "192.168.200.2",
                                  interfaceWasRequired: true, waitingReason: nil),
        .pathUnusableFromThisHost(interface: "en0", address: "192.168.200.2",
                                  interfaceWasRequired: false, waitingReason: nil),
    ]
    let all = hostSide + deviceSide + pathSide + [.accessPointClosedItself,
                                                  .associatedThenUnreachable,
                                                  .joinedButNeverLeased(interface: "en0")]
    let texts = all.map { $0.guidance(ssid: "PKT01_EXAMPLE") }
    #expect(Set(texts).count == texts.count)

    // The credential repair belongs to the two join-shaped verdicts and nowhere
    // else — six texts, three comparison outcomes each side.
    #expect(texts.filter { $0.contains("Forget PKT01_EXAMPLE in Wi-Fi settings") }.count
            == hostSide.count + deviceSide.count)
    // The lifetime story is told once, where the device said its AP had gone.
    #expect(texts.filter { $0.contains("The access point's lifetime is measured") }.count == 1)

    for text in hostSide.map({ $0.guidance(ssid: "PKT01_EXAMPLE") }) {
        #expect(text.contains("THIS HOST is not on PKT01_EXAMPLE"))
        #expect(text.contains("Join PKT01_EXAMPLE and run this again"))
        // The point of preferring it to MCU&WIFIS is stated, because it is the
        // reason three hardware runs read that check and learned nothing.
        #expect(text.contains("the device reports 2 for any associated client"))
        #expect(!text.contains("The access point's lifetime"))
    }
    for text in deviceSide.map({ $0.guidance(ssid: "PKT01_EXAMPLE") }) {
        #expect(text.contains("nothing joined PKT01_EXAMPLE"))
        #expect(!text.contains("The access point's lifetime"))
    }
    // The path verdict names the interface, and either quotes Network.framework's
    // reason or says outright that it gave none — which is itself the signature of
    // its path evaluation failing.
    let quoted = pathSide[0].guidance(ssid: "PKT01_EXAMPLE")
    #expect(quoted.contains("en0 holds 192.168.200.2"))
    #expect(quoted.contains("Network.framework's last reason for not proceeding was: "
                            + "POSIXErrorCode(rawValue: 50): Network is down"))
    #expect(!quoted.contains("Forget"))
    // Where the constraint WAS applied, blaming a VPN for owning the default
    // route would be a confident wrong cause: the constraint excludes it.
    #expect(quoted.contains("The connection WAS required to use en0"))
    #expect(quoted.contains("nothing else can have captured this path"))
    #expect(!quoted.contains("VPN or mesh client owning the default route is the first thing"))
    // Where it was NOT applied, that is exactly what to check first — and the
    // two must not say the same thing, which is the whole point of carrying it.
    let unpinned = pathSide[2].guidance(ssid: "PKT01_EXAMPLE")
    #expect(unpinned.contains("could NOT be required to use en0"))
    #expect(unpinned.contains("VPN or mesh client owning the default route is the first thing"))
    #expect(!unpinned.contains("nothing else can have captured this path"))
    // A join that associated and was never leased is its own story, with its own
    // repair, and must not reach for the credential one.
    let unleased = WiFiConnectDiagnosis.joinedButNeverLeased(interface: "en0")
        .guidance(ssid: "PKT01_EXAMPLE")
    #expect(unleased.contains("it DID associate with an access point"))
    #expect(unleased.contains("Renew DHCP Lease"))
    #expect(unleased.contains("Do NOT forget PKT01_EXAMPLE"))
    #expect(!unleased.contains("Forget PKT01_EXAMPLE in Wi-Fi settings"))
    let silent = pathSide[1].guidance(ssid: "PKT01_EXAMPLE")
    #expect(silent.contains("Network.framework never gave a reason at all"))
    #expect(silent.contains("as distinct from a refused connect (immediate)"))
}

// MARK: - The keepalive spans the join itself
//
// The defect this section exists for, in one line: on macOS `joiner.join` blocks
// on a human for about a minute, the keepalive that stops the device's access
// point idling out did not start until `join` returned, and so no Wi-Fi transfer
// from a Mac had ever completed. `wifi tcp connect timed out after 30.0 seconds`
// was the only symptom that reached the process; `No route to host` from ping and
// from nc, against a valid 192.168.200.x lease, was the diagnosis on the wire.

/// A joiner that **blocks its thread** for the whole join, exactly as
/// `ManualHotspotJoiner`'s `readLine()` does, and through the same production
/// hand-off — so a test using it exercises `runOffTheCooperativePool` rather than
/// a stand-in for it.
///
/// Released by `unblock()`, and otherwise by a bounded give-up, so a regression
/// FAILS this test instead of wedging the suite.
final class ThreadBlockingJoiner: HotspotJoining, @unchecked Sendable {
    /// Long enough that a ping interval a hundred times smaller cannot be missed
    /// by scheduling luck, short enough that a failing run still finishes.
    static let patience = DispatchTimeInterval.seconds(5)

    private let gate = DispatchSemaphore(value: 0)
    private let state = NSLock()
    private var releasedByPing = false
    private var observedThreadName: String?
    private var leaveCount = 0

    /// Lets the blocked join finish. Called from the transport's `onSend` when the
    /// keepalive ping appears — i.e. from another thread entirely, which is the
    /// arrangement under test.
    func unblock() { gate.signal() }

    /// True when the join ended because a ping arrived, not because it gave up.
    var wasReleasedByAPing: Bool { state.lock(); defer { state.unlock() }; return releasedByPing }
    /// The name of the thread the blocking work actually ran on.
    var threadName: String? { state.lock(); defer { state.unlock() }; return observedThreadName }
    var left: Int { state.lock(); defer { state.unlock() }; return leaveCount }

    func join(ssid: String, passphrase: String) async throws {
        await runOffTheCooperativePool {
            let released = self.gate.wait(timeout: .now() + Self.patience) == .success
            let name = Thread.current.name
            self.state.lock()
            self.releasedByPing = released
            self.observedThreadName = name
            self.state.unlock()
        }
    }

    func leave() async { recordLeave() }

    // Synchronous, like `SystemHotspotJoiner`'s accessors: NSLock's lock()/unlock()
    // are `noasync`, so an async method must reach the lock through a sync helper.
    private func recordLeave() { state.lock(); leaveCount += 1; state.unlock() }
}

/// A joiner that **suspends** rather than blocking, which is the programmatic
/// joiner's shape: `NEHotspotConfiguration.apply` occupies no thread but still
/// waits on a person tapping the iOS "wants to join" alert. Bounded the same way.
struct SuspendingJoiner: HotspotJoining {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var leaveCount = 0
        func markReleased() { lock.lock(); released = true; lock.unlock() }
        var wasReleasedByAPing: Bool { lock.lock(); defer { lock.unlock() }; return released }
        func markLeft() { lock.lock(); leaveCount += 1; lock.unlock() }
        var left: Int { lock.lock(); defer { lock.unlock() }; return leaveCount }
    }

    let pinged = AsyncGate()
    let box = Box()

    func join(ssid: String, passphrase: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if pinged.isOpen {
                box.markReleased()
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func leave() async { box.markLeft() }
}

/// The defect, pinned. `join` blocks its thread far longer than the ping
/// interval — the macOS shape, where somebody is in System Settings — and
/// `APP&WPING` must be on the wire *while it is still blocked*.
///
/// The proof is causal rather than sampled: the joiner is released **by the ping
/// itself**, so the run can only reach a successful transfer if a ping went out
/// during the join. Reverting the fix (starting the keepalive after `join`
/// instead of before it) makes `wasReleasedByAPing` false and the wire order
/// wrong — a failure, not a hang, because the block gives up after 5 s.
@Test func theKeepalivePingsWhileAThreadBlockingJoinIsStillWaiting() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    let joiner = ThreadBlockingJoiner()
    let polls = Counter()
    t.onSend = { wire, transport in
        switch wire {
        case "APP&WIFIS":
            // Off for the pre-flight query, associated for every later poll —
            // the polls only begin once the join has returned.
            transport.emitResponse(polls.next() == 1 ? "MCU&WIFIS&0" : "MCU&WIFIS&2")
        case "APP&WPING":
            joiner.unblock()   // the ping is what lets the join finish
        default:
            break
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: joiner,
        readiness: WiFiReadiness(timeout: .seconds(10),
                                 pollInterval: .milliseconds(5),
                                 pingInterval: .milliseconds(50)))

    #expect(data == golden)
    // The join ended because a keepalive arrived, not because it gave up.
    #expect(joiner.wasReleasedByAPing)
    // And the wire agrees: the ping falls after the AP started and BEFORE the
    // first association poll, and no poll can be issued until `join` returns —
    // so that window IS the join.
    let apStart = try #require(t.sent.firstIndex(of: "APP&WIFIO"))
    let ping = try #require(t.sent.firstIndex(of: "APP&WPING"))
    let associationPolls = t.sent.indices.filter { $0 > apStart && t.sent[$0] == "APP&WIFIS" }
    #expect(apStart < ping)
    #expect(!associationPolls.isEmpty)
    #expect(ping < associationPolls[0])
    // The blocking read never occupied a cooperative thread — the hand-off ran.
    #expect(joiner.threadName == blockingWorkThreadName)
    #expect(joiner.left == 1)
    #expect(!t.sent.contains("APP&PING"))   // still not a real command
    await session.stop()
}

/// The same protection for the programmatic joiner, which needs it for the same
/// reason and gets it for free: the keepalive starts before `join` is called at
/// all, so it covers any `HotspotJoining` that takes its time — this suspending
/// one, the blocking one, or a consumer's own. `NEHotspotConfiguration.apply` is
/// fast today, which is the only reason the phone path never hit this.
@Test func theKeepaliveAlsoPingsThroughASuspendingJoin() async throws {
    let golden = try FakeTransport.loadGoldenFixture()
    let server = try LoopbackServer(payload: golden)
    defer { server.stop() }

    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    let joiner = SuspendingJoiner()
    let polls = Counter()
    t.onSend = { wire, transport in
        switch wire {
        case "APP&WIFIS":
            transport.emitResponse(polls.next() == 1 ? "MCU&WIFIS&0" : "MCU&WIFIS&2")
        case "APP&WPING":
            joiner.pinged.open()
        default:
            break
        }
    }
    let session = PocketSession(transport: t, sessionKey: "K")
    try await session.start()

    let data = try await session.downloadOverWiFi(
        recording,
        endpointOverride: server.endpoint,
        joiner: joiner,
        readiness: WiFiReadiness(timeout: .seconds(10),
                                 pollInterval: .milliseconds(5),
                                 pingInterval: .milliseconds(50)))

    #expect(data == golden)
    #expect(joiner.box.wasReleasedByAPing)
    let apStart = try #require(t.sent.firstIndex(of: "APP&WIFIO"))
    let ping = try #require(t.sent.firstIndex(of: "APP&WPING"))
    let associationPolls = t.sent.indices.filter { $0 > apStart && t.sent[$0] == "APP&WIFIS" }
    #expect(apStart < ping)
    #expect(!associationPolls.isEmpty)
    #expect(ping < associationPolls[0])
    await session.stop()
}

/// Why the hand-off is not a formality. Swift concurrency's cooperative pool has
/// roughly one thread per core, and work that blocks one of them holds it: enough
/// concurrent blocking joins and an async task — the keepalive, say — never gets a
/// thread to run on at all, however "concurrent" it looks in the source.
///
/// So: run more blocking work than the pool has threads and require that ordinary
/// async work is still scheduled. Bounded on both sides — the blocked work gives
/// up after 3 s, the prober is waited for with a 2 s timeout — so reverting
/// `runOffTheCooperativePool` to call `work()` inline fails this in seconds
/// rather than wedging the suite.
@Test func blockingWorkNeverOccupiesTheCooperativeThreadsAsyncWorkNeeds() async {
    // Comfortably past the pool's width, whatever this machine's width is.
    let width = ProcessInfo.processInfo.activeProcessorCount * 2 + 2
    let parked = DispatchSemaphore(value: 0)
    let probeRan = DispatchSemaphore(value: 0)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<width {
            group.addTask {
                await runOffTheCooperativePool { _ = parked.wait(timeout: .now() + .seconds(3)) }
            }
        }
        // Enqueued last, and trivial: with the blocking work inline on the pool,
        // every thread is already held and this never runs.
        group.addTask { probeRan.signal() }
        // Waited for off the pool too, so this test does not itself hold one of
        // the threads it is reasoning about (and so `wait`, which is `noasync`,
        // is not called from an async context).
        let scheduled = await runOffTheCooperativePool {
            probeRan.wait(timeout: .now() + .seconds(2)) == .success
        }
        #expect(scheduled)
        for _ in 0..<width { parked.signal() }
    }
}

/// And the mechanism itself, stated directly: the work runs on a thread of its
/// own, not the caller's.
@Test func blockingWorkRunsOnItsOwnNamedThread() async {
    let caller = currentThreadIdentity()
    let observed = await runOffTheCooperativePool { currentThreadIdentity() }
    #expect(observed.name == blockingWorkThreadName)
    #expect(observed.thread != caller.thread)
}

/// Who is running this. An `ObjectIdentifier` rather than the `Thread` — a Thread
/// is not Sendable — and a synchronous function, because `Thread.current` is
/// `noasync` and this is deliberately asking about the thread.
private func currentThreadIdentity() -> (name: String?, thread: ObjectIdentifier) {
    (name: Thread.current.name, thread: ObjectIdentifier(Thread.current))
}
