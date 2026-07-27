// pocket-client/Tests/PocketClientTests/RestorationTests.swift
//
// THE STANDING DECISION HERE WAS REVERSED. This file used to open by recording
// that "CoreBluetooth cannot be faked (a deliberate, standing decision — no
// mock CB layer)", and therefore that the imperative half of state restoration
// — willRestoreState -> adoption -> deferred execution at poweredOn ->
// connect() claiming the link — was compile-verified only, with a phone run as
// its sole real check.
//
// That decision was reconsidered, not forgotten. What changed is the reasoning,
// not the constraint: CoreBluetooth still cannot be faked, but `BLETransport`
// no longer talks to CoreBluetooth. It talks to the `BLECentral`/`BLEPeripheral`
// seam (Sources/PocketClient/Transport/BLESeam.swift), which is small enough to
// stand in for — six central members, ten peripheral members — and a fake radio
// behind it drives the whole state machine with no device and no permission
// prompt. The cost of the old decision was that the branches this feature
// exists for (adopt, decline, the mismatch teardown, the leftover bookkeeping)
// could only ever be checked by relaunching an app on a phone; that is a poor
// trade for a machine whose failure mode is a wedged radio.
//
// So this file now covers three layers:
//
//  - construction options: a nil restore identifier — and any identifier on
//    macOS, which has no state restoration — must produce today's plain,
//    non-restoring central;
//  - the restoration policy (`BLERestoration`): which restored peripheral is
//    adopted, and what work drives it back to usable;
//  - the imperative glue, driven end to end against the fake radio.
//
// Restoration itself still only exists on iOS: the `willRestoreState` DELEGATE
// WITNESS is `#if os(iOS)`. The handler it forwards to deliberately is not, so
// these tests run wherever `swift test` does.
import CoreBluetooth
import Testing
@testable import PocketClient

// MARK: - Construction options

/// The nil default must construct exactly the central the CLI and every
/// existing caller already gets: no options dictionary at all.
@Test func nilRestoreIdentifierYieldsNoConstructionOptions() {
    #expect(BLETransport.centralManagerOptions(restoreIdentifier: nil) == nil)
}

#if !os(iOS)
/// macOS has no state restoration: even an explicit identifier must not
/// produce construction options there (the CLI stays a plain central).
@Test func restoreIdentifierIsIgnoredWhereRestorationDoesNotExist() {
    #expect(BLETransport.centralManagerOptions(restoreIdentifier: "pocket.central") == nil)
}
#endif

// MARK: - Restoration policy

private func snapshot(name: String? = "PKT01_AB12",
                      state: CBPeripheralState = .connected,
                      service: Bool = true,
                      command: Bool = true,
                      response: Bool = true,
                      bulk: Bool = true) -> BLERestoration.PeripheralSnapshot {
    BLERestoration.PeripheralSnapshot(name: name,
                                      state: state,
                                      hasCommandService: service,
                                      hasCommandCharacteristic: command,
                                      hasResponseCharacteristic: response,
                                      hasBulkCharacteristic: bulk)
}

private let prefix = PocketGATT.namePrefix

/// Connected with all three channels resolved: usable as-is, no discovery.
@Test func fullyResolvedConnectedPeripheralIsReady() {
    #expect(BLERestoration.plan(for: snapshot(), namePrefix: prefix) == .ready)
}

/// Any missing channel forces characteristic re-discovery — never "close
/// enough": a link without all three channels cannot carry a session.
@Test func anyMissingChannelForcesCharacteristicDiscovery() {
    #expect(BLERestoration.plan(for: snapshot(command: false), namePrefix: prefix)
            == .discoverCharacteristics)
    #expect(BLERestoration.plan(for: snapshot(response: false), namePrefix: prefix)
            == .discoverCharacteristics)
    #expect(BLERestoration.plan(for: snapshot(bulk: false), namePrefix: prefix)
            == .discoverCharacteristics)
}

/// Restored mid-connect, before service discovery ran: start from services.
@Test func undiscoveredServiceForcesServiceDiscovery() {
    let bare = snapshot(service: false, command: false, response: false, bulk: false)
    #expect(BLERestoration.plan(for: bare, namePrefix: prefix) == .discoverServices)
}

/// Restored while the system's connection attempt was still pending: wait
/// for (re-issued) didConnect — the state decides before any discovery flag.
@Test func connectingPeripheralAwaitsTheSystemConnect() {
    let pending = snapshot(state: .connecting, service: false, command: false,
                           response: false, bulk: false)
    #expect(BLERestoration.plan(for: pending, namePrefix: prefix) == .awaitSystemConnect)
}

/// A restored peripheral whose link already died is not resurrected, however
/// complete its cached attributes look — reconnecting is the app's call.
@Test func deadLinksAreNotResurrected() {
    #expect(BLERestoration.plan(for: snapshot(state: .disconnected), namePrefix: prefix) == nil)
    #expect(BLERestoration.plan(for: snapshot(state: .disconnecting), namePrefix: prefix) == nil)
}

/// Only our device is ever adopted: wrong prefix and nil name are rejected;
/// the bare prefix itself (and anything extending it) matches.
@Test func nameGateMatchesThePrefixExactly() {
    #expect(BLERestoration.plan(for: snapshot(name: "OTHER_AB12"), namePrefix: prefix) == nil)
    #expect(BLERestoration.plan(for: snapshot(name: nil), namePrefix: prefix) == nil)
    #expect(BLERestoration.plan(for: snapshot(name: "PKT01"), namePrefix: prefix) == nil)
    #expect(BLERestoration.plan(for: snapshot(name: "PKT01_"), namePrefix: prefix) == .ready)
}

/// Among several restored peripherals the first adoptable one wins —
/// mirroring the scan path, which takes the first matching advertiser.
@Test func firstAdoptablePeripheralWins() {
    let candidates = [snapshot(name: nil),                    // rejected: no name
                      snapshot(state: .disconnected),         // rejected: dead link
                      snapshot(state: .connecting, service: false, command: false,
                               response: false, bulk: false), // adoptable
                      snapshot()]                             // adoptable too, but later
    let adoption = BLERestoration.firstAdoptable(in: candidates, namePrefix: prefix)
    #expect(adoption?.index == 2)
    #expect(adoption?.plan == .awaitSystemConnect)
}

/// Nothing restored, or nothing adoptable, adopts nothing.
@Test func noAdoptableCandidateMeansNoAdoption() {
    #expect(BLERestoration.firstAdoptable(in: [], namePrefix: prefix) == nil)
    let hopeless = [snapshot(name: "OTHER_X"), snapshot(state: .disconnected)]
    #expect(BLERestoration.firstAdoptable(in: hopeless, namePrefix: prefix) == nil)
}

// MARK: - Restoration, driven end to end
//
// Everything below runs the real `BLETransport` against the fake radio. The
// sequence each test replays is CoreBluetooth's own: `willRestoreState`
// arrives first, before any state update, and the radio reports poweredOn
// afterwards — the ordering the deferred-execution design depends on, because
// GATT commands issued before poweredOn are dropped on the floor.

/// A link that came back fully resolved is CLAIMED, not rediscovered:
/// `connect()` returns it without scanning, without reconnecting, and without
/// a single discovery call.
@Test func aFullyRestoredLinkIsClaimedWithoutScanning() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    pocket.state = .connected
    pocket.restoreFullCache()
    for channel in [PocketGATT.response, PocketGATT.bulk] {
        pocket.commandService?.characteristic(channel)?.isNotifying = true
    }
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    let device = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    #expect(device == DiscoveredDevice(name: "PKT01_EXAMPLE", identifier: pocket.identifier))
    #expect(await transport.wasRestored())
    #expect(!central.log.contains(.beginScan))
    #expect(!central.log.contains(.connect(pocket.identifier)))
    #expect(central.log.count(where: { $0.discoveryUUIDs != nil }) == 0)
    // The old life's scan is stopped: in the background it finds nothing and
    // costs battery.
    #expect(central.log.contains(.endScan))
    await transport.disconnect()
}

/// Restoration preserves CCCD subscriptions, so only what the relaunch
/// actually lost is re-armed. Re-arming a live subscription is not harmless
/// noise — it is a GATT write the device did not need.
@Test func aRestoredLinkReArmsOnlyTheSubscriptionsItLost() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    pocket.state = .connected
    pocket.restoreFullCache()
    pocket.commandService?.characteristic(PocketGATT.response)?.isNotifying = true
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    _ = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    #expect(!central.log.contains(.setNotify(true, PocketGATT.response)))
    #expect(central.log.contains(.setNotify(true, PocketGATT.bulk)))
    await transport.disconnect()
}

/// A restored link whose characteristics were never resolved finishes the job
/// through the normal chain, and the claim still needs no scan.
@Test func aRestoredLinkNeedingCharacteristicsResolvesAndIsClaimed() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    pocket.state = .connected
    pocket.restoreServiceOnlyCache()
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    let device = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    #expect(device.identifier == pocket.identifier)
    #expect(central.log.contains(.discoverCharacteristics(peripheral: pocket.identifier,
                                                          service: PocketGATT.service,
                                                          uuids: [PocketGATT.command,
                                                                  PocketGATT.response,
                                                                  PocketGATT.bulk])))
    #expect(!central.log.contains(.beginScan))
    await transport.disconnect()
}

/// A connection attempt still in flight across the relaunch is re-issued, and
/// `didConnect` then drives the ordinary discovery chain.
@Test func aRestoredConnectingLinkReissuesTheSystemConnect() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    pocket.state = .connecting
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    let device = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    #expect(device.identifier == pocket.identifier)
    #expect(central.log.contains(.connect(pocket.identifier)))
    #expect(!central.log.contains(.beginScan))
    await transport.disconnect()
}

/// Nothing adoptable means nothing adopted: the transport is a plain scanning
/// one, and says so.
@Test func nothingAdoptableLeavesAPlainScanningTransport() async throws {
    let central = FakeCentral(state: .unknown)
    let dead = FakeBLE.pocket(name: "PKT01_DEAD")        // link already gone
    let foreign = FakeBLE.pocket(name: "OTHER_THING")    // wrong family
    central.restored = [dead, foreign]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    await central.settle()
    #expect(await transport.wasRestored() == false)

    // Its stale links are dropped rather than left holding the radio.
    #expect(central.log.contains(.cancelConnection(dead.identifier)))
    #expect(central.log.contains(.cancelConnection(foreign.identifier)))

    // And the transport still works exactly as a cold-started one.
    let fresh = FakeBLE.pocket()
    central.advertise(fresh)
    let device = try await transport.connect(timeout: .seconds(5))
    #expect(device.identifier == fresh.identifier)
    #expect(central.log.contains(.beginScan))
    await transport.disconnect()
}

/// Adoption is declined outright when a `connect()` already armed its scan —
/// the callback must never resume, arm or fail a continuation in flight. The
/// restored links become leftovers, and are dropped when the transport closes.
@Test func adoptionIsDeclinedWhenAConnectIsAlreadyArmed() async throws {
    let central = FakeCentral()
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")
    let leftover = FakeBLE.pocket(name: "PKT01_LEFTOVER")
    leftover.state = .connected
    leftover.disconnectOnCancel = .never   // isolate the adoption decision

    let connect = Task { try await transport.connect(timeout: .seconds(30)) }
    #expect(await central.log.wait(for: .beginScan))
    // A late restoration callback lands on an armed transport.
    await central.settle { transport.bleWillRestoreState(central, peripherals: [leftover]) }

    let pocket = FakeBLE.pocket()
    central.advertise(pocket)
    #expect(await outcome(of: connect)?.succeeded == true)
    #expect(await transport.wasRestored() == false)

    await transport.disconnect()
    await central.settle()
    #expect(central.log.contains(.cancelConnection(leftover.identifier)))
}

/// The mismatch branch: the caller named a specific device and the restored
/// link is a different one. The explicit choice wins — the restored link is
/// dropped, and the targeted resolution proceeds — and, crucially, the old
/// device's recovery plan dies with it rather than executing against the new
/// peripheral.
@Test func aTargetedConnectToADifferentDeviceDropsTheRestoredLink() async throws {
    let central = FakeCentral(state: .unknown)
    let restored = FakeBLE.pocket(name: "PKT01_RESTORED")
    restored.state = .connected
    restored.restoreServiceOnlyCache()   // plan: .discoverCharacteristics
    let wanted = FakeBLE.pocket(name: "PKT01_WANTED")
    central.restored = [restored]
    central.known = [wanted]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    // The radio is up before the deferred restoration can run, so `connect(to:)`
    // reaches the mismatch branch with the plan still pending.
    await central.settle { central.state = .poweredOn }
    let device = try await transport.connect(to: wanted.identifier, timeout: .seconds(5))
    central.power(.poweredOn)            // the deferred restoration finally runs
    await central.settle()

    #expect(device.identifier == wanted.identifier)
    #expect(central.log.contains(.cancelConnection(restored.identifier)))
    // The abandoned plan never executed: no discovery was ever issued against
    // the restored peripheral, only against the one that was asked for.
    let discoveries = central.log.calls.filter { $0.discoveryUUIDs != nil }
    #expect(discoveries.allSatisfy { call in
        if case .discoverServices(let peripheral, _) = call { return peripheral == wanted.identifier }
        if case .discoverCharacteristics(let peripheral, _, _) = call { return peripheral == wanted.identifier }
        return false
    })
    await transport.disconnect()
}

/// The fix that had no test until now. A restored leftover can BE the
/// peripheral the transport is actively driving — the system hands back one
/// instance per identifier — and that link's disconnect is REAL, not
/// bookkeeping. Swallowing it would leave the transport believing it still has
/// a link that is gone: every later request would hang until its own timeout,
/// and the streams would never finish, so the session's consume loops would
/// never end.
@Test func aLeftoverThatAliasesTheActiveLinkStillTearsTheTransportDown() async throws {
    let (transport, central, pocket) = try await FakeBLE.connected()

    // A restoration callback naming the very peripheral we are driving. It is
    // declined (a link already exists), so the peripheral lands in the discard
    // pile while remaining the active link.
    await central.settle { transport.bleWillRestoreState(central, peripherals: [pocket]) }

    pocket.dropLink()
    await central.settle()

    await #expect(throws: PocketError.disconnected) { try await transport.send(Data("APP&STA".utf8)) }
}

/// The same aliasing, from the other side: a targeted connect to a peripheral
/// sitting in the discard pile reclaims it, so the leftover sweep cannot
/// cancel the link that was just established.
@Test func aTargetedConnectReclaimsItsPeripheralFromTheDiscardPile() async throws {
    let central = FakeCentral(state: .poweredOn)
    central.announcesStateAtLaunch = false   // the sweep is held back until we say
    let pocket = FakeBLE.pocket()
    pocket.state = .disconnected             // restored but dead: not adoptable
    central.restored = [pocket]
    central.known = [pocket]                 // ...and the same instance is retrievable
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    let device = try await transport.connect(to: pocket.identifier, timeout: .seconds(5))
    #expect(device.identifier == pocket.identifier)

    central.power(.poweredOn)                // the deferred sweep runs now
    await central.settle()

    #expect(!central.log.contains(.cancelConnection(pocket.identifier)),
            "the leftover sweep cancelled the link the transport is driving")
    // Still live: the link the sweep spared really works.
    pocket.notify(PocketGATT.response, Data("MCU&SK&OK".utf8))
    #expect(await firstPayload(from: transport.responseStream()) == Data("MCU&SK&OK".utf8))
    await transport.disconnect()
}

/// A restored link whose recovery fails before `connect()` claims it degrades
/// gracefully: the peripheral and the claim are dropped, and the transport
/// falls back to being an ordinary scanning one rather than dying.
@Test func aRestoredLinkWhoseRecoveryFailsDegradesToScanning() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket(name: "PKT01_RESTORED")
    pocket.state = .connected
    pocket.serviceDiscovery = .fail(RadioError("att timeout"))
    pocket.disconnectOnCancel = .never
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    #expect(await central.log.wait(for: .cancelConnection(pocket.identifier)))

    let fresh = FakeBLE.pocket()
    central.advertise(fresh)
    let device = try await transport.connect(timeout: .seconds(5))

    #expect(device.identifier == fresh.identifier)
    #expect(central.log.contains(.beginScan))
    await transport.disconnect()
}

/// REGRESSION. This branch was unreachable until `BLETransport` gained its
/// CoreBluetooth seam, and the first test to reach it found it broken.
///
/// A restored link that is still UP but not adopted is cancelled at power-on,
/// and CoreBluetooth answers a cancel on a live link with a disconnect
/// callback. `performDeferredRestoration` used to run `restorationDiscards = []`
/// as it issued those cancels, so by the time the callback landed
/// `discardRestorationLeftover` no longer recognised it as bookkeeping: it fell
/// through the teardown funnel and closed the transport — killing the link that
/// WAS adopted. Two restored Pockets, or one stale link alongside the live one,
/// was all it took, and `connect()` then failed `.disconnected` on a background
/// relaunch, the exact scenario the feature exists for.
///
/// The fix keeps the cancelled leftovers LISTED, so the removal in
/// `discardRestorationLeftover` is what drains them — that removal being the
/// only thing that tells a bookkeeping callback from a real one.
@Test func aCancelledLeftoverDoesNotTearDownTheAdoptedLink() async throws {
    let central = FakeCentral(state: .unknown)
    let adopted = FakeBLE.pocket(name: "PKT01_ADOPTED")
    adopted.state = .connected
    adopted.restoreFullCache()
    let leftover = FakeBLE.pocket(name: "PKT01_LEFTOVER")
    leftover.state = .connected          // a LIVE link, adoptable but adopted second
    leftover.restoreFullCache()
    central.restored = [adopted, leftover]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    #expect(await central.log.wait(for: .cancelConnection(leftover.identifier)))
    await central.settle()               // the leftover's disconnect callback lands here

    let device = try await transport.connect(timeout: .seconds(5))
    #expect(device.identifier == adopted.identifier)
    #expect(await transport.wasRestored())
    // The adopted link is not merely reported: it works.
    adopted.notify(PocketGATT.response, Data("MCU&SK&OK".utf8))
    #expect(await firstPayload(from: transport.responseStream()) == Data("MCU&SK&OK".utf8))
    // And the leftover really was dropped — it does not keep holding the radio.
    #expect(!central.log.contains(.cancelConnection(adopted.identifier)))
    await transport.disconnect()
}

/// The residue question the fix raises: a cancelled leftover whose disconnect
/// callback NEVER arrives (a cancelled pending connect may produce none) stays
/// listed until `close`. That entry must be inert — in particular it must not
/// let a later, genuine disconnect be mistaken for bookkeeping.
@Test func aLeftoverWhoseCallbackNeverArrivesCannotAffectALaterLink() async throws {
    let central = FakeCentral(state: .unknown)
    // Live, so cancelling it is a real cancel — but outside the name family,
    // so it is never adopted. (A PKT01_ device with a live link WOULD be
    // adopted, which is the whole point of the adoption rule.)
    let silentLeftover = FakeBLE.pocket(name: "OTHER_SILENT")
    silentLeftover.state = .connected
    silentLeftover.disconnectOnCancel = .never   // cancelled, and never answers
    let dead = FakeBLE.pocket(name: "PKT01_DEAD")  // ours, but its link is gone
    central.restored = [dead, silentLeftover]      // so nothing here is adoptable
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    #expect(await central.log.wait(for: .cancelConnection(silentLeftover.identifier)))
    #expect(await transport.wasRestored() == false)

    // A perfectly ordinary scanning connect, with the undrained entry still listed.
    let fresh = FakeBLE.pocket()
    central.advertise(fresh)
    let device = try await transport.connect(timeout: .seconds(5))
    #expect(device.identifier == fresh.identifier)

    // A second poweredOn re-runs the deferred sweep with the residue still
    // listed. It must sweep the residue and nothing else.
    central.power(.poweredOn)
    await central.settle()
    #expect(!central.log.contains(.cancelConnection(fresh.identifier)),
            "the undrained residue made a later sweep cancel the live link")

    // And the live link is still live.
    fresh.notify(PocketGATT.response, Data("MCU&SK&OK".utf8))
    #expect(await firstPayload(from: transport.responseStream()) == Data("MCU&SK&OK".utf8))
    await transport.disconnect()
}

/// The other half of the fix's reasoning. `close` still empties the pile
/// wholesale, and that is correct rather than inconsistent: past the teardown
/// funnel there is no teardown left to tell a bookkeeping callback apart from.
/// A leftover cancelled BY `close` answers after the pile is already gone,
/// re-enters the funnel and must change nothing — if that funnel were not
/// idempotent this test would trap on a continuation resumed twice.
@Test func aLeftoverCancelledByCloseMayAnswerAfterwardsHarmlessly() async throws {
    let central = FakeCentral(state: .unknown)
    central.announcesStateAtLaunch = false      // no power-up sweep: the pile survives to close
    let leftover = FakeBLE.pocket(name: "OTHER_LEFTOVER")
    leftover.state = .connected
    leftover.disconnectOnCancel = .always       // it WILL answer, once the pile is gone
    central.restored = [leftover]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")
    await central.settle()

    await transport.disconnect()                // close cancels the leftover…
    await central.settle()                      // …and its callback lands here

    #expect(central.log.contains(.cancelConnection(leftover.identifier)))
    await #expect(throws: PocketError.disconnected) { try await transport.send(Data()) }
    await #expect(throws: PocketError.disconnected) {
        _ = try await transport.connect(timeout: .seconds(1))
    }
}
