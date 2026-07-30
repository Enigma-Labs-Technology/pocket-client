// pocket-client/Sources/pocket-cli/AccessPointLifetime.swift
//
// `pocket-cli probe-ap-lifetime` — how long does the recorder keep its Wi-Fi
// access point up, and does `APP&WPING` extend it?
//
// Two releases assume it does. `APP&WPING` is documented as the "Wi-Fi-session
// keepalive"; 0.1.3 pings during the TCP connect and 0.1.4 moved the pinger to
// start *before* the joiner, specifically so a human-paced manual join would be
// covered. Nobody measured it, and it may only keep the BLE session from idling
// out. On 2026-07-29 a `sync-wifi` run reached `MCU&WIFIS&2` — the device
// confirming the host had associated — and the TCP connect still timed out after
// 30 s with 0.1.4's keepalive running throughout, which leaves two readings with
// opposite consequences (see this command's intro text, and
// Sources/PocketClient/Transport/AccessPointLifetimeProbe.swift).
//
// This command measures it with **no join at all**, so no host-side variable can
// be mistaken for the device's behaviour. It is deliberately half an experiment
// per run: run it once silent, once with --keepalive, and the difference is the
// answer. The transcript is the deliverable — capture it.

import Foundation
import PocketClient

/// `Duration` back to the whole seconds the flags are written in, so the printed
/// "now run the other half" command quotes the same numbers this run used.
private func wholeSeconds(_ duration: Duration) -> Int { Int(duration.components.seconds) }

/// Parses `probe-ap-lifetime`'s flags. Called during argument validation, before
/// the radio is touched — a bad number must never reach the device.
///
/// Seconds only, and integers: this is a stopwatch, and a cadence nobody can type
/// twice the same way is a cadence that cannot produce comparable runs.
func accessPointLifetimeSettings(from tokens: [String]) -> AccessPointLifetimeSettings {
    var settings = AccessPointLifetimeSettings()
    var index = 0
    var sawPingFlag = false

    func seconds(after flag: String) -> Duration {
        guard index + 1 < tokens.count, let value = Int(tokens[index + 1]), value >= 1 else {
            usageError("\(flag) needs a positive whole number of seconds")
        }
        index += 1
        return .seconds(value)
    }

    while index < tokens.count {
        switch tokens[index] {
        case "--keepalive":
            settings.keepalive = true
        case "--cap":
            settings.cap = seconds(after: "--cap")
        case "--poll":
            settings.pollInterval = seconds(after: "--poll")
        case "--ping":
            settings.pingInterval = seconds(after: "--ping")
            sawPingFlag = true
        default:
            usageError("unknown probe-ap-lifetime option '\(tokens[index])' — "
                       + "expected --keepalive, --cap <s>, --poll <s>, --ping <s>")
        }
        index += 1
    }

    // Catch a run that cannot answer anything before it costs the operator its
    // whole cap: a ping interval at or past the cap means no APP&WPING is ever
    // due, so a "pinging" run would silently be a second silent one.
    if settings.keepalive, settings.pingInterval >= settings.cap {
        usageError("--ping \(wholeSeconds(settings.pingInterval)) is not shorter than --cap "
                   + "\(wholeSeconds(settings.cap)), so no APP&WPING would ever be sent and the "
                   + "run could not test the keepalive at all")
    }
    if sawPingFlag, !settings.keepalive {
        print("note: --ping only has an effect with --keepalive; this run will send no APP&WPING")
    }
    return settings
}

/// Counts interrupts so the second Ctrl-C can mean something different from the
/// first. Lock-guarded: the handler runs on a Dispatch queue, not this flow.
private final class InterruptCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

/// Cancels `task` on the first SIGINT, and abandons the process on a second.
///
/// Ctrl-C's default action is immediate termination, which on this command would
/// leave the device broadcasting an access point that competes with BLE for the
/// same 2.4 GHz radio — the exact state the probe is otherwise careful never to
/// leave behind, and the reason the transfer code sends `APP&WIFIC` on all of its
/// failure paths. So the first interrupt cancels the probe instead, and the
/// probe's own cancellation path closes the access point before returning. A
/// second interrupt is honoured literally, and says what it costs.
///
/// The signal source runs on a global queue, not the main one: this executable's
/// main thread belongs to Swift concurrency and never drains a run loop, so a
/// main-queue source would never fire.
private func cancelOnInterrupt<T: Sendable>(_ task: Task<T, Error>) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let interrupts = InterruptCount()
    source.setEventHandler {
        if interrupts.next() == 1 {
            print("""

              interrupted — closing the access point (APP&WIFIC) and reporting what was
              measured so far. Ctrl-C again to abandon the run instead, which leaves the
              device broadcasting.
            """)
            task.cancel()
        } else {
            print("""

              abandoning the run. The device may still be broadcasting its access point —
              close it with:  POCKET_SK=… swift run pocket-cli raw WIFIC
            """)
            exit(130)
        }
    }
    source.resume()
    return source
}

/// `pocket-cli probe-ap-lifetime [--keepalive] [--cap <s>] [--poll <s>] [--ping <s>]`
///
/// The device is already connected and authenticated; the caller owns the event
/// printer, so unmatched frames still surface as usual.
func runAccessPointLifetimeProbe(device: PocketDevice,
                                 settings: AccessPointLifetimeSettings) async throws {
    print("""

    probe-ap-lifetime: measuring how long this recorder keeps its Wi-Fi access point
      up, and whether APP&WPING extends it.

      WHY THIS EXISTS. APP&WPING is documented as the "Wi-Fi-session keepalive", and
      this client read that as extending the access point: 0.1.3 pings during the TCP
      connect, and 0.1.4 moved the pinger to start BEFORE the join so a human-paced
      manual join would be covered by it. Neither release measured it. On 2026-07-29 a
      sync-wifi run reached MCU&WIFIS&2 — the device itself confirming this host had
      associated — and the TCP connect to 192.168.200.1:8475 still timed out after
      30 s, with the keepalive running throughout. Two readings survive that:

        A. APP&WPING does extend the access point, and something else is wrong — the
           device's TCP listener, or this client's socket code.
        B. APP&WPING does not extend it, in which case the manual-join path cannot
           work at any human speed and two releases rest on a false premise.

      NOTHING JOINS THE ACCESS POINT in this run. No association, no DHCP, no socket:
      the device's own APP&WIFIS is the only witness, so nothing this host does can be
      mistaken for what the device does.

      ONE RUN IS HALF THE EXPERIMENT. This one has the keepalive \
    \(settings.keepalive ? "ON" : "OFF"). Run it the
      other way too — the verdict below names the exact command — and the difference
      between the two lifetimes is the answer.

      It runs for up to \(wholeSeconds(settings.cap)) s; the device closing its access point sooner is
      the number we are here for. Ctrl-C closes the access point and reports early.

    """)

    let probe = Task { () -> AccessPointLifetime in
        try await device.probeAccessPointLifetime(settings) { step in
            // The library renders every line, so the live transcript and the
            // recorded one are the same text by construction.
            if case .accessPointStarted(let ssid, let stateBefore) = step {
                print(settings.header(ssid: ssid, stateBefore: stateBefore))
                print("\ntimeline (elapsed from the MCU&WIFIO ack; * = state change):")
            }
            print(step.transcriptLine)
            fflush(stdout)
        }
    }
    let interrupts = cancelOnInterrupt(probe)
    defer {
        interrupts.cancel()
        signal(SIGINT, SIG_DFL)   // nothing left to protect; Ctrl-C means Ctrl-C again
    }
    let result = try await probe.value

    print("\n\(result.measurements)")
    print("\nverdict:")
    // `verdictText`'s first paragraph is the headline; the rest are what the run
    // did and did not establish. Wrapped so a captured transcript reads as prose
    // rather than as whatever width the terminal happened to be.
    for (index, paragraph) in result.verdictText.components(separatedBy: "\n\n").enumerated() {
        if index > 0 { print("") }
        print(wrappedForTranscript(paragraph, indent: "  "))
    }

    // The other half, spelled out, with this run's cadence carried over so the two
    // transcripts are actually comparable. `--ping` rides along only when the
    // suggested run is the pinging one — on the silent one it has no effect and
    // would make the suggested command print its own "no effect" note.
    var flags: [String] = []
    if !settings.keepalive {
        flags.append("--keepalive")
        flags.append("--ping \(wholeSeconds(settings.pingInterval))")
    }
    flags.append("--cap \(wholeSeconds(settings.cap))")
    flags.append("--poll \(wholeSeconds(settings.pollInterval))")
    print("""

      the other half of the experiment:
        POCKET_SK=… swift run pocket-cli probe-ap-lifetime \(flags.joined(separator: " "))

      Then paste both transcripts into docs/protocol/ble-protocol.md. A negative
      result settles it just as well as a positive one — and if APP&WPING turns out
      not to extend the access point, that has to be recorded against 0.1.3 and
      0.1.4 rather than left as a reading of the command table.
    """)
}
