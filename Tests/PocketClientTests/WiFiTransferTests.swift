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
        connect: { endpoint, _ in
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

/// The macOS shape of the failure: the join cannot fail (the operator pressed
/// return), nothing associated, and the only symptom is a socket that never
/// opens. The device is the witness — it reported no client — so the connect
/// error carries the diagnosis too.
@Test func aConnectFailureWithNoReportedAssociationNamesTheStaleCredential() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    t.script["APP&WIFIS"] = ["MCU&WIFIS&3"]   // AP up, never a client
    let session = PocketSession(transport: t, sessionKey: matchingKey)
    try await session.start()

    let joiner = RecordingJoiner(shouldFail: false)
    var detail = ""
    do {
        _ = try await session.downloadOverWiFi(recording, endpointOverride: deadEndpoint,
                                               joiner: joiner, readiness: briefReadiness)
        Issue.record("expected the TCP connect to fail")
    } catch PocketError.transferFailed(let thrown) {
        detail = thrown
    }

    #expect(detail.contains("wifi tcp connect"))   // the original symptom is kept
    #expect(detail.contains("the device never reported a client on its AP (no MCU&WIFIS&2)"))
    #expect(detail.contains("nothing joined PKT01_EXAMPLE"))
    #expect(detail.contains("Forget PKT01_EXAMPLE in Wi-Fi settings"))
    #expect(joiner.box.left == 1)   // the AP was still left on the failure path
    await session.stop()
}

/// The counterpart, and the reason the check is conditioned: when the device
/// DID report an associated client the host is demonstrably on the AP, so cached
/// credentials are not the story — and the failure gets its OWN diagnosis instead
/// of none. This is the 2026-07-28 shape: associated, leased, and then the access
/// point was gone by the time the socket was asked for.
@Test func aConnectFailureAfterAnObservedAssociationBlamesTheAccessPointsLifetime() async throws {
    let t = FakeTransport()
    scriptWiFiConversation(on: t)
    t.script["APP&SK&\(matchingKey)"] = ["MCU&SK&OK"]
    scriptWIFIStateMachine(on: t, apUpPolls: 0)   // reaches MCU&WIFIS&2
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

    #expect(detail.contains("wifi tcp connect"))   // the original symptom is kept
    // The credential story is absent — the host was demonstrably on the AP …
    #expect(!detail.contains("never reported a client on its AP"))
    #expect(!detail.contains("Forget"))
    // … and the access point's lifetime is named in its place, with the
    // host-side signature that confirms it.
    #expect(detail.contains("the device DID report a client on its access point (MCU&WIFIS&2)"))
    #expect(detail.contains("nothing about the password is in question"))
    #expect(detail.contains("The access point's lifetime is what to spend less of"))
    #expect(detail.contains("`ping 192.168.200.1` answers `No route to host`"))
    await session.stop()
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
    #expect(detail.contains("The access point's lifetime is what to spend less of"))
    // Emphatically NOT the credential guidance: the device's own report rules it
    // out, and a confident wrong cause is worse than a bare error.
    #expect(!detail.contains("Forget"))
    #expect(!detail.contains("never reported a client on its AP"))
    await session.stop()
}

/// The three stories must read differently — telling them apart is the point —
/// and the two access-point-lifetime ones must never reach for the credential
/// repair, which is the mistake this type exists to prevent.
@Test func theConnectDiagnosisSeparatesAccessPointLifetimeFromCredentials() {
    let lifetime: [WiFiConnectDiagnosis] = [.associatedThenUnreachable, .accessPointClosedItself]
    let credentials = WiFiJoinDiagnosis.allCases.map { WiFiConnectDiagnosis.nothingEverJoined($0) }
    let texts = (lifetime + credentials).map { $0.guidance(ssid: "PKT01_EXAMPLE") }
    #expect(Set(texts).count == texts.count)

    for text in lifetime.map({ $0.guidance(ssid: "PKT01_EXAMPLE") }) {
        #expect(text.contains("The access point's lifetime is what to spend less of"))
        #expect(text.contains("Join PKT01_EXAMPLE promptly, stay on it, and run this again"))
        #expect(!text.contains("Forget"))
        #expect(!text.contains("saved"))
    }
    for text in credentials.map({ $0.guidance(ssid: "PKT01_EXAMPLE") }) {
        #expect(text.contains("nothing joined PKT01_EXAMPLE"))
        #expect(text.contains("Forget PKT01_EXAMPLE in Wi-Fi settings"))
        #expect(!text.contains("The access point's lifetime"))
    }
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
