// pocket-client/Tests/PocketClientTests/RestorationTests.swift
//
// iOS state restoration cannot be executed in tests: CoreBluetooth cannot be
// faked (a deliberate, standing decision — no mock CB layer), and restoration
// itself exists only on iOS. These tests therefore pin the two pieces that
// ARE pure logic:
//
//  - construction options: a nil restore identifier — and any identifier on
//    macOS, which has no state restoration — must produce today's plain,
//    non-restoring central;
//  - the restoration policy (`BLERestoration`): which restored peripheral is
//    adopted, and what work drives it back to usable.
//
// The imperative glue (willRestoreState -> adoption -> deferred execution at
// poweredOn -> connect() claiming the link) is compile-verified by the iOS
// build only; Plan 3's phone run exercises it live. No BLETransport is ever
// constructed here — instantiating a CBCentralManager would touch the real
// radio stack (and its permission prompt).
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
