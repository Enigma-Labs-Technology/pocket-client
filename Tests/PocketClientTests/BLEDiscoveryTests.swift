// pocket-client/Tests/PocketClientTests/BLEDiscoveryTests.swift
//
// The package's central safety property, asserted rather than read.
//
// The recorder exposes services that can destroy it: a combo-chip OTA
// receiver, a provisioning surface, and an unidentified factory service (see
// the safety note on `PocketGATT`, and the GATT map in the protocol doc).
// `BLETransport` must never enumerate them — every discovery it issues names
// exactly the `001120a*` command service and its three channels, and never
// CoreBluetooth's `nil` wildcard, which means "walk everything".
//
// Until now that was a guarantee you got by reading the code carefully. These
// tests make it one a future contributor cannot silently break: the fake
// device below carries the recorder's REAL GATT map, forbidden services and
// all, and the fake radio records every discovery call with its argument list.
//
// Two layers hold the property, and both are deliberate:
//   1. TYPE. The seam's `discoverServices(only:)` takes a non-optional
//      `[CBUUID]`. The wildcard is not discouraged, it is unrepresentable —
//      there is no value of that parameter type meaning "everything".
//   2. ASSERTION. These tests pin the exact lists, so narrowing the type is
//      not the only thing a wildcard would have to defeat.
import CoreBluetooth
import Testing
@testable import PocketClient

/// The only two discovery calls this package is ever allowed to make.
private let serviceDiscovery = [PocketGATT.service]
private let channelDiscovery = [PocketGATT.command, PocketGATT.response, PocketGATT.bulk]

private func discoveries(_ central: FakeCentral) -> [BLECall] {
    central.log.calls.filter { $0.discoveryUUIDs != nil }
}

/// THE test. A full connect issues exactly two discovery calls, each naming
/// exactly the UUIDs it is allowed to name — and each carrying a non-empty
/// list, the closest thing to a wildcard this seam can even express.
@Test func discoveryAsksForExactlyTheThreeChannelsAndNothingElse() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    _ = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    #expect(discoveries(central) == [
        .discoverServices(peripheral: pocket.identifier, uuids: serviceDiscovery),
        .discoverCharacteristics(peripheral: pocket.identifier, service: PocketGATT.service,
                                 uuids: channelDiscovery),
    ])
    // An empty list is as close to `nil` as the seam allows anyone to get.
    #expect(discoveries(central).allSatisfy { !($0.discoveryUUIDs ?? []).isEmpty })
    await transport.disconnect()
}

/// The forbidden services are not merely un-connected-to: they are never
/// named in a discovery call, and never become visible to the transport at
/// all. The fake honors the filter the way a real device does, so anything
/// the transport did not explicitly ask for stays unrevealed.
@Test func theForbiddenServicesAreNeverEnumerated() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    central.advertisers = [pocket]
    let transport = FakeBLE.transport(central)

    _ = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    let named = Set(central.log.calls.flatMap { $0.discoveryUUIDs ?? [] })
    for forbidden in FakeBLE.forbiddenServices {
        #expect(!named.contains(forbidden), "discovery named the forbidden service \(forbidden)")
    }
    for forbidden in FakeBLE.forbiddenCharacteristics {
        #expect(!named.contains(forbidden), "discovery named the forbidden characteristic \(forbidden)")
    }
    #expect(pocket.discoveredServices?.map(\.uuid) == [PocketGATT.service])
    for service in pocket.table where service.uuid != PocketGATT.service {
        #expect(service.discoveredCharacteristics == nil,
                "characteristics of \(service.uuid) were enumerated")
    }
    await transport.disconnect()
}

/// The targeted path (`connect(to:)`) shares the scanned path's discovery
/// chain — the same explicit lists, not a shortcut of its own.
@Test func targetedConnectDiscoversWithTheSameExplicitLists() async throws {
    let central = FakeCentral()
    let pocket = FakeBLE.pocket()
    central.known = [pocket]
    let transport = FakeBLE.transport(central)

    _ = try await transport.connect(to: pocket.identifier, timeout: .seconds(5))
    await central.settle()

    #expect(discoveries(central) == [
        .discoverServices(peripheral: pocket.identifier, uuids: serviceDiscovery),
        .discoverCharacteristics(peripheral: pocket.identifier, service: PocketGATT.service,
                                 uuids: channelDiscovery),
    ])
    await transport.disconnect()
}

/// A restored link whose previous life never got past connecting re-resolves
/// through the same explicit chain — restoration is not a discovery loophole.
@Test func restoredLinkRediscoversWithTheSameExplicitLists() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    pocket.state = .connected            // link up, nothing discovered yet
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    central.power(.poweredOn)
    #expect(await central.log.wait(for: { $0.discoveryUUIDs != nil }))
    _ = try await transport.connect(timeout: .seconds(5))
    await central.settle()

    #expect(discoveries(central) == [
        .discoverServices(peripheral: pocket.identifier, uuids: serviceDiscovery),
        .discoverCharacteristics(peripheral: pocket.identifier, service: PocketGATT.service,
                                 uuids: channelDiscovery),
    ])
    await transport.disconnect()
}

/// A restored attribute cache that thinned out between adoption and power-up
/// falls back to full re-resolution — again explicitly, never a wildcard
/// sweep to "find what is left".
@Test func aThinnedRestoredCacheReResolvesExplicitly() async throws {
    let central = FakeCentral(state: .unknown)
    let pocket = FakeBLE.pocket()
    pocket.state = .connected
    pocket.restoreFullCache()
    central.restored = [pocket]
    let transport = FakeBLE.transport(central, restoreIdentifier: "pocket.central")

    // The cache is complete at adoption (so the plan is `.ready`) and empty by
    // the time the radio comes up.
    await central.settle()
    await central.settle { pocket.commandService?.discoveredCharacteristics = [] }
    central.power(.poweredOn)

    #expect(await central.log.wait(for: .discoverServices(peripheral: pocket.identifier,
                                                          uuids: serviceDiscovery)))
    _ = try await transport.connect(timeout: .seconds(5))
    await central.settle()
    #expect(discoveries(central).allSatisfy { !($0.discoveryUUIDs ?? []).isEmpty })
    await transport.disconnect()
}

/// A device that does not carry the command service fails the connect rather
/// than casting about for something else to talk to.
@Test func aDeviceWithoutTheCommandServiceFailsTheConnect() async throws {
    let central = FakeCentral()
    let stranger = FakePeripheral(name: "PKT01_IMPOSTER", services: [
        FakeService(FakeBLE.otaService, characteristics: [
            FakeCharacteristic(CBUUID(string: "E49A3002-F69A-11E8-8EB2-F2801F1B9FD1")),
        ]),
    ])
    central.advertisers = [stranger]
    let transport = FakeBLE.transport(central)

    await #expect(throws: PocketError.transferFailed("command service not found")) {
        _ = try await transport.connect(timeout: .seconds(5))
    }
    await central.settle()
    // It asked for the command service and nothing else, even on a device
    // that has none.
    #expect(discoveries(central) == [.discoverServices(peripheral: stranger.identifier,
                                                       uuids: serviceDiscovery)])
    #expect(central.log.contains(.cancelConnection(stranger.identifier)))
}

/// All three channels or none: a command service missing one is not "close
/// enough", and no second, wider discovery is attempted to go looking.
@Test func aCommandServiceMissingAChannelFailsTheConnect() async throws {
    let central = FakeCentral()
    let partial = FakePeripheral(name: "PKT01_PARTIAL", services: [
        FakeService(PocketGATT.service, characteristics: [
            FakeCharacteristic(PocketGATT.command, properties: [.write]),
            FakeCharacteristic(PocketGATT.response, properties: [.notify]),
        ]),
    ])
    central.advertisers = [partial]
    let transport = FakeBLE.transport(central)

    await #expect(throws: PocketError.transferFailed("channel characteristics missing")) {
        _ = try await transport.connect(timeout: .seconds(5))
    }
    await central.settle()
    #expect(discoveries(central).count == 2)
    #expect(central.log.contains(.cancelConnection(partial.identifier)))
}
