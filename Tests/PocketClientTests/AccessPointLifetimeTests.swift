// pocket-client/Tests/PocketClientTests/AccessPointLifetimeTests.swift
//
// The access-point lifetime probe — the instrument that measures whether
// `APP&WPING` extends the recorder's Wi-Fi access point.
//
// An experiment cannot be unit-tested against the truth it is trying to find, so
// what is pinned here is the opposite: given a device whose behaviour is KNOWN,
// does the probe report the right finding? Both readings therefore get a fake
// device of their own —
//
//  - `.closesAfterPolls(n)`: the access point goes off on the nth poll whatever
//    the client sends. This is the reading where `APP&WPING` does not extend it.
//  - `.closesAfterQuietPolls(n)`: the same, except an `APP&WPING` resets the
//    count. This is the reading where it does.
//
// — and the probe is run against each of them twice, silent and pinging. The four
// verdicts that come back are the four the operator will read off hardware, so
// this is where they are held to what they claim.
//
// Plus the guarantee that holds whichever way the experiment falls, and the one
// that matters most on a device whose radio is shared: every exit closes the
// access point, an interrupted run included.
import Foundation
import Testing
@testable import PocketClient

/// A fake recorder that models the one thing the experiment is about: an access
/// point with a lifetime.
///
/// It answers the whole capture-verified preamble, brings its access point up on
/// `APP&WIFIO`, reports it through `APP&WIFIS`, and takes it down again on a
/// scripted schedule — counted in polls rather than wall-clock time, so a slow
/// machine cannot change what a test measures.
final class ScriptedAccessPoint: @unchecked Sendable {
    /// What the fake device does with its access point — one case per reading of
    /// the open question.
    enum Behaviour: Sendable {
        /// The access point goes off on the nth answered poll, whatever the client
        /// sends. `APP&WPING` does not extend it.
        case closesAfterPolls(Int)
        /// The same, except every `APP&WPING` resets the count: the keepalive DOES
        /// extend the access point.
        case closesAfterQuietPolls(Int)
        /// The access point never goes off on its own.
        case staysUp
    }

    /// The device the transcripts in this repository use. Both values are
    /// placeholders of the right shape and neither is a live credential.
    static let ssid = "PKT01_EXAMPLE"
    static let reportedPassphrase = "ExampleK"

    private let behaviour: Behaviour
    /// Poll indices (1-based, counted from the access point coming up) the device
    /// simply does not answer — silence has to be recorded, not skipped.
    private let silentPolls: Set<Int>
    private let lock = NSLock()
    private var up = false
    private var pollsSinceReset = 0
    private var pollsWhileUp = 0
    private var pings = 0
    private var starts = 0
    private var closes = 0

    init(_ behaviour: Behaviour, silentPolls: Set<Int> = []) {
        self.behaviour = behaviour
        self.silentPolls = silentPolls
    }

    var isUp: Bool { lock.lock(); defer { lock.unlock() }; return up }
    var pingsReceived: Int { lock.lock(); defer { lock.unlock() }; return pings }
    var accessPointStarts: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var closeFramesReceived: Int { lock.lock(); defer { lock.unlock() }; return closes }

    /// Scripts the fixed replies and drives `APP&WIFIS` from the access point's
    /// own state, which is what makes this a device rather than a transcript: the
    /// answer depends on what the client has done so far.
    func install(on transport: FakeTransport) {
        transport.script["APP&SK&K"] = ["MCU&SK&OK"]
        transport.script["APP&SHUT"] = []   // no reply on an idle device (live-probe verified)
        transport.script["APP&WIFI"] = ["MCU&WIFI&\(Self.ssid)&\(Self.reportedPassphrase)"]
        transport.script["APP&WIFIO"] = ["MCU&WIFIO"]
        transport.script["APP&WPING"] = ["MCU&WPING"]
        transport.script["APP&WIFIC"] = ["MCU&WIFIC"]
        transport.onSend = { [self] wire, transport in
            switch wire {
            case "APP&WIFIO":
                startAccessPoint()
            case "APP&WIFIC":
                closeAccessPoint()
            case "APP&WPING":
                recordPing()
            case "APP&WIFIS":
                if let state = answerPoll() {
                    transport.emitResponse("MCU&WIFIS&\(state.rawValue)")
                }
            default:
                break
            }
        }
    }

    private func startAccessPoint() {
        lock.lock()
        up = true
        pollsSinceReset = 0
        pollsWhileUp = 0
        starts += 1
        lock.unlock()
    }

    private func closeAccessPoint() {
        lock.lock(); up = false; closes += 1; lock.unlock()
    }

    private func recordPing() {
        lock.lock()
        pings += 1
        if case .closesAfterQuietPolls = behaviour { pollsSinceReset = 0 }
        lock.unlock()
    }

    /// `nil` means the device stays silent for this poll.
    private func answerPoll() -> WiFiState? {
        lock.lock(); defer { lock.unlock() }
        // A poll while the access point is down does not advance the schedule:
        // the preamble's state query and the confirming poll after `APP&WIFIC`
        // both land here.
        guard up else { return .off }
        pollsWhileUp += 1
        pollsSinceReset += 1
        if silentPolls.contains(pollsWhileUp) { return nil }
        switch behaviour {
        case .staysUp:
            return .accessPointUp
        case .closesAfterPolls(let limit), .closesAfterQuietPolls(let limit):
            guard pollsSinceReset >= limit else { return .accessPointUp }
            up = false   // the device took its own access point down
            return .off
        }
    }
}

/// One probe run against one fake device, with everything a test needs to check
/// afterwards: the finding, the frames, and the device's own view of its AP.
struct AccessPointProbeRun {
    let result: AccessPointLifetime
    let transport: FakeTransport
    let accessPoint: ScriptedAccessPoint
}

/// Cadences in milliseconds so the suite stays hermetic and quick. The ratios are
/// the ones that matter and they mirror the real defaults: polls several times
/// per ping interval, and a cap comfortably longer than the schedule under test.
func runAccessPointProbe(_ behaviour: ScriptedAccessPoint.Behaviour,
                         keepalive: Bool,
                         cap: Duration = .seconds(2),
                         pollInterval: Duration = .milliseconds(5),
                         pingInterval: Duration = .milliseconds(10),
                         silentPolls: Set<Int> = []) async throws -> AccessPointProbeRun {
    let transport = FakeTransport()
    let accessPoint = ScriptedAccessPoint(behaviour, silentPolls: silentPolls)
    accessPoint.install(on: transport)
    let session = PocketSession(transport: transport, sessionKey: "K")
    try await session.start()
    let result = try await session.probeAccessPointLifetime(
        AccessPointLifetimeSettings(keepalive: keepalive, pollInterval: pollInterval,
                                    pingInterval: pingInterval, cap: cap))
    await session.stop()
    return AccessPointProbeRun(result: result, transport: transport, accessPoint: accessPoint)
}

// MARK: - The sequence it performs, and the one it must not

/// Steps 1–4 of Wi-Fi Quick Transfer, in the capture's order, then polls — and
/// then the close. What it brings up has to be the same access point a transfer
/// brings up, or the measurement is of something else.
@Test func accessPointProbeSendsTheCaptureVerifiedPreambleThenPolls() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false)

    #expect(Array(run.transport.sent.prefix(5)) ==
            ["APP&SK&K", "APP&SHUT", "APP&WIFIS", "APP&WIFI", "APP&WIFIO"])
    #expect(run.transport.sent.contains("APP&WIFIC"))
    #expect(run.accessPoint.accessPointStarts == 1)
    #expect(run.result.ssid == ScriptedAccessPoint.ssid)
}

/// The probe never joins, so it can never send a provisioning frame, a selection,
/// or anything else outside the five verbs it needs. Pinned as a set: a frame
/// added here later has to be a deliberate edit to this list.
@Test func accessPointProbeSendsNothingButItsFiveVerbs() async throws {
    // Long enough for a keepalive to be due, so the set covers APP&WPING too.
    let run = try await runAccessPointProbe(.closesAfterPolls(8), keepalive: true)

    #expect(Set(run.transport.sent).subtracting(["APP&SK&K"]) ==
            ["APP&SHUT", "APP&WIFIS", "APP&WIFI", "APP&WIFIO", "APP&WPING", "APP&WIFIC"])
    // `APP&WIFI` stays argument-less: the forbidden provisioning command
    // `APP&WIFI&CH&<ssid>&<psk>` shares its prefix, and nothing here may make it
    // reachable.
    #expect(!run.transport.sent.contains { $0.hasPrefix("APP&WIFI&") })
    // No join, so no selection and no reroute either.
    #expect(!run.transport.sent.contains { $0.hasPrefix("APP&U") })
}

/// A silent run sends no keepalive at all — otherwise the two halves of the
/// experiment would be the same run twice.
@Test func silentAccessPointProbeSendsNoKeepalive() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false)

    #expect(!run.transport.sent.contains("APP&WPING"))
    #expect(run.accessPoint.pingsReceived == 0)
    #expect(run.result.pingsSent == 0)
}

// MARK: - The experiment: the same device, run both ways

/// **The experiment itself.** On a device where `APP&WPING` extends the access
/// point, the silent run loses it and the pinging run keeps it to the cap; on a
/// device that ignores the keepalive, both runs lose it. Those two pairs are the
/// only evidence that can distinguish the readings, and the verdicts must say so
/// by name.
@Test func probeDistinguishesAKeepaliveThatExtendsTheApFromOneThatDoesNot() async throws {
    // Reading A — the device's access point survives as long as it is pinged.
    let silentOnA = try await runAccessPointProbe(.closesAfterQuietPolls(4), keepalive: false)
    let pingingOnA = try await runAccessPointProbe(.closesAfterQuietPolls(4), keepalive: true,
                                                  cap: .milliseconds(250))

    guard case .closedWithoutKeepalive(let baselineA) = silentOnA.result.verdict else {
        Issue.record("silent run must report the unassisted baseline, got \(silentOnA.result.verdict)")
        return
    }
    #expect(baselineA > .zero)
    guard case .survivedCapWithKeepalive(_, let sentA, let answeredA)
        = pingingOnA.result.verdict else {
        Issue.record("pinging run must reach the cap, got \(pingingOnA.result.verdict)")
        return
    }
    #expect(sentA >= 1)
    #expect(answeredA == sentA)   // the fake answers every APP&WPING
    #expect(pingingOnA.result.lifetime == nil)   // a cap is a lower bound, not a lifetime

    // Reading B — the access point goes off on schedule however hard it is pinged.
    let silentOnB = try await runAccessPointProbe(.closesAfterPolls(8), keepalive: false)
    let pingingOnB = try await runAccessPointProbe(.closesAfterPolls(8), keepalive: true)

    guard case .closedWithoutKeepalive = silentOnB.result.verdict else {
        Issue.record("silent run must report the unassisted baseline, got \(silentOnB.result.verdict)")
        return
    }
    guard case .closedDespiteKeepalive(let lifetimeB, let sentB, let answeredB)
        = pingingOnB.result.verdict else {
        Issue.record("expected the negative finding, got \(pingingOnB.result.verdict)")
        return
    }
    #expect(sentB >= 1)
    #expect(answeredB == sentB)
    #expect(lifetimeB == pingingOnB.result.lifetime)
    // The negative finding is the consequential one, so the prose has to name the
    // consequence rather than only the number.
    #expect(pingingOnB.result.verdictText.contains("does not extend the access point"))
    #expect(pingingOnB.result.verdictText.contains("WITHOUT the keepalive"))
}

/// A single run is half an experiment, and every verdict has to say which half is
/// missing — otherwise the first transcript to reach the protocol doc gets read as
/// an answer.
@Test func everyVerdictNamesTheRunThatIsStillMissing() async throws {
    let silent = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false)
    let pinging = try await runAccessPointProbe(.closesAfterPolls(8), keepalive: true)

    #expect(silent.result.verdictText.contains("WITH the keepalive"))
    #expect(pinging.result.verdictText.contains("WITHOUT the keepalive"))
    #expect(silent.result.verdictText.contains("half the experiment"))
}

/// An access point that outlives the cap with no keepalive measures nothing about
/// the keepalive — and it moves the suspicion somewhere specific, which the
/// verdict has to say.
@Test func anAccessPointThatOutlivesTheCapUnaidedMeasuresNothing() async throws {
    let run = try await runAccessPointProbe(.staysUp, keepalive: false, cap: .milliseconds(200))

    guard case .survivedCapWithoutKeepalive(let cap) = run.result.verdict else {
        Issue.record("expected the cap-too-short finding, got \(run.result.verdict)")
        return
    }
    #expect(cap >= .milliseconds(200))
    #expect(run.result.lifetime == nil)
    if case .stillUpAtCap = run.result.outcome {} else {
        Issue.record("expected .stillUpAtCap, got \(run.result.outcome)")
    }
    // Where to look instead, named: the listener and this client's socket code.
    #expect(run.result.verdictText.contains("8475"))
    #expect(run.result.verdictText.contains("raise the cap"))
}

/// Asking for a keepalive is not the same as sending one. If the access point dies
/// before the first `APP&WPING` is due, the run is a second silent baseline and
/// must refuse to be read as a test of the keepalive.
@Test func aKeepaliveRunThatNeverPingedIsReportedAsInconclusive() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(2), keepalive: true,
                                            pingInterval: .seconds(30))

    #expect(run.result.pingsSent == 0)
    guard case .inconclusive(let reason) = run.result.verdict else {
        Issue.record("a run that sent no ping cannot claim anything, got \(run.result.verdict)")
        return
    }
    #expect(reason.contains("no APP&WPING ever went out"))
    // The lifetime WAS measured; it is the keepalive claim that is unavailable.
    #expect(run.result.lifetime != nil)
}

/// A keepalive nothing answers has not been shown to reach the device, and a
/// conclusion drawn from one would be worthless. The verdict has to carry that
/// caveat rather than counting the sends and calling it evidence.
@Test func anUnansweredKeepaliveIsCalledOutInTheVerdict() async throws {
    let transport = FakeTransport()
    let accessPoint = ScriptedAccessPoint(.closesAfterPolls(8))
    accessPoint.install(on: transport)
    transport.script["APP&WPING"] = []   // the frame goes out; nothing comes back
    let session = PocketSession(transport: transport, sessionKey: "K")
    try await session.start()

    let result = try await session.probeAccessPointLifetime(
        AccessPointLifetimeSettings(keepalive: true, pollInterval: .milliseconds(5),
                                    pingInterval: .milliseconds(10), cap: .seconds(2)))

    #expect(result.pingsSent >= 1)
    #expect(result.pingsAnswered == 0)
    #expect(result.verdictText.contains("not one MCU&WPING came back"))
    await session.stop()
}

// MARK: - The timeline is the evidence

/// Absolute elapsed times from the `MCU&WIFIO` ack, every state transition
/// flagged, and the cadence that produced them — the three things that make the
/// output quotable as evidence.
@Test func accessPointProbeRecordsEveryStateWithItsElapsedTime() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false)
    let result = run.result

    #expect(result.observations.count == 3)
    #expect(result.observations.map(\.state) == [.accessPointUp, .accessPointUp, .off])
    // `3` then `0`: the repeat in the middle is duration, not a transition.
    #expect(result.transitions.map(\.state) == [.accessPointUp, .off])
    // Elapsed times are monotonic and measured from t=0, not per-poll deltas.
    let elapsed = result.observations.map(\.elapsed)
    #expect(elapsed == elapsed.sorted())
    #expect(elapsed.first! > .zero)
    #expect(result.accessPointUpAfter == elapsed.first)
    #expect(result.lifetime == elapsed.last)
    #expect(result.pollsAnswered == 3)
    #expect(result.pollsAttempted == 3)

    // The cadence is in the transcript, because a lifetime quoted without the
    // cadence that produced it is not reproducible.
    #expect(result.transcript.contains("poll cadence"))
    #expect(result.transcript.contains("keepalive OFF"))
    #expect(result.transcript.contains("MCU&WIFIS&0"))
    #expect(result.transcript.contains("timeline"))
}

/// A device that stops answering `APP&WIFIS` is a finding in itself, and one that
/// must never be confused with a device that answered `0`.
@Test func aPollTheDeviceDoesNotAnswerIsRecordedAsSilenceNotAsOff() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false,
                                           silentPolls: [2])

    #expect(run.result.observations.count == 3)
    #expect(run.result.observations[1].state == nil)
    #expect(run.result.pollsAnswered == 2)
    #expect(run.result.pollsAttempted == 3)
    // Still a completed measurement: the access point did report itself off.
    #expect(run.result.lifetime != nil)
    #expect(run.result.timeline.contains("NO ANSWER to APP&WIFIS"))
}

/// The AP password arrives in the same frame as the SSID and is discarded unread.
/// A transcript is meant to be pasted into a public document, so it must not be
/// able to carry a live credential — this probe never needs one, because nothing
/// joins.
@Test func theTranscriptCarriesTheSsidAndNeverThePassphrase() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false)

    #expect(run.result.transcript.contains(ScriptedAccessPoint.ssid))
    #expect(!run.result.transcript.contains(ScriptedAccessPoint.reportedPassphrase))
    #expect(run.result.transcript.contains("discarded unread"))
}

// MARK: - The access point is closed on every exit

/// Interruption is the exit that matters most: an operator will Ctrl-C a
/// three-minute watch, and a still-broadcasting access point competes with BLE
/// for the same 2.4 GHz radio. So a cancelled run closes the access point,
/// confirms it went off, and comes back with the partial measurement rather than
/// throwing it away.
@Test func interruptedProbeStillClosesTheAccessPoint() async throws {
    let transport = FakeTransport()
    let accessPoint = ScriptedAccessPoint(.staysUp)
    accessPoint.install(on: transport)
    let session = PocketSession(transport: transport, sessionKey: "K")
    try await session.start()

    let watching = AsyncGate()
    let probe = Task {
        try await session.probeAccessPointLifetime(
            AccessPointLifetimeSettings(keepalive: false, pollInterval: .milliseconds(5),
                                        pingInterval: .milliseconds(10), cap: .seconds(30))
        ) { step in
            if case .observed = step { watching.open() }
        }
    }
    await watching.wait()   // the access point is up and being polled
    probe.cancel()
    let result = try await probe.value

    // The frames that matter, and the fake device agreeing it heard them.
    #expect(transport.sent.contains("APP&WIFIC"))
    #expect(accessPoint.closeFramesReceived >= 1)
    #expect(!accessPoint.isUp)
    // Closed like an aborted transfer: APP&SHUT first, the shape the transfer
    // code established for exits it does not control.
    #expect(transport.sent.filter { $0 == "APP&SHUT" }.count == 2)
    // And it proved the close landed rather than assuming it.
    #expect(result.closeConfirmed == true)

    if case .interrupted = result.outcome {} else {
        Issue.record("expected .interrupted, got \(result.outcome)")
    }
    guard case .inconclusive(let reason) = result.verdict else {
        Issue.record("an interrupted run cannot claim a lifetime, got \(result.verdict)")
        return
    }
    #expect(reason.contains("interrupted"))
    #expect(result.lifetime == nil)
    // The partial timeline survives: a cancelled measurement's data IS the
    // measurement.
    #expect(!result.observations.isEmpty)
    await session.stop()
}

/// A normal ending closes the access point too, and says whether the device
/// confirmed it — a probe that cannot prove it closed the AP has to admit it.
@Test func completedProbeClosesTheAccessPointAndConfirmsIt() async throws {
    let run = try await runAccessPointProbe(.closesAfterPolls(3), keepalive: false)

    #expect(run.transport.sent.contains("APP&WIFIC"))
    #expect(!run.accessPoint.isUp)
    #expect(run.result.closeConfirmed == true)
    #expect(run.result.measurements.contains("the device then reported MCU&WIFIS&0"))
    // Not the aborting shape: exactly the one APP&SHUT the preamble sends.
    #expect(run.transport.sent.filter { $0 == "APP&SHUT" }.count == 1)
}

/// The access point may have started despite a lost `MCU&WIFIO`, so the failure
/// path closes it as well — the same reasoning `openWiFiSession` applies.
@Test func aProbeThatCannotStartTheAccessPointStillClosesIt() async throws {
    let transport = FakeTransport()
    let accessPoint = ScriptedAccessPoint(.staysUp)
    accessPoint.install(on: transport)
    transport.script["APP&WIFIO"] = ["MCU&UNKNOWN"]   // this firmware refuses it
    let session = PocketSession(transport: transport, sessionKey: "K")
    try await session.start()

    await #expect(throws: PocketError.unknownCommand(.wifiAccessPointOn)) {
        _ = try await session.probeAccessPointLifetime(
            AccessPointLifetimeSettings(keepalive: false, pollInterval: .milliseconds(5),
                                        pingInterval: .milliseconds(10), cap: .seconds(2)))
    }

    #expect(transport.sent.contains("APP&WIFIC"))
    await session.stop()
}

// MARK: - It is a transfer, as far as the device's radio is concerned

/// The probe owns the device's access point for its whole run, so it claims the
/// same exclusive slot the downloads and the live stream claim. A Wi-Fi transfer
/// starting underneath it would fight it for exactly that.
@Test func accessPointProbeClaimsTheExclusiveTransferSlot() async throws {
    let transport = FakeTransport()
    ScriptedAccessPoint(.staysUp).install(on: transport)
    let session = PocketSession(transport: transport, sessionKey: "K")
    try await session.start()
    try await session.beginTransfer()   // stand in for a transfer already running

    await #expect(throws: PocketError.busy("transfer already in progress")) {
        _ = try await session.probeAccessPointLifetime()
    }

    #expect(!transport.sent.contains("APP&WIFIO"))   // the radio was never touched
    await session.endTransfer()
    await session.stop()
}

/// Before the handshake there is no session to probe with, and the check happens
/// before `APP&WIFIO` — nothing may bring an access point up unauthenticated.
@Test func accessPointProbeIsRefusedBeforeTheHandshake() async throws {
    let transport = FakeTransport()
    ScriptedAccessPoint(.staysUp).install(on: transport)
    let session = PocketSession(transport: transport, sessionKey: "K")

    await #expect(throws: PocketError.notAuthenticated) {
        _ = try await session.probeAccessPointLifetime()
    }

    #expect(transport.sent.isEmpty)
}

// MARK: - Defaults

/// The defaults are the vendor app's cadence, from the capture: `APP&WIFIS` about
/// once a second and `APP&WPING` every ~10 s — the same figures `WiFiReadiness`
/// uses, so a pinging run reproduces what a real transfer does while it waits for
/// a join instead of some louder cadence that would not generalise.
@Test func accessPointProbeDefaultsMirrorTheCaptureCadence() {
    let settings = AccessPointLifetimeSettings()

    #expect(settings.keepalive == false)   // the honest default: measure the device unaided
    #expect(settings.pollInterval == .seconds(1))
    #expect(settings.pingInterval == WiFiReadiness().pingInterval)
    #expect(settings.cap == .seconds(180))
}
