// pocket-client/Tests/PocketClientTests/BLETransportTests.swift
//
// `BLETransport` driven end to end against a fake radio (Support/FakeBLE.swift).
//
// What these are for. Three of this package's worst defects lived in exactly
// these paths, and every one was found by review or by hardware rather than by
// a test: a `cancelAll` that could not resume a checked continuation (the
// caller hung past its own timeout and the session wedged in `.busy`); a
// per-chunk `Task {}` that reordered bulk bytes; and a mid-connect teardown
// that left a zombie holding the radio's single central slot. The suite below
// is shaped around making each of those reachable in-process:
//
//   * every cancellation test asserts the call RETURNS, bounded, because the
//     failure mode of a lost continuation is a hang, not a wrong answer;
//   * every failure path asserts the half-open link was cancelled, because
//     the zombie is invisible from the caller's side;
//   * a double resume traps inside `withCheckedContinuation` itself, so any
//     test that completes at all has proven single-resume for its path.
import CoreBluetooth
import Testing
@testable import PocketClient

private let isWrite: @Sendable (BLECall) -> Bool = { call in
    if case .write = call { return true }
    return false
}

// MARK: - Connect: the scanned path

@Test func connectResolvesTheLinkAndReportsTheDevice() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket(name: "PKT01_EXAMPLE")
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let device = try await transport.connect(timeout: .seconds(5))

    #expect(device == DiscoveredDevice(name: "PKT01_EXAMPLE", identifier: pocket.identifier))
    #expect(central.log.contains(.beginScan))
    #expect(central.log.contains(.endScan))       // the scan stops the moment it matches
    #expect(central.log.contains(.connect(pocket.identifier)))
    await transport.disconnect()
}

/// Only the name gate decides. A neighbouring advertiser is passed over
/// without stopping the scan, and the Pocket behind it still wins.
@Test func connectIgnoresAdvertisersOutsideTheNamePrefix() async throws {
    let central = FakeCentral()
    let stranger = FakeBLE.pocket(name: "OTHER_DEVICE")
    let pocket = FakeBLE.pocket(name: "PKT01_EXAMPLE")
    central.advertisers = [stranger, pocket]
    let transport = FakeBLE.transport(central)

    let device = try await transport.connect(timeout: .seconds(5))

    #expect(device.identifier == pocket.identifier)
    #expect(!central.log.contains(.connect(stranger.identifier)))
    await transport.disconnect()
}

/// The gate reads the advertised local name when the peripheral has no name
/// yet — but the resolved `DiscoveredDevice` still reports the peripheral's
/// own name, which at that point is empty. Pinned because it is surprising,
/// not because it is ideal.
@Test func theNameGateReadsTheAdvertisementWhileTheDeviceNameIsStillEmpty() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket(name: nil)
    pocket.advertisementData = [CBAdvertisementDataLocalNameKey: "PKT01_EXAMPLE"]
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let device = try await transport.connect(timeout: .seconds(5))

    #expect(device.identifier == pocket.identifier)
    #expect(device.name.isEmpty)
    await transport.disconnect()
}

@Test func connectTimesOutWhenNothingAdvertises() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    await #expect(throws: PocketError.timeout(.auth(""))) {
        _ = try await transport.connect(timeout: .milliseconds(50))
    }
}

/// The BLE-contention defect, as a test. A connect that expires between
/// "found" and "resolved" must not leave the system holding a link: the
/// recorder accepts ONE central at a time, and a zombie half-connect makes
/// every later attempt — including another app's — fail for no visible reason.
@Test func aTimedOutConnectDropsTheHalfOpenLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.connectOutcome = .silent            // the system never completes it
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    await #expect(throws: PocketError.timeout(.auth(""))) {
        _ = try await transport.connect(timeout: .milliseconds(80))
    }
    await central.settle()
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
    #expect(central.log.contains(.endScan))
}

/// A second connect while one is in flight is REFUSED, not queued and not
/// merged — the alternative is two callers racing for one continuation.
@Test func connectRefusesASecondCallWhileOneIsPending() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    let first = Task { try await transport.connect(timeout: .seconds(30)) }
    #expect(await central.log.wait(for: .beginScan))

    await #expect(throws: PocketError.busy("connect already in progress")) {
        _ = try await transport.connect(timeout: .seconds(5))
    }

    // ...and the refusal left the first one intact.
    let pocket = FakeBLE.pocket()
    central.advertise(pocket)
    let result = await outcome(of: first)
    #expect(result?.succeeded == true)
    await transport.disconnect()
}

@Test func connectRefusesOnceTheLinkIsUp() async throws {
    let (transport, _, _) = try await FakeBLE.connected()

    await #expect(throws: PocketError.busy("connect already in progress")) {
        _ = try await transport.connect(timeout: .seconds(5))
    }
    await transport.disconnect()
}

/// Single-use: a spent transport refuses forever rather than half-working.
@Test func connectAfterDisconnectFails() async throws {
    let (transport, _, _) = try await FakeBLE.connected()
    await transport.disconnect()

    await #expect(throws: PocketError.disconnected) {
        _ = try await transport.connect(timeout: .seconds(5))
    }
}

@Test func aFailedSystemConnectFailsTheConnect() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.connectOutcome = .fail(RadioError("peer removed pairing information"))
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let result = await outcome(of: Task { try await transport.connect(timeout: .seconds(5)) })
    #expect(result?.thrownError is PocketError)
    if case .transferFailed(let message)? = result?.thrownError as? PocketError {
        #expect(message.contains("peer removed pairing information"))
    } else {
        Issue.record("expected transferFailed, got \(String(describing: result?.thrownError))")
    }
}

@Test func serviceDiscoveryFailureFailsTheConnectAndDropsTheLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.serviceDiscovery = .fail(RadioError("att timeout"))
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let result = await outcome(of: Task { try await transport.connect(timeout: .seconds(5)) })
    if case .transferFailed(let message)? = result?.thrownError as? PocketError {
        #expect(message.hasPrefix("service discovery failed:"))
    } else {
        Issue.record("expected transferFailed, got \(String(describing: result?.thrownError))")
    }
    await central.settle()
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
}

@Test func characteristicDiscoveryFailureFailsTheConnectAndDropsTheLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.characteristicDiscovery = .fail(RadioError("att timeout"))
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let result = await outcome(of: Task { try await transport.connect(timeout: .seconds(5)) })
    if case .transferFailed(let message)? = result?.thrownError as? PocketError {
        #expect(message.hasPrefix("characteristic discovery failed:"))
    } else {
        Issue.record("expected transferFailed, got \(String(describing: result?.thrownError))")
    }
    await central.settle()
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
}

// MARK: - Connect: the radio

/// A radio that is not up yet is waited for, not failed — the whole point of
/// the powered-on stage. Nothing is scanned until it arrives.
@Test func connectWaitsForTheRadioToPowerOn() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(30)) }
    await central.settle()
    #expect(!central.log.contains(.beginScan))

    central.power(.poweredOn)
    let result = await outcome(of: connect)
    #expect(result?.succeeded == true)
    await transport.disconnect()
}

@Test func aRadioLostDuringTheScanFailsTheConnect() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(30)) }
    #expect(await central.log.wait(for: .beginScan))
    central.power(.poweredOff)

    let result = await outcome(of: connect)
    #expect(result?.thrownError as? PocketError
            == .transferFailed("bluetooth powered off during scan"))
}

/// Terminal radio states are terminal: no amount of waiting produces a radio,
/// so the transport closes rather than parking until the deadline.
@Test func anUnusableRadioClosesTheTransport() async throws {
    let central = FakeCentral(state: .unknown)
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(30)) }
    central.power(.unsupported)

    let result = await outcome(of: connect)
    if case .transferFailed(let message)? = result?.thrownError as? PocketError {
        #expect(message.hasPrefix("bluetooth unavailable"))
    } else {
        Issue.record("expected transferFailed, got \(String(describing: result?.thrownError))")
    }
    await #expect(throws: PocketError.transferFailed("bluetooth unavailable (state 2)")) {
        try await transport.send(Data("APP&STA".utf8))
    }
}

/// A radio that goes away under an established link kills it SILENTLY —
/// CoreBluetooth sends no disconnect callback — so this is the only place the
/// streams can be finished, and the session's consume loops depend on it.
@Test func losingTheRadioUnderALiveLinkFinishesTheStreams() async throws {
    let (transport, central, _) = try await FakeBLE.connected()
    let drain = Task { () throws -> Int in
        var count = 0
        for await _ in transport.responseStream() { count += 1 }
        return count
    }

    central.power(.poweredOff)

    #expect(await outcome(of: drain)?.succeeded == true)
    await #expect(throws: PocketError.disconnected) { try await transport.send(Data()) }
}

// MARK: - Connect: the targeted path

@Test func targetedConnectResolvesByIdentifierAndNeverScans() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    central.known = [pocket]
    let transport = FakeBLE.transport(central)

    let device = try await transport.connect(to: pocket.identifier, timeout: .seconds(5))

    #expect(device.identifier == pocket.identifier)
    #expect(central.log.contains(.retrieve(pocket.identifier)))
    #expect(!central.log.contains(.beginScan))
    await transport.disconnect()
}

@Test func anIdentifierTheSystemDoesNotKnowFailsWithDeviceNotFound() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)
    let stranger = UUID()

    await #expect(throws: PocketError.deviceNotFound(stranger)) {
        _ = try await transport.connect(to: stranger, timeout: .seconds(5))
    }
}

/// The whole point of choosing a device: an unknown identifier fails even
/// while a perfectly good Pocket is advertising an arm's length away. No
/// scan, no fallback, no "helpfully" connecting to somebody else's recorder.
@Test func targetedConnectNeverFallsBackToAnotherPocket() async throws {
    let central = FakeCentral()
    let neighbour = FakeBLE.pocket(name: "PKT01_NEIGHBOUR")
    central.advertisers = [neighbour]        // would be found instantly by a scan
    let transport = FakeBLE.transport(central)
    let stranger = UUID()

    await #expect(throws: PocketError.deviceNotFound(stranger)) {
        _ = try await transport.connect(to: stranger, timeout: .seconds(5))
    }
    await central.settle()
    #expect(!central.log.contains(.beginScan))
    #expect(!central.log.contains(.connect(neighbour.identifier)))
}

/// Known but unreachable (asleep, out of range) is the timeout case, not the
/// not-found case — and it drops its half-open link like any other failure.
@Test func aKnownButUnreachableDeviceTimesOutAndDropsItsLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.connectOutcome = .silent
    central.known = [pocket]
    let transport = FakeBLE.transport(central)

    await #expect(throws: PocketError.timeout(.auth(""))) {
        _ = try await transport.connect(to: pocket.identifier, timeout: .milliseconds(80))
    }
    await central.settle()
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
}

// MARK: - Teardown

@Test func disconnectMidConnectFailsThePendingConnect() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(30)) }
    #expect(await central.log.wait(for: .beginScan))
    await transport.disconnect()

    #expect(await outcome(of: connect)?.thrownError as? PocketError == .disconnected)
}

@Test func disconnectMidConnectDropsTheHalfOpenLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.connectOutcome = .silent
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(30)) }
    #expect(await central.log.wait(for: .connect(pocket.identifier)))
    await transport.disconnect()

    #expect(await outcome(of: connect)?.thrownError as? PocketError == .disconnected)
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
}

@Test func disconnectMidTransferFailsThePendingWrite() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .silent }

    let send = Task { try await transport.send(Data("APP&STA".utf8)) }
    #expect(await central.log.wait(for: isWrite))
    await transport.disconnect()

    #expect(await outcome(of: send)?.thrownError as? PocketError == .disconnected)
}

@Test func disconnectFinishesBothStreams() async throws {
    let (transport, _, _) = try await FakeBLE.connected()
    let responses = Task { () throws -> Int in
        var count = 0
        for await _ in transport.responseStream() { count += 1 }
        return count
    }
    let bulk = Task { () throws -> Int in
        var count = 0
        for await _ in transport.bulkStream() { count += 1 }
        return count
    }

    await transport.disconnect()

    #expect(await outcome(of: responses)?.succeeded == true)
    #expect(await outcome(of: bulk)?.succeeded == true)
}

/// Link loss is a permanent teardown, not a hiccup: the streams end so the
/// session's consume loops can, and everything pending fails.
@Test func linkLossClosesTheTransport() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .silent }
    let send = Task { try await transport.send(Data("APP&STA".utf8)) }
    #expect(await central.log.wait(for: isWrite))

    pocket.dropLink()

    #expect(await outcome(of: send)?.thrownError as? PocketError == .disconnected)
    await #expect(throws: PocketError.disconnected) { try await transport.send(Data()) }
}

/// `disconnect()` cancels the link, and CoreBluetooth answers that with a
/// disconnect callback — a second trip through the teardown funnel. It must
/// be idempotent: a continuation resumed twice traps, so this test completing
/// at all is the assertion.
@Test func teardownSurvivesTheDisconnectCallbackItProvokes() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.disconnectOnCancel = .always }

    await transport.disconnect()
    await transport.disconnect()
    await central.settle()

    await #expect(throws: PocketError.disconnected) { try await transport.send(Data()) }
}

@Test func sendBeforeTheLinkIsUpFails() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    await #expect(throws: PocketError.disconnected) { try await transport.send(Data("APP&STA".utf8)) }
}

// MARK: - Cancellation
//
// The deadlock defect: `cancelAll()` alone never resumes a checked
// continuation, so a cancelled caller hung past its own timeout and the
// session wedged in `.busy`. Every test here asserts the call RETURNS —
// `outcome(of:within:)` yields nil rather than hanging the suite, so the
// failure is a report, not a stall.

@Test func cancellingAConnectWaitingForTheRadioReturnsPromptly() async throws {
    let central = FakeCentral(state: .unknown)
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(600)) }
    await central.settle()
    connect.cancel()

    // The error flavor depends on whether the cancellation lands before or
    // after the powered-on wait parks (poisoned attempt vs resumed
    // continuation); that it lands AT ALL is the property under test.
    let result = await outcome(of: connect)
    #expect(result != nil, "a cancelled connect never returned — a continuation is parked")
    #expect(result?.thrownError != nil)
}

@Test func cancellingAConnectDuringTheScanReturnsPromptly() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(600)) }
    #expect(await central.log.wait(for: .beginScan))
    connect.cancel()

    let result = await outcome(of: connect)
    #expect(result != nil, "a cancelled connect never returned — a continuation is parked")
    #expect(result?.thrownError is CancellationError)
}

@Test func cancellingDuringTheSystemConnectReturnsPromptlyAndDropsTheLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.connectOutcome = .silent
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(600)) }
    #expect(await central.log.wait(for: .connect(pocket.identifier)))
    connect.cancel()

    let result = await outcome(of: connect)
    #expect(result != nil, "a cancelled connect never returned — a continuation is parked")
    #expect(result?.thrownError is CancellationError)
    await central.settle()
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
}

@Test func cancellingDuringDiscoveryReturnsPromptlyAndDropsTheLink() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.serviceDiscovery = .silent
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    let connect = Task { try await transport.connect(timeout: .seconds(600)) }
    #expect(await central.log.wait(for: { $0.discoveryUUIDs != nil }))
    connect.cancel()

    let result = await outcome(of: connect)
    #expect(result != nil, "a cancelled connect never returned — a continuation is parked")
    #expect(result?.thrownError is CancellationError)
    await central.settle()
    #expect(central.log.contains(.cancelConnection(pocket.identifier)))
}

/// `send` is the one suspension point that is deliberately NOT
/// cancellation-responsive. There is no per-write timer — a dead link always
/// ends in a teardown path — and resuming a write continuation from a
/// cancellation handler AS WELL AS from the ack callback is precisely how a
/// continuation gets resumed twice. So a cancelled sender stays parked until
/// the ack or the teardown resolves it. Pinned here so that nobody "fixes" it
/// into the trap.
@Test func cancellingASendLeavesItParkedForTheLinkToResolve() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .silent }

    let send = Task { try await transport.send(Data("APP&STA".utf8)) }
    #expect(await central.log.wait(for: isWrite))
    send.cancel()
    #expect(await outcome(of: send, within: .milliseconds(150)) == nil)

    await transport.disconnect()
    #expect(await outcome(of: send)?.thrownError as? PocketError == .disconnected)
}

/// The other half of the deadlock defect: after the cancelled caller hung, the
/// transport stayed wedged. A cancelled connect must leave nothing parked and
/// nothing armed — the next connect behaves as if the first never happened.
@Test func aCancelledConnectLeavesTheTransportUsable() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    let cancelled = Task { try await transport.connect(timeout: .seconds(600)) }
    #expect(await central.log.wait(for: .beginScan))
    cancelled.cancel()
    #expect(await outcome(of: cancelled) != nil)

    let pocket = FakeBLE.pocket()
    central.advertise(pocket)
    let device = try await transport.connect(timeout: .seconds(5))
    #expect(device.identifier == pocket.identifier)
    await transport.disconnect()
}

// MARK: - Attempt tokens

/// The identity guard. A deadline belonging to a RESOLVED attempt can still
/// land after the next attempt armed — its task is cancelled, not stopped, and
/// cancellation resumes it on its own schedule. It must recognise that the
/// pending stage is not its own and poison rather than resume it; the newer
/// attempt has to survive untouched.
@Test func aStaleAttemptCannotFailANewerOne() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central)

    // Attempt 1: nothing advertises, so it expires and surrenders the token.
    await #expect(throws: PocketError.timeout(.auth(""))) {
        _ = try await transport.connect(timeout: .milliseconds(50))
    }

    // Attempt 2 arms and parks mid-connect.
    let pocket = FakeBLE.pocket()
    pocket.connectOutcome = .silent
    central.advertise(pocket)
    let second = Task { try await transport.connect(timeout: .seconds(600)) }
    #expect(await central.log.wait(for: .connect(pocket.identifier)))

    // Attempt 1's deadline task finally lands.
    transport.failPendingConnect(attempt: 1, with: CancellationError())
    await central.settle()

    pocket.completeConnect()
    let result = await outcome(of: second)
    #expect(result?.succeeded == true, "a stale attempt killed the live one")
    await transport.disconnect()
}

/// The same interleaving, unforced. Every connect leaves a cancelled deadline
/// task behind that calls into the transport on its own schedule; a retry
/// issued immediately afterwards races it. Repeated because a concurrency
/// property that held once held once.
@Test func aRetryAfterAFailedConnectIsNeverKilledByItsPredecessor() async throws {
    for _ in 0..<25 {
        let central = FakeCentral()
        let doomed = FakeBLE.pocket()
        doomed.connectOutcome = .fail(RadioError("connection failed"))
        central.advertisers = [doomed]
        let transport = FakeBLE.transport(central)

        let first = await outcome(of: Task { try await transport.connect(timeout: .seconds(30)) })
        #expect(first?.thrownError != nil)

        await central.settle { doomed.connectOutcome = .succeed }
        let retry = await outcome(of: Task { try await transport.connect(timeout: .seconds(30)) })
        #expect(retry?.succeeded == true, "a retry was killed by its predecessor's deadline")
        await transport.disconnect()
    }
}

// MARK: - Notification setup

@Test func bothNotifyChannelsAreArmedDuringConnect() async throws {
    let (transport, central, _) = try await FakeBLE.connected()
    await central.settle()

    #expect(central.log.contains(.setNotify(true, PocketGATT.response)))
    #expect(central.log.contains(.setNotify(true, PocketGATT.bulk)))
    // The command channel is written to, never subscribed.
    #expect(!central.log.contains(.setNotify(true, PocketGATT.command)))
    await transport.disconnect()
}

@Test func notifyStateSummaryReportsWhatTheDeviceAnswered() async throws {
    let (transport, central, _) = try await FakeBLE.connected()
    await central.settle()

    #expect(await transport.notifyStateSummary() == "response: enabled, bulk: enabled")
    await transport.disconnect()
}

/// The diagnostic that distinguishes "notify never armed" from "device
/// silent" — the difference between a firmware problem and a client bug.
@Test func aFailedNotifyEnableIsReportedAsSuch() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.notifyOutcome = .fail(RadioError("cccd write rejected"))
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    _ = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    let summary = await transport.notifyStateSummary()
    #expect(summary.contains("response: enable FAILED"))
    #expect(summary.contains("bulk: enable FAILED"))
    await transport.disconnect()
}

/// A CCCD write the device accepts but does not act on: the summary must say
/// "reported off" rather than "enabled", or the diagnosis points at the wrong
/// layer entirely.
@Test func aNotifyEnableThatDoesNotTakeIsReportedAsOff() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    pocket.notifyOutcome = .silent
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    _ = try await transport.connect(timeout: .seconds(5))
    #expect(await transport.notifyStateSummary() == "response: no callback yet, bulk: no callback yet")

    pocket.reportNotifyState(PocketGATT.response, notifying: false)
    pocket.reportNotifyState(PocketGATT.bulk, notifying: true)
    await central.settle()

    #expect(await transport.notifyStateSummary() == "response: reported off, bulk: enabled")
    await transport.disconnect()
}

@Test func commandCharacteristicPropertiesAreReportedFromDiscovery() async throws {
    let (transport, central, _) = try await FakeBLE.connected()
    await central.settle()

    #expect(await transport.commandCharacteristicProperties() == "write-with-response")
    await transport.disconnect()
}

// MARK: - Writes and the acknowledgement queue

@Test func sendWaitsForTheWriteAcknowledgement() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .silent }

    let send = Task { try await transport.send(Data("APP&STA".utf8)) }
    #expect(await central.log.wait(for: isWrite))
    #expect(await outcome(of: send, within: .milliseconds(150)) == nil,
            "send returned before the write was acknowledged")

    pocket.acknowledgeWrite()
    #expect(await outcome(of: send)?.succeeded == true)
    #expect(central.log.contains(.write(Data("APP&STA".utf8))))
    await transport.disconnect()
}

@Test func aFailedWriteSurfacesAsAnError() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .fail(RadioError("no resources")) }

    let result = await outcome(of: Task { try await transport.send(Data("APP&STA".utf8)) })
    if case .transferFailed(let message)? = result?.thrownError as? PocketError {
        #expect(message.hasPrefix("write failed:"))
    } else {
        Issue.record("expected transferFailed, got \(String(describing: result?.thrownError))")
    }
    await transport.disconnect()
}

/// CoreBluetooth acks one characteristic's writes in submission order, and
/// the transport's FIFO depends on it: the first ack must resume the first
/// sender, not whichever happens to be convenient.
@Test func writeAcknowledgementsAreMatchedInSubmissionOrder() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .silent }

    let first = Task { try await transport.send(Data("FIRST".utf8)) }
    #expect(await central.log.wait(for: .write(Data("FIRST".utf8))))
    let second = Task { try await transport.send(Data("SECOND".utf8)) }
    #expect(await central.log.wait(for: .write(Data("SECOND".utf8))))

    pocket.acknowledgeWrite()
    #expect(await outcome(of: first)?.succeeded == true)
    #expect(await outcome(of: second, within: .milliseconds(150)) == nil,
            "one acknowledgement resumed two senders")

    pocket.acknowledgeWrite()
    #expect(await outcome(of: second)?.succeeded == true)
    await transport.disconnect()
}

/// An acknowledgement for some other characteristic must not pop the queue —
/// it would resume a sender whose write is still in flight, and every later
/// ack would then land one slot out.
@Test func anAcknowledgementForAnotherChannelDoesNotPopTheQueue() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()
    await central.settle { pocket.writeOutcome = .silent }

    let send = Task { try await transport.send(Data("APP&STA".utf8)) }
    #expect(await central.log.wait(for: isWrite))

    pocket.acknowledgeWrite(channel: PocketGATT.response)
    #expect(await outcome(of: send, within: .milliseconds(150)) == nil,
            "a foreign acknowledgement resumed the command sender")

    pocket.acknowledgeWrite(channel: PocketGATT.command)
    #expect(await outcome(of: send)?.succeeded == true)
    await transport.disconnect()
}

// MARK: - Streams

@Test func responseAndBulkPayloadsReachTheirOwnStreams() async throws {
    let (transport, _, pocket) = try await FakeBLE.connected()
    let responses = Task { () throws -> [Data] in
        var out: [Data] = []
        for await payload in transport.responseStream() {
            out.append(payload)
            if out.count == 2 { break }
        }
        return out
    }
    let bulk = Task { () throws -> [Data] in
        var out: [Data] = []
        for await payload in transport.bulkStream() {
            out.append(payload)
            if out.count == 1 { break }
        }
        return out
    }

    pocket.notify(PocketGATT.response, Data("MCU&SK&OK".utf8))
    pocket.notify(PocketGATT.bulk, Data([0xFF, 0xF3, 0x48, 0xC4]))
    pocket.notify(PocketGATT.response, Data("MCU&STE&0".utf8))

    #expect(try await responses.value == [Data("MCU&SK&OK".utf8), Data("MCU&STE&0".utf8)])
    #expect(try await bulk.value == [Data([0xFF, 0xF3, 0x48, 0xC4])])
    await transport.disconnect()
}

/// The scrambled-audio defect lived one layer up, but the ordering guarantee
/// starts here: notifications reach the bulk stream in arrival order, with
/// nothing between them that could reorder anything.
@Test func bulkChunkOrderIsPreserved() async throws {
    let (transport, _, pocket) = try await FakeBLE.connected()
    let chunks = (0..<200).map { Data([UInt8($0 % 256), UInt8($0 / 256)]) }
    let collected = Task { () throws -> [Data] in
        var out: [Data] = []
        for await payload in transport.bulkStream() {
            out.append(payload)
            if out.count == chunks.count { break }
        }
        return out
    }

    for chunk in chunks { pocket.notify(PocketGATT.bulk, chunk) }

    #expect(try await collected.value == chunks)
    await transport.disconnect()
}

/// A notification on a channel this package does not own is dropped, not
/// mis-routed: the response stream sees only the response channel.
@Test func aNotificationOnAForeignChannelIsIgnored() async throws {
    let (transport, _, pocket) = try await FakeBLE.connected()
    let responses = Task { () throws -> Data? in
        for await payload in transport.responseStream() { return payload }
        return nil
    }

    pocket.notify(FakeBLE.batteryLevel, Data([99]))
    pocket.notify(PocketGATT.response, Data("MCU&SK&OK".utf8))

    #expect(try await responses.value == Data("MCU&SK&OK".utf8))
    await transport.disconnect()
}

// MARK: - Restoration flag

@Test func wasRestoredIsFalseWithoutRestoration() async throws {
    let (transport, _, _) = try await FakeBLE.connected()
    #expect(await transport.wasRestored() == false)
    await transport.disconnect()
}
