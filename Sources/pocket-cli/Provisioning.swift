// pocket-client/Sources/pocket-cli/Provisioning.swift
//
// Session-key provisioning flows for the hardware harness: `reset` (guarded
// device wipe) and `adopt` (bind a self-generated key and PROVE it stuck).
//
// These live in the CLI executable — NOT in the PocketClient library — on
// purpose. `APP&BLE&RESET` permanently wipes every recording on the device,
// and the iOS app (pocket-core / PocketApp) must never send it. Precisely
// stated, the guarantee is threefold — and no stronger:
//  (a) no `Command` case can produce the frame — enforced by the
//      compiler-forced exhaustive walk in CommandTests
//      (`noDestructiveCommandsExist`, `deviceResetFrameIsNotRepresentableAsACommand`),
//      so the library's typed API cannot emit it;
//  (b) the frame's bytes exist at exactly one call site, here in the CLI,
//      behind the `pocket-cli reset` opt-in flag and typed confirmation;
//  (c) pocket-core/PocketApp contain no such call site.
// It is NOT "unreachable from anything that links the library":
// `PocketTransport.send(Data)` is public (this file uses it), so any linking
// code COULD hand-build the bytes. (a) and the tests make that impossible to
// do accidentally through the typed API; (b) and (c) are upheld by review.

import Foundation
import PocketClient

/// The one destructive frame in this whole package, deliberately NOT a
/// `Command` case and NOT in the library. Sent only by `runReset`, only after
/// the explicit `--wipe-all-recordings` opt-in. `APP&BLE&RESET` clears the
/// binding and permanently erases every recording on the device (verified from
/// the vendor's own reset sheet); the device acks `MCU&W91&RESET` and reboots.
private let deviceResetFrame = Data("APP&BLE&RESET".utf8)

/// Its acknowledgement, matched as a raw frame off the session's event stream
/// (it has no `Command`, so no waiter is armed for it — it surfaces as
/// `.unmatchedResponse`).
private let deviceResetAck = "MCU&W91&RESET"

/// The flag that must be present for `reset` to do anything. Its name states
/// the consequence, so nobody types it by reflex the way they would `-f`.
let resetOptInFlag = "--wipe-all-recordings"

// MARK: - reset

/// `pocket-cli reset <flag>` — authenticate with the CURRENT key, show every
/// recording that is about to be destroyed, then send `APP&BLE&RESET` and
/// await `MCU&W91&RESET`.
///
/// The caller guarantees the opt-in flag was present (checked before we ever
/// touch the radio). This function still prints the full inventory and a short
/// abort window so an operator who forgot about an unsynced recording can
/// Ctrl-C before anything is destroyed.
func runReset(sessionKey: String) async throws {
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
    print("authenticated with the current key")

    // Show exactly what is about to be lost — the operator's last chance to
    // notice an outstanding sync (APP&LIST_DIRS + APP&LIST&<date>).
    print("\nrecordings currently on the device — ALL of these will be PERMANENTLY ERASED:")
    let dates = try await session.listDates()
    var total = 0
    if dates.isEmpty {
        print("  (device reports no recordings)")
    }
    for date in dates {
        let recordings = try await session.listRecordings(on: date)
        for recording in recordings {
            print("  \(date)/\(recording.id.timestamp)  \(recording.durationSeconds)s")
            total += 1
        }
    }
    print("""

    \(total) recording(s) will be permanently erased and the device unbound.
    This CANNOT be undone. If any recording above is unsynced, abort now and
    sync it first (pocket-cli download / list).

    To proceed, type exactly:  WIPE \(found.name)
    Anything else aborts.
    """)
    print("> ", terminator: "")
    // Typed confirmation, not a timer: the operator must actively name the
    // device being wiped; failing to interrupt something is not consent.
    // (Same blocking readLine() pattern as ManualHotspotJoiner.)
    let typed = readLine()?.trimmingCharacters(in: .whitespaces)
    guard typed == "WIPE \(found.name)" else {
        print("aborted — nothing was sent; the device was not touched.")
        await session.stop()
        exit(1)
    }

    print("sending \(String(decoding: deviceResetFrame, as: UTF8.self)) …")
    // Send the raw frame straight down the transport: it is not a `Command`,
    // so nothing in the library can represent it. Its ack has no armed waiter
    // and arrives as an unsolicited `.unmatchedResponse` on the event stream.
    try await transport.send(deviceResetFrame)

    let acked = await awaitResetAck(session: session, transport: transport, timeout: .seconds(10))
    await session.stop()

    if acked {
        print("device acknowledged reset (\(deviceResetAck)) — it is wiping and rebooting.")
        print("the device is now UNBOUND; bind a fresh key with: pocket-cli adopt")
    } else {
        print("""
        no \(deviceResetAck) acknowledgement arrived within the window.
        UNCONFIRMED DOES NOT MEAN NOTHING HAPPENED: the reset frame WAS sent, and
        the device may well have wiped and rebooted anyway — it drops BLE as it
        reboots, and the \(deviceResetAck) ack itself is inferred from the vendor
        app's strings, never observed on hardware, so its absence proves nothing.
        Assume the recordings may be gone. Re-scan, then check the device's state:
        if the old key is rejected, the reset (and the wipe) went through.
        """)
        exit(1)
    }
}

/// Waits for the reset ack on the session's event stream, bounded by `timeout`.
/// On expiry it tears the link down (which finishes the event stream) so this
/// can never block past the deadline. Returns true iff `MCU&W91&RESET` arrived.
private func awaitResetAck(session: PocketSession, transport: BLETransport,
                           timeout: Duration) async -> Bool {
    let deadline = Task {
        try? await Task.sleep(for: timeout)
        // Finish the event stream so the loop below terminates even if the
        // device never answers (it may reboot without a clean disconnect).
        await transport.disconnect()
    }
    defer { deadline.cancel() }

    for await event in session.events {
        switch event {
        case .unmatchedResponse(let frame) where frame.contains(deviceResetAck):
            return true
        case .disconnected:
            // The device rebooted (dropped BLE) without our seeing the ack.
            return false
        default:
            continue
        }
    }
    return false
}

// MARK: - adopt

/// `pocket-cli adopt [key]` — bind a self-generated (or supplied) 16-char key
/// to an UNBOUND device, then PROVE it persisted. Proof is the whole point:
/// on the wire an adoption is byte-identical to an ordinary successful auth
/// (`MCU&SK&OK`), so the only way to tell "stored in NV" from "accepted for
/// this session" is to disconnect, reconnect, and re-authenticate.
///
/// `explicitKey`, when given, has already been validated by the caller
/// (`PocketKey.isValid`); it lets a half-finished rebind be repeated with the
/// same key. `oldKey` (the previous POCKET_SK, if set) drives the optional
/// negative control at the end.
func runAdopt(explicitKey: String?, oldKey: String?) async throws {
    let newKey = explicitKey ?? PocketKey.generate()
    print("new session key: \(newKey)")
    print("""
    ^ this is the ONLY copy. Store it now (e.g. as POCKET_SK). The device never
      reveals more than its first 8 characters, so a lost key cannot be recovered
      in full from the device.
    """)

    // [1/4] Adopt: on an unbound device the SK handshake IS the bind. This
    // first connect scans (we don't know the identifier yet); every later
    // step reconnects to THIS peripheral by identifier, so with a second
    // Pocket in range the proof cannot silently switch units.
    print("\n[1/4] connecting and authenticating with the new key (expect MCU&SK&OK) …")
    let (session1, device) = try await handshake(sessionKey: newKey, target: nil,
                                                 label: "  ", onAuthRejected: {
        print("""
          FAILED: the device answered MCU&SK&ERR — it is still bound to another key.
          Adoption only works on an UNBOUND device. Clear the binding first with
          `pocket-cli reset \(resetOptInFlag)` (which permanently wipes recordings),
          then retry adopt.
        """)
    })
    print("  OK: the device accepted the key for this session (MCU&SK&OK).")
    print("  (this alone proves nothing — an already-bound device answers identically)")
    await session1.stop()

    // [2/4] Persistence proof: a FRESH connection re-authenticating with the
    // new key. This is the only check that distinguishes a stored binding from
    // a key merely accepted for the first session. Targeted reconnect — the
    // proof must run against the SAME unit that step 1 bound.
    print("\n[2/4] disconnecting, reconnecting to \(device.identifier), and re-authenticating with the new key …")
    print("  (persistence across a fresh connection is the property that matters)")
    try? await Task.sleep(for: .seconds(2))   // let the device re-advertise
    let (session2, _) = try await handshake(sessionKey: newKey, target: device.identifier,
                                            label: "  ", onAuthRejected: {
        print("""
          FAILED (step 2/4): re-auth with the new key was REJECTED after a fresh
          reconnect. The key did NOT persist — it was accepted for the first
          session only and not written to non-volatile storage. The adoption did
          not stick; the device is likely still unbound or bound to something else.
        """)
    })
    print("  OK: the new key authenticated on a fresh connection — it persisted.")

    // [3/4] Cross-check the one readable part of the key: APP&WIFI returns the
    // AP password, which is the binding's first 8 characters.
    print("\n[3/4] querying APP&WIFI and confirming its PSK equals newkey[:8] …")
    let expectedPSK = String(newKey.prefix(8))
    let credentials = try await session2.request(.wifiCredentials) {
        if case .wifiCredentials = $0 { true } else { false }
    }
    guard case .wifiCredentials(let ssid, let psk) = credentials else {
        await session2.stop()
        throw PocketError.unexpectedResponse("expected MCU&WIFI&<ssid>&<psk>")
    }
    if psk == expectedPSK {
        print("  OK: MCU&WIFI psk=\(psk) == newkey[:8]=\(expectedPSK) (ssid=\(ssid)).")
        print("  the device re-derived its AP password from the new binding — the key is live.")
    } else {
        print("""
          FAILED (step 3/4): APP&WIFI psk=\(psk) does NOT equal newkey[:8]=\(expectedPSK).
          The device is serving a DIFFERENT key's AP password, so the new key is not
          the active binding despite the auth succeeding. Do not trust this adoption.
        """)
        await session2.stop()
        exit(1)
    }
    await session2.stop()

    // [4/4] Optional negative control: the OLD key should now be rejected.
    // Best-effort — its failure never invalidates the proof above.
    print("\n[4/4] negative control: confirming the OLD key is now rejected …")
    if let oldKey, !oldKey.isEmpty, oldKey != newKey {
        try? await Task.sleep(for: .seconds(2))
        await confirmOldKeyRejected(oldKey, target: device.identifier)
    } else {
        print("  skipped: set POCKET_SK to the previous key to run this negative control.")
    }

    print("""

    ADOPTED. The device authenticates with \(newKey) and keeps it across reconnects.
    Set POCKET_SK=\(newKey) for every later pocket-cli command against this device.
    """)
}

/// Builds a fresh transport + session, connects, and performs the SK
/// handshake with `sessionKey`. A nil `target` scans (first PKT01_* wins —
/// only for the initial connect, when no identifier is known yet); a non-nil
/// `target` reconnects to exactly that peripheral via `connect(to:)`, so the
/// adoption proof can never drift to a different unit in a multi-Pocket
/// environment. `onAuthRejected` runs (and the process exits 1) if the device
/// answers `MCU&SK&ERR`; every other failure is thrown for the caller's
/// generic handler.
private func handshake(sessionKey: String, target: UUID?, label: String,
                       onAuthRejected: () -> Void) async throws
    -> (session: PocketSession, device: DiscoveredDevice) {
    let transport = BLETransport()
    let scanStart = ContinuousClock.now
    let found: DiscoveredDevice
    if let target {
        found = try await transport.connect(to: target)
    } else {
        found = try await transport.connect()
    }
    print("\(label)connected to \(found.name)  [scan+connect+discover: \(milliseconds(ContinuousClock.now - scanStart)) ms]")
    let session = PocketSession(transport: transport, sessionKey: sessionKey)
    do {
        try await session.start()
    } catch PocketError.authRejected {
        await session.stop()
        onAuthRejected()
        exit(1)
    } catch {
        print("\(label)notify state: \(await transport.notifyStateSummary())")
        await session.stop()
        throw error
    }
    return (session, found)
}

/// The negative control: a fresh connection with the OLD key must be rejected.
/// Targeted at the adopted unit's identifier — testing some other Pocket's
/// rejection would prove nothing. Inconclusive outcomes (a failed reconnect)
/// are reported as such — never as success, and never as a failure of the
/// already-proven adoption.
private func confirmOldKeyRejected(_ oldKey: String, target: UUID) async {
    let transport = BLETransport()
    do {
        let found = try await transport.connect(to: target)
        print("  reconnected to \(found.name) to test the old key")
        let session = PocketSession(transport: transport, sessionKey: oldKey)
        do {
            try await session.start()
            // Reaching here means the OLD key still authenticated — unexpected.
            print("""
              WARNING: the OLD key \(oldKey) STILL authenticated (MCU&SK&OK).
              The new binding did not displace the previous one as expected — investigate
              before assuming the old key no longer grants access.
            """)
            await session.stop()
        } catch PocketError.authRejected {
            print("  OK: the old key was rejected (MCU&SK&ERR) — the new binding fully replaced it.")
            await session.stop()
        } catch {
            print("  inconclusive: the negative-control handshake failed for another reason: \(error)")
            await session.stop()
        }
    } catch {
        print("  inconclusive: could not reconnect for the negative control: \(error)")
        await transport.disconnect()
    }
}
