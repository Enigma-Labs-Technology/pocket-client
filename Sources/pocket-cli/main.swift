// pocket-client/Sources/pocket-cli/main.swift
//
// Hardware harness for the Pocket recorder (macOS only — CoreBluetooth
// needs a real device). Diagnostic-grade on purpose: it prints the command
// characteristic's GATT properties, the notify-enable outcomes, and a
// millisecond timing for every command round-trip, so link-layer failures
// are visible without a BLE sniffer.
//
// Usage:
//   swift run pocket-cli scan [seconds]             — enumerate nearby Pockets (no key needed)
//   swift run pocket-cli probe                      — connect, authenticate, print status
//   swift run pocket-cli connect <uuid>             — targeted connect by identifier, then status
//   swift run pocket-cli list                       — dates + recordings
//   swift run pocket-cli download <date> <ts> [ble|wifi]
//   swift run pocket-cli sync-wifi <date> [count]   — N recordings, ONE access-point session
//   swift run pocket-cli probe-ap-lifetime [--keepalive] — how long the AP stays up
//   swift run pocket-cli record [start|stop|pause|resume]
//   swift run pocket-cli listen [seconds]           — live MP3 to live.mp3
//   swift run pocket-cli raw WIFIS --listen 20      — one allowlisted probe, print all replies
//   swift run pocket-cli probe-unverified           — APP&PAU / APP&RESU, print real replies
//   swift run pocket-cli adopt [key]                — bind a self-generated key, prove it stuck
//   swift run pocket-cli reset --wipe-all-recordings — clear binding + WIPE all recordings
//
// POCKET_SK is the device's current 16-char session key (a factory device's is
// the first 16 chars of the account's Firebase UID; after `adopt` it is the key
// you generated). Provide it via POCKET_SK=… swift run pocket-cli probe

import Foundation
import PocketClient

let usageText = """
usage: POCKET_SK=<16-char key> swift run pocket-cli <subcommand>

subcommands:
  scan [seconds]                    enumerate nearby Pockets — name, identifier, RSSI —
                                    without connecting (default 10 s; needs no POCKET_SK)
  probe                             connect, authenticate, print device status
  connect <identifier>              connect to ONE specific Pocket by the peripheral
                                    identifier `scan` printed (no scan, no fallback),
                                    authenticate, print device status
  list                              recording dates and files
  download <date> <ts> [ble|wifi]   fetch one recording to <ts>.mp3 (default ble)
  sync-wifi <date> [count]          fetch the first <count> recordings of <date> (default 3)
                                    over ONE access-point session instead of one per
                                    recording, and report per recording whether the
                                    session was REUSED or had to be RESTARTED. That
                                    report is the experiment: nobody has ever issued a
                                    second APP&U&<date>&<ts> while the AP was still up,
                                    so the run attempts it and falls back to one session
                                    per recording the moment the device refuses. On this
                                    Mac you should be asked to join the network once if
                                    reuse works, and once per recording if it does not.
  probe-ap-lifetime [--keepalive] [--cap <s>] [--poll <s>] [--ping <s>]
                                    measure how long the recorder keeps its WiFi access
                                    point up, and whether APP&WPING extends it. Brings the
                                    AP up (APP&WIFIO), polls APP&WIFIS every --poll seconds
                                    (default 1) printing every state with its elapsed time,
                                    and stops when the device reports the AP off or at
                                    --cap seconds (default 180). NOTHING JOINS the AP — no
                                    association, no DHCP, no socket — so only the device's
                                    own report is measured. --keepalive sends APP&WPING
                                    every --ping seconds (default 10) meanwhile: run it
                                    once WITHOUT and once WITH, and the difference in
                                    lifetime is the answer. Two releases assume the
                                    keepalive extends the AP and nobody has measured it.
                                    Ctrl-C closes the AP and reports what it saw.
  record [start|stop|pause|resume]  recording control (default start)
  listen [seconds]                  capture live MP3 to live.mp3 (default 10 s)
  raw <VERB> [args…] [--listen <seconds>]
                                    send ONE allowlisted probe frame, then print every
                                    frame the device sends back, with millisecond
                                    timestamps (default window 15 s). Probe verbs:
                                    WIFIS WIFI SHUT WIFIC WPING BAT FW MAC WF SPACE
                                    STE REC&SECEN LIST_DIRS — anything else is refused.
  probe-unverified                  send APP&PAU then APP&RESU (string-table commands
                                    never seen on the wire), print every frame the
                                    device answers, and give an honest verdict —
                                    only a distinctive reply proves support, only
                                    MCU&UNKNOWN proves absence. Run it while a
                                    recording is in progress.
  adopt [key]                       bind a self-generated (or supplied) 16-char key
                                    to an UNBOUND device, then PROVE it persisted by
                                    reconnecting, re-authenticating, and checking that
                                    APP&WIFI returns newkey[:8]. Generates a key when
                                    none is given; needs no POCKET_SK (uses it, if set,
                                    only to confirm the old key is now rejected).
  reset --wipe-all-recordings       PERMANENTLY ERASE every recording on the device
                                    and clear its binding (APP&BLE&RESET). Requires the
                                    current key in POCKET_SK and the explicit flag; it
                                    refuses without the flag and touches nothing.

POCKET_SK is the device's current 16-char session key. On a factory device that
is the first 16 characters of the account's Firebase UID; after `adopt` it is the
key you generated, e.g.  POCKET_SK=ExampleKey000000 swift run pocket-cli probe
"""

func usageError(_ message: String) -> Never {
    print("error: \(message)\n")
    print(usageText)
    exit(2)
}

func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

/// Runs one command round-trip and prints how long the device took to answer.
func timed<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let start = ContinuousClock.now
    let result = try await body()
    print("  [\(label): \(milliseconds(ContinuousClock.now - start)) ms]")
    return result
}

/// Marks the instant the first transfer byte arrives, so the KB/s diagnostic
/// measures the transfer itself — in wifi mode the operator can sit at the
/// manual-join prompt for arbitrarily long, which must not count.
final class TransferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: ContinuousClock.Instant?
    func mark() { lock.lock(); if first == nil { first = .now }; lock.unlock() }
    var start: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return first }
}

func hexPrefix(_ data: Data, count: Int = 4) -> String {
    data.prefix(count).map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// Printable-ASCII rendering with '.' for everything else, so an ASCII
/// control frame riding the data channel (e.g. MCU&OFF) is recognizable
/// at a glance next to the hex.
func asciiPreview(_ data: Data) -> String {
    String(data.map { byte in
        (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    })
}

/// One line of triage per failure mode, so the human partner does not have
/// to reverse-engineer the client to know what a given error implicates.
/// `targeted` distinguishes a `connect <uuid>` run: its link stage never
/// scans, so a "scan window" hint would send the debugging the wrong way.
func hint(for error: PocketError, targeted: Bool = false) -> String {
    switch error {
    case .timeout(let command):
        if case .auth(let key) = command {
            // BLETransport signals its scan/connect deadline with .auth("");
            // the session's handshake timeout carries the real key.
            if key.isEmpty {
                return targeted
                    ? "connect window expired — the identifier is known to this system but the " +
                      "device never became reachable: asleep, out of range, Bluetooth off, or " +
                      "factory-reset into a new BLE identity (re-run pocket-cli scan for current " +
                      "identifiers)"
                    : "scan/connect window expired with no PKT01_* link established — " +
                      "device asleep or out of range, Bluetooth off, or macOS denied Bluetooth access"
            }
            return "handshake sent but unanswered — suspect CCCD notify-enable or command write-type; " +
                   "check the 'command characteristic properties' and 'notify state' lines above"
        }
        return "no reply matching what the client expects for \(command.wireFormat) — " +
               "if [unmatched] lines appear above, the device DID answer, just not in the " +
               "expected shape (capture those lines; `pocket-cli raw` can probe further); " +
               "with none, the link was up but the device stayed silent — check the notify " +
               "state line and whether another app holds the device"
    case .authRejected:
        return "device answered MCU&SK&ERR and will drop the link — wrong session key? " +
               "POCKET_SK must be the device's CURRENT key: on a factory device the first " +
               "16 characters of the account's Firebase UID; after `pocket-cli adopt`, the " +
               "adopted key"
    case .notAuthenticated:
        return "a command ran before the handshake completed — harness bug, please report"
    case .busy(let what):
        return "\(what) — the device allows one connection and one transfer at a time"
    case .disconnected:
        return "link dropped or never established — device asleep/out of range, Bluetooth off, " +
               "or macOS denied Bluetooth access (System Settings > Privacy & Security > Bluetooth)"
    case .deviceNotFound(let identifier):
        return "this system does not know peripheral \(identifier) — the device was never seen " +
               "by this machine, or Bluetooth forgot it (e.g. after a factory reset); run " +
               "`pocket-cli scan` and connect with a currently visible identifier"
    case .unknownCommand(let command):
        return "device answered MCU&UNKNOWN to \(command.wireFormat) — this firmware may not support it"
    case .unexpectedResponse(let detail):
        return "protocol drift between client and firmware: \(detail)"
    case .sizeMismatch(let expected, let received):
        // Under- and over-read implicate different things: truncation means
        // the stream died early; surplus means the peer sent bytes past the
        // announced (authoritative) length and the client failed to trim.
        return received < expected
            ? "transfer truncated: received \(received) of \(expected) announced bytes"
            : "received \(received), more than the announced \(expected) bytes — " +
              "the device sent surplus past the announced length"
    case .notMP3:
        return "transfer payload did not start with an MP3 frame header — channel framing suspect"
    case .emptyRecording:
        return "the device reports this recording as 0 bytes — nothing to download " +
               "(0-second recordings exist; delete it on the device if unwanted)"
    case .wifiJoinFailed(let detail):
        return "could not join the device's WiFi AP: \(detail)"
    case .transferFailed(let detail):
        return detail
    }
}

/// `scan` — live enumeration only: lists nearby PKT01_* devices with the
/// peripheral identifiers `connect` takes, plus signal strength. It never
/// connects (so it needs no session key), and cancelling its consumer is
/// what stops the radio — the exact contract an app picker uses.
func runScan(seconds: Int) async {
    let scanner = PocketScanner()
    print("scanning for nearby Pockets for \(seconds) s (enumeration only — nothing is connected) …")
    let consumer = Task { () -> [NearbyPocket] in
        var known: [UUID: NearbyPocket] = [:]
        var lastList: [NearbyPocket] = []
        for await state in scanner.updates() {
            switch state {
            case .starting:
                break   // radio state not determined yet; a real state follows
            case .poweredOff:
                print("Bluetooth is powered off — turn it on to scan")
            case .unauthorized:
                print("Bluetooth access denied — System Settings > Privacy & Security > Bluetooth")
            case .unsupported:
                print("this machine reports no Bluetooth LE support")
            case .scanning(let nearby):
                // Print arrivals and departures only — RSSI refreshes arrive
                // many times a second and would flood the transcript.
                for device in nearby where known[device.identifier] == nil {
                    print("  + \(device.name)  \(device.identifier)  " +
                          "RSSI \(device.rssi.map(String.init) ?? "n/a") dBm")
                }
                for (identifier, device) in known
                where !nearby.contains(where: { $0.identifier == identifier }) {
                    print("  - \(device.name) stopped advertising (aged out)")
                }
                known = Dictionary(uniqueKeysWithValues: nearby.map { ($0.identifier, $0) })
                lastList = nearby
            }
        }
        return lastList
    }
    try? await Task.sleep(for: .seconds(seconds))
    consumer.cancel()   // ends the updates() stream, which stops the radio scan
    let final = await consumer.value
    if final.isEmpty {
        print("no Pockets in range — is the device awake? (it sleeps aggressively; slide its switch)")
    } else {
        print("final list (first-seen order):")
        for device in final {
            print("  \(device.name)  \(device.identifier)  RSSI \(device.rssi.map(String.init) ?? "n/a") dBm")
        }
        print("connect to one with: POCKET_SK=… swift run pocket-cli connect <identifier>")
    }
}

/// Scans, connects, prints link-layer diagnostics, authenticates.
/// The transport/device pair is single-use; each CLI invocation builds
/// exactly one pair and never retries on it. A non-nil `target` connects to
/// exactly that peripheral identifier instead of scanning (`connect` verb).
func connectDevice(sessionKey: String, target: UUID? = nil) async throws -> PocketDevice {
    let transport = BLETransport()
    let scanStart = ContinuousClock.now
    let found: DiscoveredDevice
    if let target {
        print("connecting to \(target) (retrieve by identifier — no scan, no fallback) …")
        found = try await transport.connect(to: target)
    } else {
        print("scanning for PKT01_* …")
        found = try await transport.connect()
    }
    print("connected to \(found.name)  [scan+connect+discover: \(milliseconds(ContinuousClock.now - scanStart)) ms]")

    // Must-confirm #1: the command characteristic's write type. send() uses
    // .withResponse; a device offering only write-without-response would fail
    // every command at the GATT layer with nothing else to show for it.
    if let properties = await transport.commandCharacteristicProperties() {
        print("command characteristic properties: \(properties)")
        if !properties.contains("write-with-response") {
            print("WARNING: no write-with-response — the client writes .withResponse; every command will fail")
        }
    } else {
        print("command characteristic properties: unknown (discovery incomplete)")
    }

    // The CLI is macOS-only, where programmatic hotspot join does not exist:
    // wifi downloads pause and ask the operator to join the AP by hand.
    let device = PocketDevice(transport: transport, sessionKey: sessionKey,
                              joiner: ManualHotspotJoiner())
    let handshakeStart = ContinuousClock.now
    do {
        try await device.connect()
    } catch {
        // Must-confirm #2: a handshake timeout with a failed or missing
        // notify enable is a CCCD problem, not an auth problem — say so
        // before dying.
        print("notify state: \(await transport.notifyStateSummary())")
        throw error
    }
    print("authenticated  [handshake: \(milliseconds(ContinuousClock.now - handshakeStart)) ms]")
    print("notify state: \(await transport.notifyStateSummary())")
    return device
}

/// `raw` — sends ONE allowlisted probe frame, then prints every frame the
/// device sends for the listen window. The discovery tool for handshakes the
/// client does not model yet (e.g. the real `APP&WIFIS` reply shape): no
/// waiter is ever armed after the handshake, so EVERY incoming frame reaches
/// the events stream — verbatim as `.unmatchedResponse`, or as its
/// structured event for the two known unsolicited shapes.
func runRawProbe(verb: String, listenSeconds: Int, sessionKey: String) async throws {
    guard let command = RawProbe.command(forVerb: verb) else {
        usageError("'\(verb)' is not an allowlisted probe verb")   // unreachable: validated at startup
    }
    let transport = BLETransport()
    print("scanning for PKT01_* …")
    let scanStart = ContinuousClock.now
    let found = try await transport.connect()
    print("connected to \(found.name)  [scan+connect+discover: \(milliseconds(ContinuousClock.now - scanStart)) ms]")

    let session = PocketSession(transport: transport, sessionKey: sessionKey)
    do {
        try await session.start()
    } catch {
        print("notify state: \(await transport.notifyStateSummary())")
        await session.stop()
        throw error
    }
    print("authenticated")

    let epoch = ContinuousClock.now
    let printer = Task { () -> Int in
        var frames = 0
        for await event in session.events {
            let ms = milliseconds(ContinuousClock.now - epoch)
            switch event {
            case .unmatchedResponse(let frame):
                frames += 1
                print("  [+\(ms) ms] \(frame)")
            case .disconnected:
                print("  [+\(ms) ms] -- link dropped --")
            default:
                frames += 1
                print("  [+\(ms) ms] [event] \(event)")
            }
        }
        return frames
    }

    print("sending \(command.wireFormat), then listening \(listenSeconds) s " +
          "(the session absorbs its own 30 s APP&BAT keepalive echoes; they will not appear) …")
    try await session.send(command)
    try? await Task.sleep(for: .seconds(listenSeconds))
    await session.stop()   // finishes the events stream; the printer drains and returns
    let frames = await printer.value
    print(frames == 0 ? "no frames received — the device stayed silent"
                      : "listen window closed after \(frames) frame(s)")
}

/// Frames received during one probe window; drained between windows so each
/// verdict is derived only from its own window's traffic.
final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []
    func record(_ frame: String) { lock.lock(); frames.append(frame); lock.unlock() }
    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let drained = frames
        frames = []
        return drained
    }
}

/// Honest classification of one probe window. Only two outcomes are proof:
/// a reply naming the verb (support) or `MCU&UNKNOWN` (absence). Everything
/// else — silence, keepalive noise, unrelated status frames — is
/// inconclusive by construction and must be reported as such.
func probeVerdict(verb: String, frames: [String], windowSeconds: Int) -> String {
    // "Names the verb" means an exact '&'-field match (MCU&PAU, MCU&REC&PAU…),
    // never a substring — fuzzy matching is how false positives happen.
    let distinctive = frames.first { $0.components(separatedBy: "&").dropFirst().contains(verb) }
    let unknown = frames.contains("MCU&UNKNOWN")
    switch (distinctive, unknown) {
    case (let frame?, true):
        return "CONTRADICTORY — both \"\(frame)\" and MCU&UNKNOWN arrived; capture this transcript"
    case (let frame?, false):
        return "SUPPORTED — distinctive reply naming \(verb): \"\(frame)\""
    case (nil, true):
        return "NOT SUPPORTED — the firmware answered MCU&UNKNOWN"
    case (nil, false) where frames.isEmpty:
        return "INCONCLUSIVE — silence for \(windowSeconds) s (the firmware may accept "
             + "silently, ignore the frame, or answer only in some other device state)"
    case (nil, false):
        return "INCONCLUSIVE — \(frames.count) frame(s) arrived but none names \(verb) and "
             + "none is MCU&UNKNOWN; treat them as unrelated traffic, not as acceptance"
    }
}

/// `probe-unverified` — sends the two commands that exist only in the app's
/// string table (`APP&PAU`, `APP&RESU`; seen in no capture) and prints every
/// frame the device answers, with a verdict per command.
///
/// Deliberately NOT `device.pauseRecording()`: those methods accept ANY
/// response (their real reply shape is unknown), so a coincidental frame —
/// e.g. the 30 s keepalive's `MCU&BAT` reply — satisfies them and "accepted"
/// proves nothing. This flow never arms a waiter: like `raw`, it
/// fire-and-forgets each frame and reads the events stream, so what is
/// printed is exactly what the device sent, and the verdict is derived from
/// those frames alone.
func runUnverifiedProbe(sessionKey: String, windowSeconds: Int = 5) async throws {
    let transport = BLETransport()
    print("scanning for PKT01_* …")
    let scanStart = ContinuousClock.now
    let found = try await transport.connect()
    print("connected to \(found.name)  [scan+connect+discover: \(milliseconds(ContinuousClock.now - scanStart)) ms]")

    let session = PocketSession(transport: transport, sessionKey: sessionKey)
    do {
        try await session.start()
    } catch {
        print("notify state: \(await transport.notifyStateSummary())")
        await session.stop()
        throw error
    }
    print("authenticated")

    // Pause is only meaningful against an active recording; record which
    // world this probe ran in so the transcript is self-describing.
    let state = try? await session.request(.recordingState) {
        if case .recordingState = $0 { true } else { false }
    }
    if case .recordingState(let active)? = state {
        print(active
            ? "recording in progress — pause/resume have something to act on"
            : "WARNING: no recording in progress — APP&PAU has nothing to pause; "
              + "start one first (pocket-cli record start) for a meaningful probe")
    }

    let frameLog = FrameLog()
    let epoch = ContinuousClock.now
    let printer = Task {
        for await event in session.events {
            let ms = milliseconds(ContinuousClock.now - epoch)
            switch event {
            case .unmatchedResponse(let frame):
                // The session absorbs its own keepalive's MCU&BAT echoes, so
                // a battery frame here is unsolicited — still never evidence.
                let noise = frame.hasPrefix("MCU&BAT")
                    ? "   (unsolicited battery frame — not evidence)" : ""
                print("  [+\(ms) ms] \(frame)\(noise)")
                frameLog.record(frame)
            case .disconnected:
                print("  [+\(ms) ms] -- link dropped --")
            default:
                // Structured unsolicited events (recording started / in
                // progress) are context, not candidate replies — logged so
                // the verdict can count them as unrelated traffic.
                print("  [+\(ms) ms] [event] \(event)")
                frameLog.record("[event] \(event)")
            }
        }
    }

    var verdicts: [(command: String, verdict: String)] = []
    for (command, verb) in [(Command.pauseRecording, "PAU"), (.resumeRecording, "RESU")] {
        print("sending \(command.wireFormat), then listening \(windowSeconds) s …")
        try await session.send(command)
        try? await Task.sleep(for: .seconds(windowSeconds))
        let verdict = probeVerdict(verb: verb, frames: frameLog.drain(),
                                   windowSeconds: windowSeconds)
        print("  verdict: \(verdict)")
        verdicts.append((command.wireFormat, verdict))
    }

    await session.stop()   // finishes the events stream; the printer drains and returns
    await printer.value

    print("""

    summary:
    \(verdicts.map { "  \($0.command):  \($0.verdict)" }.joined(separator: "\n"))

    how to read this:
      - only a distinctive reply naming the verb (e.g. MCU&PAU) proves support
      - MCU&UNKNOWN proves this firmware does not implement the verb
      - the session absorbs its own 30 s keepalive's MCU&BAT echoes; any battery
        frame that still appears is unsolicited status — never evidence either
      - silence and unrelated frames prove nothing either way: "the command did not
        error" is NOT the same as "the command worked"
      - a meaningful pause probe needs a recording in progress; verify any effect
        independently — e.g. does `pocket-cli listen` go quiet after APP&PAU and
        resume after APP&RESU, and does the recording flag in `pocket-cli probe`
        change?
    """)
}

// MARK: - Argument validation (everything checkable before touching the radio)

let arguments = Array(CommandLine.arguments.dropFirst())
let subcommand = arguments.first ?? "probe"

/// Set by the `raw` validation below and read by the main flow; the verb is
/// only ever a *key* into `RawProbe`'s fixed table, never frame material.
var rawProbeVerb = ""
var rawListenSeconds = 15

/// Set by the `connect` validation below: the peripheral identifier for a
/// targeted (no-scan) connect. Nil means every other subcommand's normal
/// scanning connect.
var targetIdentifier: UUID?

/// Set by the `adopt` validation below: an operator-supplied key to bind
/// instead of a freshly generated one (lets a half-finished rebind repeat
/// deterministically). Nil means generate one.
var adoptKey: String?

/// Set by the `sync-wifi` validation below: how many of the day's recordings to
/// pull in one access-point session.
var syncWiFiCount = 3

/// Set by the `probe-ap-lifetime` validation below: the access-point lifetime
/// experiment's cadence, cap, and whether it sends `APP&WPING`.
var apLifetimeSettings = AccessPointLifetimeSettings()

switch subcommand {
case "help", "--help", "-h":
    print(usageText)
    exit(0)
case "probe", "list", "probe-unverified":
    break
case "adopt":
    // Optional explicit key; validate it up front so a bad key never reaches
    // the device (the firmware would accept a wrong-length/exotic key on
    // length alone, or mis-parse it — and this is the user's only recorder).
    if arguments.count >= 2 {
        let candidate = arguments[1]
        guard PocketKey.isValid(candidate) else {
            usageError("adopt key must be exactly 16 characters from [A-Za-z0-9], not '\(candidate)'")
        }
        adoptKey = candidate
    }
case "reset":
    // Destructive: refuse outright unless the operator opted in by name. This
    // check runs before we ever touch the radio, so a bare `reset` cannot wipe
    // anything even by accident.
    guard arguments.dropFirst().contains(resetOptInFlag) else {
        print("""
        REFUSED: `pocket-cli reset` sends APP&BLE&RESET, which PERMANENTLY ERASES
        every recording stored on the device and clears its binding. There is no undo.

        This is not something to run by reflex, so it needs an explicit flag that
        names the consequence:

            POCKET_SK=<current key> swift run pocket-cli reset \(resetOptInFlag)

        Nothing was sent; the device was not touched.
        """)
        exit(2)
    }
case "scan":
    if arguments.count >= 2, (Int(arguments[1]) ?? 0) < 1 {
        usageError("scan seconds must be a positive integer, not '\(arguments[1])'")
    }
case "connect":
    guard arguments.count >= 2 else {
        usageError("connect needs a peripheral identifier — run `pocket-cli scan` to list them")
    }
    guard let parsed = UUID(uuidString: arguments[1]) else {
        usageError("'\(arguments[1])' is not a peripheral identifier (UUID) — run `pocket-cli scan` to list them")
    }
    targetIdentifier = parsed
case "download":
    guard arguments.count >= 3 else { usageError("download needs <date> <timestamp>") }
    if arguments.count >= 4, !["ble", "wifi"].contains(arguments[3]) {
        usageError("transfer mode must be ble or wifi, not '\(arguments[3])'")
    }
case "sync-wifi":
    guard arguments.count >= 2 else {
        usageError("sync-wifi needs a date — run `pocket-cli list` to see which dates exist")
    }
    if arguments.count >= 3 {
        guard let parsed = Int(arguments[2]), parsed >= 1 else {
            usageError("sync-wifi count must be a positive integer, not '\(arguments[2])'")
        }
        syncWiFiCount = parsed
    }
case "probe-ap-lifetime":
    // Every flag is checkable without a radio, and a bad cadence must not cost
    // the operator a three-minute run to discover.
    apLifetimeSettings = accessPointLifetimeSettings(from: Array(arguments.dropFirst()))
case "record":
    let verb = arguments.count >= 2 ? arguments[1] : "start"
    guard ["start", "stop", "pause", "resume"].contains(verb) else {
        usageError("record verb must be start|stop|pause|resume, not '\(verb)'")
    }
case "listen":
    if arguments.count >= 2, (Int(arguments[1]) ?? 0) < 1 {
        usageError("listen seconds must be a positive integer, not '\(arguments[1])'")
    }
case "raw":
    var tokens = Array(arguments.dropFirst())
    if let flagIndex = tokens.firstIndex(of: "--listen") {
        guard flagIndex + 1 < tokens.count, let seconds = Int(tokens[flagIndex + 1]), seconds >= 1 else {
            usageError("--listen needs a positive integer number of seconds")
        }
        guard flagIndex + 2 == tokens.count else {
            usageError("unexpected arguments after --listen")
        }
        rawListenSeconds = seconds
        tokens.removeSubrange(flagIndex...)
    }
    guard !tokens.isEmpty else { usageError("raw needs a probe verb, e.g. raw WIFIS") }
    // Multi-token verbs (raw REC SECEN) join with '&' — the joined string is
    // still only a lookup key; a verb that takes no arguments plus any extra
    // token yields a key outside the allowlist and is refused below.
    rawProbeVerb = tokens.joined(separator: "&").uppercased()
    if RawProbe.command(forVerb: rawProbeVerb) == nil {
        print("refused: '\(rawProbeVerb)' is not an allowlisted probe verb — nothing was sent")
        print("raw sends only these fixed read-only probes: "
              + RawProbe.allowedVerbs.joined(separator: " "))
        exit(2)
    }
default:
    usageError("unknown subcommand: \(subcommand)")
}

// `scan` never connects, so it needs no session key: handle it before the
// POCKET_SK gate and exit.
if subcommand == "scan" {
    let seconds = arguments.count >= 2 ? (Int(arguments[1]) ?? 10) : 10
    await runScan(seconds: seconds)
    exit(0)
}

// `adopt` binds a NEW key (generated or supplied), so it does not require the
// current key. POCKET_SK, if set, is used only for the optional negative
// control (confirming the old key is now rejected). Handle it before the gate.
if subcommand == "adopt" {
    let previousKey = ProcessInfo.processInfo.environment["POCKET_SK"]
    do {
        try await runAdopt(explicitKey: adoptKey, oldKey: previousKey)
    } catch let error as PocketError {
        print("error: PocketError.\(error)")
        print("hint: \(hint(for: error))")
        exit(1)
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
}

guard let sessionKey = ProcessInfo.processInfo.environment["POCKET_SK"], !sessionKey.isEmpty else {
    usageError("set POCKET_SK to the 16-character session key")
}
if sessionKey.count != 16 {
    print("warning: POCKET_SK is \(sessionKey.count) characters, expected 16 — the device will likely reject it")
}

// MARK: - Main flow

do {
    if subcommand == "raw" {
        // Its own flow: it needs the session's fire-and-forget send + events
        // stream, which PocketDevice deliberately does not expose.
        try await runRawProbe(verb: rawProbeVerb, listenSeconds: rawListenSeconds,
                              sessionKey: sessionKey)
        exit(0)
    }

    if subcommand == "probe-unverified" {
        // Also session-level: PocketDevice's pause/resume would arm their
        // accept-anything matchers and could report a coincidental frame as
        // success — this probe needs the raw traffic instead.
        try await runUnverifiedProbe(sessionKey: sessionKey)
        exit(0)
    }

    if subcommand == "reset" {
        // Its own flow: it authenticates with the CURRENT key, lists what is
        // about to be lost, then sends the raw APP&BLE&RESET frame (which is
        // deliberately not a `Command`) and awaits MCU&W91&RESET. The opt-in
        // flag was already required during argument validation.
        try await runReset(sessionKey: sessionKey)
        exit(0)
    }

    let device = try await connectDevice(sessionKey: sessionKey, target: targetIdentifier)

    // Surface unsolicited device traffic (device-initiated recordings, link
    // loss) as it arrives — exactly what a diagnostic harness must not hide.
    let eventPrinter = Task {
        for await event in device.events {
            switch event {
            case .wifiReadinessNotObserved:
                print("[event] device never reported a joined WiFi client (MCU&WIFIS&2) " +
                      "within the readiness window — proceeding with the transfer anyway")
            case .unmatchedResponse(let frame):
                // The device spoke, but in a shape no armed request expected —
                // exactly what a timeout postmortem needs to see.
                print("[unmatched] \(frame)")
            case .wifiTrailerReceived(let byteCount, let preview):
                // Bytes past the announced length on the TCP socket — kept out
                // of the file, printed here so we can learn what they are.
                let truncated = byteCount > preview.count ? " (first \(preview.count) shown)" : ""
                print("trailer after file: \(byteCount) bytes: " +
                      "\(hexPrefix(preview, count: preview.count)) " +
                      "\"\(asciiPreview(preview))\"\(truncated)")
            default:
                print("[event] \(event)")
            }
        }
    }
    defer { eventPrinter.cancel() }

    switch subcommand {
    case "probe", "connect":
        let status = try await timed("status (7 round-trips)") { try await device.status() }
        print("""
        battery:   \(status.batteryPercent)%
        firmware:  \(status.firmware)   wifi fw: \(status.wifiFirmware)
        mac:       \(status.macAddress)
        storage:   \(status.storage.freeMB) MB free of \(status.storage.totalMB) MB
        slider:    \(status.slider)
        recording: \(status.isRecording)
        """)

    case "list":
        let dates = try await timed("listDates") { try await device.listDates() }
        if dates.isEmpty { print("no recordings on device") }
        for date in dates {
            print("\(date):")
            let recordings = try await timed("listRecordings \(date)") {
                try await device.listRecordings(on: date)
            }
            for recording in recordings {
                print("  \(recording.id.timestamp)  \(recording.durationSeconds)s  " +
                      "~\(recording.estimatedBytes / 1024) KB")
            }
        }

    case "download":
        let id = RecordingID(date: arguments[1], timestamp: arguments[2])
        let mode: TransferMode = (arguments.count >= 4 && arguments[3] == "wifi") ? .wifi : .ble
        // Duration is needed for size estimates; probe the real value from the day's list.
        let listed = try await timed("listRecordings \(id.date)") {
            try await device.listRecordings(on: id.date)
        }
        guard let recording = listed.first(where: { $0.id == id }) else {
            print("no such recording \(id.timestamp) on \(id.date); device has: " +
                  (listed.isEmpty ? "none" : listed.map(\.id.timestamp).joined(separator: ", ")))
            await device.disconnect()
            exit(1)
        }
        print("downloading \(id.timestamp) (\(recording.durationSeconds) s, " +
              "~\(recording.estimatedBytes / 1024) KB) via \(mode == .wifi ? "wifi" : "ble") …")
        let callStart = ContinuousClock.now
        let transferClock = TransferClock()
        // Streaming API: bytes go to disk as they arrive, never held whole in
        // memory (they land at the .mp3 path only after validation passes —
        // a failed transfer leaves nothing behind).
        let out = URL(fileURLWithPath: "\(id.timestamp).mp3")
        try await device.download(recording, to: out, via: mode) { fraction in
            transferClock.mark()
            print(String(format: "\r  %3.0f%%", fraction * 100), terminator: "")
            fflush(stdout)
        }
        let elapsedMS = max(milliseconds(ContinuousClock.now - (transferClock.start ?? callStart)), 1)
        print("")   // end the \r progress line
        // The bytes went to disk, so the diagnostics read them back from the
        // validated file: its true size, and its first four bytes for the
        // MP3-sync eyeball check.
        let byteCount = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        let reader = try FileHandle(forReadingFrom: out)
        let firstBytes = (try reader.read(upToCount: 4)) ?? Data()
        try reader.close()
        let rate = Double(byteCount) / 1024.0 / (Double(elapsedMS) / 1000.0)
        print("wrote \(out.path): \(byteCount) bytes in \(elapsedMS) ms " +
              "(\(String(format: "%.1f", rate)) KB/s)")
        print("first bytes: \(hexPrefix(firstBytes))  (expect FF F3 48 C4 — 32 kbps mono MP3 sync)")

    case "sync-wifi":
        try await runWiFiBatchSync(device: device, date: arguments[1], count: syncWiFiCount)

    case "probe-ap-lifetime":
        try await runAccessPointLifetimeProbe(device: device, settings: apLifetimeSettings)

    case "record":
        switch arguments.count >= 2 ? arguments[1] : "start" {
        case "start":
            let id = try await timed("startRecording") { try await device.startRecording() }
            print("recording started: \(id.date)/\(id.timestamp)")
        case "stop":
            try await timed("stopRecording") { try await device.stopRecording() }
            print("recording stopped")
        case "pause", "resume":
            print("""
            not supported by this firmware — probed 2026-07-25 against FW 1.7:
            APP&PAU and APP&RESU both answer MCU&UNKNOWN, so there is no
            pauseRecording()/resumeRecording() API. Use `record stop`.
            Re-test a future firmware with: pocket-cli probe-unverified
            """)
        default:
            break   // unreachable: validated before connecting
        }

    case "listen":
        let seconds = arguments.count >= 2 ? (Int(arguments[1]) ?? 10) : 10
        let stream = try await device.liveAudio()
        print("capturing live audio for \(seconds) s (frames only flow while the device is recording) …")
        var captured = Data()
        var chunkCount = 0
        var firstChunkMS: Int?
        let listenStart = ContinuousClock.now
        let stopper = Task {
            try? await Task.sleep(for: .seconds(seconds))
            // Tearing the link down finishes the live stream, which ends the
            // loop below. The pair is spent afterwards, which is fine — the
            // CLI exits after one subcommand and never reuses it.
            await device.disconnect()
        }
        for await chunk in stream {
            if firstChunkMS == nil {
                firstChunkMS = milliseconds(ContinuousClock.now - listenStart)
                print("  first chunk after \(firstChunkMS!) ms")
            }
            captured.append(chunk)
            chunkCount += 1
        }
        stopper.cancel()
        try captured.write(to: URL(fileURLWithPath: "live.mp3"))
        print("wrote live.mp3: \(captured.count) bytes in \(chunkCount) chunks")
        if captured.isEmpty {
            print("no audio arrived — was a recording active? (start one: pocket-cli record start)")
        } else {
            print("first bytes: \(hexPrefix(captured))  (expect FF Fx MP3 sync)")
        }

    default:
        break   // unreachable: validated before connecting
    }

    await device.disconnect()
} catch let error as PocketError {
    print("error: PocketError.\(error)")
    print("hint: \(hint(for: error, targeted: targetIdentifier != nil))")
    exit(1)
} catch {
    print("error: \(error)")
    exit(1)
}
