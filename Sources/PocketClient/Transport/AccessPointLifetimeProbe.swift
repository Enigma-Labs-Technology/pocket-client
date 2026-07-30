// pocket-client/Sources/PocketClient/Transport/AccessPointLifetimeProbe.swift
//
// How long does the recorder keep its Wi-Fi access point up, and does
// `APP&WPING` change that?
//
// Two releases rest on the answer. `APP&WPING` is documented as the
// "Wi-Fi-session keepalive" (docs/protocol/ble-protocol.md, command table), and
// this package read that as *extending the access point*: 0.1.3 pings during the
// TCP connect, and 0.1.4 moved the pinger to start before the joiner precisely so
// a human-paced manual join would be covered by it. Neither release ever measured
// it. The keepalive may only keep the BLE session from idling out.
//
// The evidence that forces the question, from hardware on 2026-07-29: a
// `sync-wifi` run reached `MCU&WIFIS&2` — the device itself confirming the host
// had associated — and the TCP connect to 192.168.200.1:8475 still timed out
// after 30 s, with 0.1.4's keepalive running throughout. Two readings survive
// that, with opposite consequences:
//
//   A. `APP&WPING` does extend the access point, and something else is wrong —
//      the device's TCP listener, or this client's socket code.
//   B. `APP&WPING` does not extend the access point, in which case the
//      manual-join path cannot work at any human speed, and both 0.1.3 and 0.1.4
//      are built on a premise that has to be corrected in the record.
//
// This file measures it directly, and the measurement's whole design is that it
// **never joins the access point**. No association, no DHCP, no socket — so no
// host-side variable (a stale saved password, a slow person in System Settings,
// macOS auto-joining a remembered network) can be mistaken for the device's
// behaviour. The only witness is the device's own `APP&WIFIS`, which is already
// this sequence's state oracle.
//
// It is an experiment, and it is deliberately half of one per run: the keepalive
// is a flag, the operator runs the probe twice, and the difference between the two
// runs is the answer. Every verdict below therefore names the run that is still
// missing and says what each possible comparison would mean — a single run cannot
// distinguish A from B, and saying otherwise would be how a measurement starts
// costing more than it saves.
import Foundation

/// How long to watch the access point, how often to ask about it, and whether to
/// keep the Wi-Fi session alive while watching.
public struct AccessPointLifetimeSettings: Sendable, Equatable {
    /// Send `APP&WPING` every `pingInterval` while the access point is up.
    ///
    /// **This flag is the experiment.** Off measures what the device does
    /// unaided; on measures what it does while being pinged exactly as a real
    /// transfer pings it. One run answers nothing on its own.
    public var keepalive: Bool
    /// `APP&WIFIS` cadence. 1 s is the vendor app's, from the capture.
    public var pollInterval: Duration
    /// `APP&WPING` cadence when `keepalive` is set. 10 s is the vendor app's, and
    /// `WiFiReadiness`'s default, so a pinging run reproduces what a real
    /// transfer does while it waits for a join rather than some louder cadence
    /// that would not generalise.
    public var pingInterval: Duration
    /// Hard stop. The probe closes the access point and reports at this point
    /// even if the device is still broadcasting — an access point left up
    /// competes with BLE for the same 2.4 GHz radio, so nothing here runs
    /// unbounded.
    public var cap: Duration

    public init(keepalive: Bool = false,
                pollInterval: Duration = .seconds(1),
                pingInterval: Duration = .seconds(10),
                cap: Duration = .seconds(180)) {
        self.keepalive = keepalive
        self.pollInterval = pollInterval
        self.pingInterval = pingInterval
        self.cap = cap
    }
}

extension AccessPointLifetimeSettings {
    /// The transcript's header: what this run is doing, and at what cadence.
    ///
    /// Rendered from the settings rather than from a finished run, so a live
    /// consumer can print it the moment the access point starts and the recorded
    /// transcript can print the same block afterwards — one function, so the two
    /// cannot drift.
    public func header(ssid: String, stateBefore: WiFiState?) -> String {
        let ping = keepalive
            ? "every \(elapsedSecondsText(pingInterval))  (APP&WPING)"
            : "none — this run sends no APP&WPING"
        let before = stateBefore.map { "MCU&WIFIS&\($0.rawValue)" } ?? "no answer"
        return """
        access-point lifetime probe — keepalive \(keepalive ? "ON" : "OFF")
          access point SSID:   \(ssid)
          state before start:  \(before)   (APP&WIFIS, before APP&WIFIO)
          poll cadence:        every \(elapsedSecondsText(pollInterval))  (APP&WIFIS)
          ping cadence:        \(ping)
          cap:                 \(elapsedSecondsText(cap))
          t=0:                 the MCU&WIFIO ack
          nothing joins this access point: no association, no DHCP, no socket. The
          AP password arrived with the SSID and was discarded unread.
        """
    }
}

/// One `APP&WIFIS` poll: when it happened, and what the device said.
public struct AccessPointObservation: Sendable, Equatable {
    /// Elapsed since the `MCU&WIFIO` ack — the instant the access point started,
    /// and t=0 for every number this probe reports.
    public let elapsed: Duration
    /// The state the device reported, or `nil` when it did not answer this poll
    /// usably. Silence is recorded rather than skipped: a device that stops
    /// answering `APP&WIFIS` is itself a finding, and one that must not be
    /// confused with a device that answered `0`.
    public let state: WiFiState?
    /// This poll's answer differs from the previous poll's (the first
    /// observation is always a change). The transitions are the evidence; the
    /// repeats are how long each state lasted.
    public let isChange: Bool

    public init(elapsed: Duration, state: WiFiState?, isChange: Bool) {
        self.elapsed = elapsed
        self.state = state
        self.isChange = isChange
    }
}

/// One thing the probe did, in the order it did it. Reported live through
/// `onStep` so a CLI can print the experiment as it unfolds, and kept in
/// `AccessPointLifetime.steps` so the same rendering produces the transcript —
/// live output and recorded transcript cannot drift, because they are one
/// function.
public enum AccessPointProbeStep: Sendable, Equatable {
    /// The preamble finished and `MCU&WIFIO` was acked. **The clock starts
    /// here**, so this step is the transcript's header rather than a measurement.
    case accessPointStarted(ssid: String, stateBefore: WiFiState?)
    /// One `APP&WIFIS` poll.
    case observed(AccessPointObservation)
    /// One `APP&WPING` went out, and whether `MCU&WPING` came back. Both halves
    /// matter: a keepalive nothing answers has not been shown to reach the
    /// device, and a conclusion drawn from one would be worthless.
    case pinged(elapsed: Duration, answered: Bool)
    /// Why the watch ended; `APP&WIFIC` follows immediately.
    case closing(elapsed: Duration, reason: String)

    /// The transcript line for this step. `*` marks a state change.
    public var transcriptLine: String {
        switch self {
        case .accessPointStarted(let ssid, let stateBefore):
            let before = stateBefore.map { "MCU&WIFIS&\($0.rawValue)" } ?? "no answer"
            return "  \(padRight("t=0", 12))MCU&WIFIO acked — access point starting, SSID \(ssid) "
                + "(state before APP&WIFIO: \(before))"
        case .observed(let observation):
            let marker = observation.isChange ? "*" : " "
            let what = observation.state.map(wifiStateText)
                ?? "NO ANSWER to APP&WIFIS within the poll timeout"
            return "\(marker) \(padRight(elapsedColumn(observation.elapsed), 12))\(what)"
        case .pinged(let elapsed, let answered):
            return "  \(padRight(elapsedColumn(elapsed), 12))APP&WPING sent — "
                + (answered ? "MCU&WPING came back" : "NO MCU&WPING came back")
        case .closing(let elapsed, let reason):
            return "  \(padRight(elapsedColumn(elapsed), 12))\(reason) — sending APP&WIFIC"
        }
    }
}

/// What one probe run established, and — just as importantly — what it did not.
public struct AccessPointLifetime: Sendable {
    /// Why the watch ended.
    public enum Outcome: Sendable, Equatable {
        /// The device reported `MCU&WIFIS&0`: its access point went off. This is
        /// the measurement the experiment wants.
        case accessPointClosed(after: Duration)
        /// `cap` elapsed with the access point still up. Not a lifetime — a lower
        /// bound on one.
        case stillUpAtCap(Duration)
        /// The caller cancelled (on the CLI: Ctrl-C). The access point is still
        /// closed; the measurement is partial.
        case interrupted(after: Duration)
        /// The BLE session stopped being authenticated, so the only witness to
        /// the access point was gone.
        case linkLost(after: Duration)
    }

    public let settings: AccessPointLifetimeSettings
    /// The SSID the device reported for its access point. The AP password came
    /// back in the same frame and is deliberately discarded unread: nothing joins
    /// this access point, so the probe never needs it and can never print it.
    public let ssid: String
    /// `MCU&WIFIS&<n>` before `APP&WIFIO` — normally `0`. Anything else means the
    /// device was already broadcasting when the run started, which changes what
    /// the numbers below mean.
    public let stateBeforeStart: WiFiState?
    /// Every poll, every ping, and the close, in order.
    public let steps: [AccessPointProbeStep]
    public let pingsSent: Int
    public let pingsAnswered: Int
    /// After `APP&WIFIC`, did the device confirm `MCU&WIFIS&0`? `nil` when the
    /// confirming poll could not be made or went unanswered. A probe that cannot
    /// prove it closed the access point has to say so.
    public let closeConfirmed: Bool?
    public let outcome: Outcome

    public init(settings: AccessPointLifetimeSettings, ssid: String,
                stateBeforeStart: WiFiState?, steps: [AccessPointProbeStep],
                pingsSent: Int, pingsAnswered: Int, closeConfirmed: Bool?,
                outcome: Outcome) {
        self.settings = settings
        self.ssid = ssid
        self.stateBeforeStart = stateBeforeStart
        self.steps = steps
        self.pingsSent = pingsSent
        self.pingsAnswered = pingsAnswered
        self.closeConfirmed = closeConfirmed
        self.outcome = outcome
    }

    // MARK: - What the steps add up to

    public var observations: [AccessPointObservation] {
        steps.compactMap { if case .observed(let o) = $0 { o } else { nil } }
    }

    /// Only the polls whose answer differed from the one before — the state
    /// machine this run actually walked.
    public var transitions: [AccessPointObservation] {
        observations.filter(\.isChange)
    }

    /// When the device first reported its access point up (`3`, or `2`/`1` if
    /// something had already associated). The capture's figure is ~114 ms.
    public var accessPointUpAfter: Duration? {
        observations.first { $0.state != nil && $0.state != .off }?.elapsed
    }

    /// The measured access-point lifetime — only for a run that saw it go off.
    /// `nil` otherwise, deliberately: a run that hit the cap has a lower bound,
    /// not a lifetime, and conflating the two is how a cap gets quoted as a
    /// measurement.
    public var lifetime: Duration? {
        if case .accessPointClosed(let after) = outcome { after } else { nil }
    }

    public var pollsAttempted: Int { observations.count }
    public var pollsAnswered: Int { observations.filter { $0.state != nil }.count }

    /// A client associated during the run (`MCU&WIFIS&2` or `1`) even though this
    /// probe never joins. Something else did — most likely this Mac auto-joining
    /// a network it remembers — and an association may itself affect how long the
    /// device holds the access point up, so the run has to be reported as
    /// confounded rather than quietly averaged in.
    public var associationObserved: Bool {
        observations.contains { $0.state == .clientJoined || $0.state == .tcpConnected }
    }

    // MARK: - The verdict

    public var verdict: AccessPointLifetimeVerdict {
        // Asked for a keepalive and never sent one: whatever this run measured,
        // it is not a measurement of the keepalive. Checked before the outcome,
        // because it invalidates every branch of it.
        if settings.keepalive && pingsSent == 0 {
            return .inconclusive(
                "the keepalive was asked for but no APP&WPING ever went out: the run ended before "
                + "the first one was due at \(elapsedSecondsText(settings.pingInterval)). What this "
                + "measured is a silent baseline, not a test of the keepalive — set a ping interval "
                + "below the observed lifetime and run it again")
        }
        switch outcome {
        case .accessPointClosed(let after):
            return settings.keepalive
                ? .closedDespiteKeepalive(lifetime: after, pingsSent: pingsSent,
                                          pingsAnswered: pingsAnswered)
                : .closedWithoutKeepalive(lifetime: after)
        case .stillUpAtCap(let cap):
            return settings.keepalive
                ? .survivedCapWithKeepalive(cap: cap, pingsSent: pingsSent,
                                            pingsAnswered: pingsAnswered)
                : .survivedCapWithoutKeepalive(cap: cap)
        case .interrupted(let after):
            return .inconclusive(
                "the run was interrupted after \(elapsedSecondsText(after)), before the device had "
                + "reported its access point off, so no lifetime was measured")
        case .linkLost(let after):
            return .inconclusive(
                "the BLE session stopped being authenticated after "
                + "\(elapsedSecondsText(after)), and the device is the only witness to its own "
                + "access point — nothing can be concluded about the access point from a run that "
                + "lost the link")
        }
    }

    /// The verdict as prose: what this run established, what it did not, and the
    /// exact run that would complete the experiment.
    public var verdictText: String {
        var body = [verdict.headline]
        switch verdict {
        case .closedDespiteKeepalive(let lifetime, let sent, let answered):
            body.append(
                "The device reported MCU&WIFIS&0 \(elapsedSecondsText(lifetime)) after acking "
                + "APP&WIFIO, while this run was sending APP&WPING every "
                + "\(elapsedSecondsText(settings.pingInterval)) — \(sent) went out and \(answered) "
                + "came back. A keepalive that extended the access point could not allow that.")
            body.append(
                "What settles it: run this again WITHOUT the keepalive. A silent lifetime of about "
                + "\(elapsedSecondsText(lifetime)) means APP&WPING does not extend the access point "
                + "at all — the manual-join path cannot work at any human speed, and the premise "
                + "0.1.3 and 0.1.4 were built on has to be corrected in the record. A silent "
                + "lifetime that is markedly shorter means the keepalive does extend the access "
                + "point, just not far enough, and the difference between the two numbers is the "
                + "figure to quote.")
        case .closedWithoutKeepalive(let lifetime):
            body.append(
                "No APP&WPING was sent: the device brought its access point up and took it down "
                + "\(elapsedSecondsText(lifetime)) later entirely on its own. That is the baseline, "
                + "and it is half the experiment.")
            body.append(
                "What settles it: run this again WITH the keepalive. A materially longer lifetime "
                + "means APP&WPING does extend the access point, and the figure to quote is the "
                + "difference. About the same \(elapsedSecondsText(lifetime)) means it does not — "
                + "it keeps the BLE session alive and nothing else — in which case the manual-join "
                + "path cannot work at any human speed and both 0.1.3 and 0.1.4 rest on a false "
                + "premise.")
        case .survivedCapWithKeepalive(let cap, let sent, let answered):
            body.append(
                "The access point was still up when the cap of \(elapsedSecondsText(cap)) expired, "
                + "with \(sent) APP&WPING sent and \(answered) answered. Consistent with the "
                + "keepalive extending it — but only in comparison with the silent run.")
            body.append(
                "What settles it: run this again WITHOUT the keepalive. If the silent run's access "
                + "point goes off well before \(elapsedSecondsText(cap)), the keepalive extended it "
                + "and this is the evidence. If the silent run also reaches the cap, the cap is "
                + "simply shorter than this device's unaided access-point lifetime and this run "
                + "distinguishes nothing — raise the cap until the silent run dies, then re-run "
                + "this one.")
        case .survivedCapWithoutKeepalive(let cap):
            body.append(
                "The device held its access point up for the whole cap of "
                + "\(elapsedSecondsText(cap)) with no keepalive at all, so nothing here can measure "
                + "what APP&WPING adds: raise the cap and run again until the access point goes off "
                + "by itself, and only then run the pinging half.")
            body.append(
                "This result already bears on the failure that prompted the experiment. If "
                + "\(elapsedSecondsText(cap)) is longer than the pause that lost the access point "
                + "on hardware, then access-point lifetime did not cause that failure, and what "
                + "remains to suspect is the device's TCP listener on "
                + "\(WiFiEndpoint.deviceHost):\(WiFiEndpoint.devicePort) or this client's socket "
                + "code.")
        case .inconclusive:
            body.append(
                "Nothing about APP&WPING follows from this run. Both readings are still open: that "
                + "it extends the access point (and something else broke the transfer), and that it "
                + "only keeps the BLE session alive (and the manual-join path cannot work at human "
                + "speed).")
        }
        // A keepalive nothing answered has not been shown to reach the device, and
        // that undercuts every branch above rather than just one of them.
        if pingsSent > 0 && pingsAnswered == 0 {
            body.append(
                "CAVEAT: \(pingsSent) APP&WPING went out and not one MCU&WPING came back, so this "
                + "run did not establish that the device received the keepalive at all — and a "
                + "conclusion about a keepalive the device may never have seen is worthless. Check "
                + "the BLE link (the session's own APP&BAT keepalive should be answered) and run it "
                + "again before concluding anything about APP&WPING.")
        }
        if associationObserved {
            body.append(
                "CONFOUNDED: this probe never joins, yet the device reported an associated client "
                + "(MCU&WIFIS&2, or 1) during the run — something else joined the access point, "
                + "most likely this Mac auto-joining a network it remembers. An association may "
                + "itself change how long the device holds the access point up. Forget the SSID in "
                + "Wi-Fi settings and run it again before quoting these numbers.")
        }
        if stateBeforeStart != .off {
            let before = stateBeforeStart.map { "MCU&WIFIS&\($0.rawValue)" } ?? "no answer"
            body.append(
                "NOTE: the device answered \(before) before APP&WIFIO, not MCU&WIFIS&0, so its "
                + "access point was not starting from off. t=0 is the APP&WIFIO ack either way, but "
                + "the lifetime measured from it may be an access point that was already running.")
        }
        return body.joined(separator: "\n\n")
    }

    // MARK: - The transcript

    /// The run's parameters. Printed before the timeline, because every number
    /// after it is only meaningful against the cadence that produced it.
    public var header: String {
        settings.header(ssid: ssid, stateBefore: stateBeforeStart)
    }

    /// Every step, one line each, `*` on the state changes.
    public var timeline: String {
        steps.map(\.transcriptLine).joined(separator: "\n")
    }

    /// The numbers, absolute and unrounded, for pasting into the protocol doc.
    public var measurements: String {
        let up = accessPointUpAfter.map(elapsedSecondsText) ?? "never reported up"
        let life = lifetime.map { "\(elapsedSecondsText($0))   (the device reported MCU&WIFIS&0)" }
            ?? "not measured — \(outcomeText)"
        // Spelled `.some`/`.none` rather than `true`/`false`/`nil`: the latter is
        // accepted as exhaustive over `Bool?` by some Swift compilers and rejected
        // by others, and CI caught the difference that a local Xcode did not.
        let closed: String
        switch closeConfirmed {
        case .some(true):  closed = "sent; the device then reported MCU&WIFIS&0"
        case .some(false): closed = "sent, but the device did NOT report MCU&WIFIS&0 afterwards"
        case .none:        closed = "sent; no confirming APP&WIFIS answer, so the close is unconfirmed"
        }
        return """
        measured:
          access point up after:      \(up)
          access point lifetime:      \(life)
          state transitions:          \(transitions.count) \
        (\(transitions.map { observation in
            observation.state.map { "\($0.rawValue)" } ?? "silent"
        }.joined(separator: " → ")))
          APP&WIFIS polls answered:   \(pollsAnswered) of \(pollsAttempted)
          APP&WPING sent / answered:  \(pingsSent) / \(pingsAnswered)
          APP&WIFIC:                  \(closed)
        """
    }

    /// One line naming how the watch ended.
    public var outcomeText: String {
        switch outcome {
        case .accessPointClosed(let after):
            return "the device reported its access point off after \(elapsedSecondsText(after))"
        case .stillUpAtCap(let cap):
            return "the access point was still up at the cap of \(elapsedSecondsText(cap))"
        case .interrupted(let after):
            return "interrupted after \(elapsedSecondsText(after))"
        case .linkLost(let after):
            return "the BLE session stopped being authenticated after \(elapsedSecondsText(after))"
        }
    }

    /// The whole experiment as one block: parameters, timeline, numbers, verdict.
    /// This is the thing to paste into `docs/protocol/ble-protocol.md`.
    public var transcript: String {
        """
        \(header)

        timeline (elapsed from the MCU&WIFIO ack; * = state change):
        \(timeline)

        \(measurements)

        verdict:
        \(verdictText)
        """
    }
}

/// What one run can honestly claim. Typed rather than only prose so a consumer —
/// and the test suite — can branch on the finding instead of matching strings.
public enum AccessPointLifetimeVerdict: Sendable, Equatable {
    /// The access point went off while `APP&WPING` was being sent. Reading B, one
    /// run short of settled.
    case closedDespiteKeepalive(lifetime: Duration, pingsSent: Int, pingsAnswered: Int)
    /// The access point went off with no keepalive at all: the unassisted
    /// lifetime, and the baseline the pinging run is compared against.
    case closedWithoutKeepalive(lifetime: Duration)
    /// Still up at the cap, with pings going out. Consistent with reading A, and
    /// only meaningful against a silent run that died sooner.
    case survivedCapWithKeepalive(cap: Duration, pingsSent: Int, pingsAnswered: Int)
    /// Still up at the cap with no pings: the cap is shorter than the device's own
    /// access-point lifetime, so this run cannot measure the keepalive's effect.
    case survivedCapWithoutKeepalive(cap: Duration)
    /// The run did not measure a lifetime, and says why.
    case inconclusive(String)

    /// One line, in the register the rest of this package uses for findings.
    public var headline: String {
        switch self {
        case .closedDespiteKeepalive(let lifetime, let sent, _):
            return "APP&WPING DID NOT KEEP THE ACCESS POINT UP — it went off after "
                + "\(elapsedSecondsText(lifetime)) with \(sent) keepalive(s) sent."
        case .closedWithoutKeepalive(let lifetime):
            return "the unassisted access-point lifetime on this device is "
                + "\(elapsedSecondsText(lifetime))."
        case .survivedCapWithKeepalive(let cap, let sent, _):
            return "THE ACCESS POINT WAS STILL UP at the cap of \(elapsedSecondsText(cap)), with "
                + "\(sent) keepalive(s) sent."
        case .survivedCapWithoutKeepalive(let cap):
            return "the access point was still up at the cap of \(elapsedSecondsText(cap)) with no "
                + "keepalive at all — this cap measures nothing."
        case .inconclusive(let reason):
            return "INCONCLUSIVE — \(reason)."
        }
    }
}

// MARK: - Rendering helpers

/// `Duration` as seconds with millisecond precision. Every number this
/// experiment reports goes through here, so the transcript's units are uniform
/// and quotable.
func elapsedSecondsText(_ duration: Duration) -> String {
    // `Int`, not the components' `Int64`: `String(format:)`'s `%d` is an `Int`
    // conversion on these platforms, and the CLI's own `milliseconds` helper
    // narrows the same way.
    let (seconds, attoseconds) = duration.components
    return String(format: "%d.%03d s",
                  Int(seconds), Int(attoseconds / 1_000_000_000_000_000))
}

/// The timeline's elapsed column, signed so it reads as an offset from t=0.
func elapsedColumn(_ duration: Duration) -> String { "+" + elapsedSecondsText(duration) }

/// Pads to `width` without ever truncating — a long number must run into the next
/// column rather than lose a digit.
func padRight(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// `MCU&WIFIS&<n>` and what it means, so a transcript needs no legend.
func wifiStateText(_ state: WiFiState) -> String {
    switch state {
    case .off:           return "MCU&WIFIS&0   access point OFF"
    case .accessPointUp: return "MCU&WIFIS&3   access point up, nothing associated"
    case .clientJoined:  return "MCU&WIFIS&2   a client is associated (nothing here joined)"
    case .tcpConnected:  return "MCU&WIFIS&1   a TCP client is connected on :8475"
    }
}

// MARK: - The probe

extension PocketSession {
    /// Measures how long the device keeps its Wi-Fi access point up, and whether
    /// `APP&WPING` extends it.
    ///
    /// **An instrument, not a feature.** It changes no transfer behaviour and is
    /// never called by one; it exists so the assumption under 0.1.3 and 0.1.4 can
    /// be checked against the device instead of read out of a command table. See
    /// this file's header for why that matters.
    ///
    /// What it does, and deliberately no more:
    ///
    /// 1. `APP&SHUT` → `APP&WIFIS` → `APP&WIFI` → `APP&WIFIO` — the same
    ///    capture-verified preamble every transfer uses (steps 1–4 of Wi-Fi Quick
    ///    Transfer), so what it brings up is the same access point a transfer
    ///    brings up.
    /// 2. polls `APP&WIFIS` every `pollInterval`, recording each answer against
    ///    the elapsed time from the `MCU&WIFIO` ack;
    /// 3. sends `APP&WPING` every `pingInterval` **only** when
    ///    `settings.keepalive` is set, counting both the sends and the replies;
    /// 4. stops when the device reports `MCU&WIFIS&0`, at `settings.cap`, on
    ///    cancellation, or when the link stops being authenticated;
    /// 5. closes the access point on **every** one of those exits.
    ///
    /// **There is no join.** Nothing associates with the access point, no DHCP
    /// runs, no socket opens — which is the point: the device's own `APP&WIFIS` is
    /// the only witness, so no host-side variable can be mistaken for the
    /// device's behaviour. It follows that this method needs no `HotspotJoining`
    /// and takes none.
    ///
    /// **Cancellation returns a result rather than throwing.** A cancelled
    /// measurement's data *is* the measurement — an operator pressing Ctrl-C on a
    /// three-minute watch means "stop and tell me what you saw", not "discard
    /// it" — so the outcome is `.interrupted` and the partial timeline comes back
    /// intact. The access point is closed first, before this returns, on that
    /// path as on every other: an access point left broadcasting competes with
    /// BLE for the same 2.4 GHz radio, which is why the transfer code sends
    /// `APP&WIFIC` on all of its failure paths too.
    ///
    /// Claims the same exclusive transfer slot as the downloads and the live
    /// stream. It transfers nothing, but it owns the device's access point for
    /// the duration, and a concurrent Wi-Fi transfer would fight it for exactly
    /// that.
    ///
    /// Throws only before the access point is up: `PocketError.busy` for the
    /// slot, `.notAuthenticated`, and whatever the preamble's four commands
    /// throw. Once the watch has started, every ending is an `Outcome`.
    public func probeAccessPointLifetime(
        _ settings: AccessPointLifetimeSettings = AccessPointLifetimeSettings(),
        onStep: (@Sendable (AccessPointProbeStep) -> Void)? = nil
    ) async throws -> AccessPointLifetime {
        try beginTransfer()
        defer { endTransfer() }
        return try await runAccessPointLifetimeProbe(settings, onStep: onStep)
    }

    private func runAccessPointLifetimeProbe(
        _ settings: AccessPointLifetimeSettings,
        onStep: (@Sendable (AccessPointProbeStep) -> Void)?
    ) async throws -> AccessPointLifetime {
        // 1–2. Abort anything in flight and read the state. SHUT is
        // fire-and-forget: an idle device sends no MCU&SHUT (live-probe verified).
        try await send(.wifiShutdown)
        let before = try await request(.wifiStatus, timeout: .seconds(5)) {
            if case .wifiState = $0 { true } else { false }
        }
        var stateBefore: WiFiState?
        if case .wifiState(let state) = before { stateBefore = state }

        // 3. Credentials are the synchronous reply to APP&WIFI. This is NOT the
        // forbidden provisioning command APP&WIFI&CH&… — it carries no arguments.
        // The passphrase is discarded on the spot: nothing joins this access
        // point, so the probe never needs it and cannot print it.
        let credentials = try await request(.wifiCredentials, timeout: .seconds(5)) {
            if case .wifiCredentials = $0 { true } else { false }
        }
        guard case .wifiCredentials(let ssid, _) = credentials else {
            throw PocketError.unexpectedResponse("expected MCU&WIFI&<ssid>&<psk>")
        }

        // 4. APP&WIFIO starts the access point. From here every exit closes it.
        do {
            _ = try await request(.wifiAccessPointOn, timeout: .seconds(5)) {
                $0 == .wifiAccessPointOn
            }
        } catch {
            // The access point may have started despite a lost ack.
            _ = await closeAccessPointAfterProbe(aborting: true)
            throw error
        }

        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + settings.cap
        var steps: [AccessPointProbeStep] = []
        func record(_ step: AccessPointProbeStep) {
            steps.append(step)
            onStep?(step)
        }
        record(.accessPointStarted(ssid: ssid, stateBefore: stateBefore))

        // Matches `awaitWiFiClientJoined`: the first ping is due one interval in,
        // not immediately, so a pinging run reproduces a real transfer's cadence
        // rather than a louder one.
        var lastPing = start
        var pingsSent = 0
        var pingsAnswered = 0
        var lastState: WiFiState?
        var hasObserved = false
        var outcome: AccessPointLifetime.Outcome?

        while outcome == nil {
            if Task.isCancelled {
                outcome = .interrupted(after: clock.now - start)
                break
            }
            if clock.now >= deadline {
                outcome = .stillUpAtCap(clock.now - start)
                break
            }
            guard isAuthenticated else {
                outcome = .linkLost(after: clock.now - start)
                break
            }

            let response = try? await request(
                .wifiStatus,
                timeout: commandBound(remaining: deadline - clock.now,
                                      cadence: settings.pollInterval * 4)
            ) {
                if case .wifiState = $0 { true } else { false }
            }
            var state: WiFiState?
            if case .wifiState(let seen)? = response { state = seen }
            let elapsed = clock.now - start
            let isChange = !hasObserved || lastState != state
            hasObserved = true
            lastState = state
            record(.observed(AccessPointObservation(elapsed: elapsed, state: state,
                                                    isChange: isChange)))
            if state == .off {
                outcome = .accessPointClosed(after: elapsed)
                break
            }

            if settings.keepalive, clock.now - lastPing >= settings.pingInterval {
                // `request`, not the session's fire-and-forget keepalive: this run
                // needs to know whether MCU&WPING came back, because a keepalive
                // nothing answers proves nothing either way. Same call shape and
                // cadence as `awaitWiFiClientJoined`'s pinger, which is the
                // stretch of a real transfer this probe stands in for.
                let pong = try? await request(
                    .wifiKeepalive,
                    timeout: commandBound(remaining: deadline - clock.now,
                                          cadence: settings.pingInterval)
                ) {
                    $0 == .pong
                }
                pingsSent += 1
                if pong == .pong { pingsAnswered += 1 }
                lastPing = clock.now
                record(.pinged(elapsed: clock.now - start, answered: pong == .pong))
            }

            // Wakes immediately on cancellation, which the loop head then reads —
            // so an interrupted run neither spins nor waits out a poll interval.
            try? await Task.sleep(for: settings.pollInterval)
        }

        let ended = outcome ?? .interrupted(after: clock.now - start)
        record(.closing(elapsed: clock.now - start, reason: closingReason(ended)))
        let confirmed = await closeAccessPointAfterProbe(aborting: isAbort(ended))
        return AccessPointLifetime(settings: settings, ssid: ssid, stateBeforeStart: stateBefore,
                                   steps: steps, pingsSent: pingsSent,
                                   pingsAnswered: pingsAnswered, closeConfirmed: confirmed,
                                   outcome: ended)
    }

    /// The per-command timeout inside the watch loop.
    ///
    /// Three bounds, each for its own reason: never longer than the 2 s the rest
    /// of this sequence allows a state query; never past the run's own `cap`, or
    /// one silent poll would overshoot it; and never longer than `cadence` — a
    /// device that has not answered by the time the next frame of the same kind is
    /// due is silent *for this poll*, and the next one asks again. The floor keeps
    /// a healthy device from being timed out on a short last iteration.
    ///
    /// At the real cadences (`APP&WIFIS` every 1 s, `APP&WPING` every 10 s) the
    /// `cadence` term never binds and this is exactly the 2 s used elsewhere; at a
    /// test's millisecond cadence it lands on the floor, which is what keeps the
    /// suite both hermetic and quick.
    private func commandBound(remaining: Duration, cadence: Duration) -> Duration {
        max(min(.seconds(2), remaining, cadence), .milliseconds(50))
    }

    private func closingReason(_ outcome: AccessPointLifetime.Outcome) -> String {
        switch outcome {
        case .accessPointClosed:
            return "the device reported its access point off"
        case .stillUpAtCap:
            return "cap reached with the access point still up"
        case .interrupted:
            return "interrupted"
        case .linkLost:
            return "the BLE session is no longer authenticated"
        }
    }

    /// A run that ended on its own terms closes like a completed transfer; one
    /// that was cut short closes like an aborted one (`APP&SHUT` first), which is
    /// the shape the transfer code established for exits it does not control.
    private func isAbort(_ outcome: AccessPointLifetime.Outcome) -> Bool {
        switch outcome {
        case .accessPointClosed, .stillUpAtCap: return false
        case .interrupted, .linkLost:           return true
        }
    }

    /// Closes the access point and asks the device to confirm it went off.
    ///
    /// Runs on **every** exit, an interrupted one included, which is why the
    /// frames go out from a fresh unstructured task: `Task.init` does not inherit
    /// cancellation, and this method's caller may already be cancelled. The
    /// package's own `BLETransport.send` happens not to check for cancellation,
    /// but `PocketTransport` is public and a consumer's transport is free to fail
    /// a send in that state — which would leave the access point broadcasting
    /// into the BLE fallback, the one outcome this must not have.
    ///
    /// Best effort throughout: it also runs where the link may already be gone,
    /// and a lost error matters less than an access point left up.
    private func closeAccessPointAfterProbe(aborting: Bool) async -> Bool? {
        await Task<Bool?, Never> {
            if aborting { try? await self.send(.wifiShutdown) }
            try? await self.send(.wifiClose)
            guard self.isAuthenticated else { return nil }
            let response = try? await self.request(.wifiStatus, timeout: .seconds(2)) {
                if case .wifiState = $0 { true } else { false }
            }
            guard case .wifiState(let state)? = response else { return nil }
            return state == .off
        }.value
    }
}
