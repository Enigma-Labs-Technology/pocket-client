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

    await #expect(throws: PocketError.wifiJoinFailed("test")) {
        _ = try await session.downloadOverWiFi(recording,
                                               endpointOverride: nil,
                                               joiner: RecordingJoiner(shouldFail: true))
    }
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

    await #expect(throws: PocketError.wifiJoinFailed("test")) {
        _ = try await device.download(recording, via: .wifi)
    }
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
