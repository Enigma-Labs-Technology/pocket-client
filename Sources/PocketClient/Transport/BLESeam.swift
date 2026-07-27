// pocket-client/Sources/PocketClient/Transport/BLESeam.swift
import Foundation
@preconcurrency import CoreBluetooth

// MARK: - Why this seam exists
//
// `BLETransport` runs a state machine whose worst failure modes are invisible
// to a compiler and expensive to reach on hardware: a checked continuation
// left parked forever, a zombie half-connect holding the radio's single
// central slot, a stale attempt killing a live one. The device this package
// drives can be permanently damaged by careless GATT traffic, so "just try it
// against the recorder" is not a test strategy — it is the last resort.
//
// These protocols cover EXACTLY the CoreBluetooth members `BLETransport`
// uses, so the whole machine can run in-process against a fake radio,
// deterministically, with no device present.
//
// WHY INTERNAL. This is a testability affordance, not API. Nobody outside the
// package should write a transport by conforming to these — `PocketTransport`
// is the public abstraction for that, and it is deliberately radio-free. The
// package's public surface does not widen by one symbol; the tests reach the
// seam with `@testable import`.
//
// SAFETY — the seam is NARROWER than CoreBluetooth, never wider:
//
//   * `discoverServices(only:)` and `discoverCharacteristics(only:for:)` take
//     NON-OPTIONAL `[CBUUID]`. CoreBluetooth's own methods accept `nil`,
//     meaning "enumerate everything", which would walk the recorder's OTA and
//     rebinding services (see the safety note on `PocketGATT`). At this seam
//     that wildcard is not discouraged, it is UNREPRESENTABLE: there is no
//     value of the parameter type that expresses it. A contributor who wanted
//     it would have to edit this protocol — a diff that also has to defeat
//     `discoveryAsksForExactlyTheThreeChannelsAndNothingElse`.
//   * writes are write-WITH-response only. The ack is what `send` awaits; a
//     write-without-response would resume nothing and hang the caller, so the
//     type simply cannot express one.
//   * after this refactor `BLETransport`'s state machine holds no
//     CoreBluetooth object at all — only seam values. There is no
//     `CBPeripheral` in scope anywhere in it to call the wildcard on. The
//     CoreBluetooth types appear in exactly one place: the delegate witnesses
//     at the bottom of `BLETransport.swift`, which do nothing but forward.

/// The central manager, as `BLETransport` uses it.
///
/// `CBCentralManager` conforms by extension (below), so the live path is the
/// same object it always was — identity, threading and delivery order are
/// CoreBluetooth's, unchanged.
protocol BLECentral: AnyObject {
    /// Radio state. Same name and type as `CBCentralManager.state`, so the
    /// live conformance needs no adapter at all.
    var state: CBManagerState { get }

    /// Starts the package's link-layer scan.
    ///
    /// The service filter is baked in as "none" because that is the only scan
    /// this package has ever run: the recorder does not advertise its service
    /// UUID, so the `PKT01_` name gate does the filtering. NOTE the asymmetry
    /// with discovery below — it is deliberate, not an oversight. A scan
    /// touches no GATT table (nothing is connected yet), so no safety property
    /// rides on this argument; discovery walks the attribute database of a
    /// connected device, which is why only *that* side forbids the wildcard.
    func beginScan()
    func endScan()

    func connectPeripheral(_ peripheral: any BLEPeripheral)
    func cancelConnection(to peripheral: any BLEPeripheral)

    /// `retrievePeripherals(withIdentifiers:)`, narrowed to the single lookup
    /// `BLETransport.connect(to:)` performs. nil means this system has never
    /// seen that identifier — the `deviceNotFound` case, which must NOT fall
    /// back to some other Pocket.
    func knownPeripheral(withIdentifier identifier: UUID) -> (any BLEPeripheral)?
}

/// The peripheral, as `BLETransport` uses it.
protocol BLEPeripheral: AnyObject {
    var name: String? { get }
    var identifier: UUID { get }
    var state: CBPeripheralState { get }

    /// Services ALREADY discovered (or restored) — a property read, never a
    /// radio operation. Deliberately named apart from `CBPeripheral.services`
    /// so the live conformance's bridge can never recurse into itself.
    var discoveredServices: [any BLEService]? { get }

    func attachDelegate(_ delegate: any BLEDelegate)

    /// Explicit-UUID discovery — the package's central safety property.
    /// The list is non-optional: CoreBluetooth's `nil` wildcard, which would
    /// enumerate the OTA and rebinding services, cannot be expressed here.
    func discoverServices(only serviceUUIDs: [CBUUID])
    /// As above, for characteristics of an already-discovered service.
    func discoverCharacteristics(only characteristicUUIDs: [CBUUID], for service: any BLEService)

    func setNotify(_ enabled: Bool, for characteristic: any BLECharacteristic)

    /// Write-with-response only: `send` parks until the ack, so an
    /// unacknowledged write type would hang it. Not a parameter by design.
    func writeWithResponse(_ data: Data, to characteristic: any BLECharacteristic)
}

/// A GATT service, as `BLETransport` reads it.
protocol BLEService: AnyObject {
    var uuid: CBUUID { get }
    /// Characteristics ALREADY discovered (or restored) — a property read,
    /// never a radio operation. Named apart from `CBService.characteristics`
    /// for the same reason as `discoveredServices`.
    var discoveredCharacteristics: [any BLECharacteristic]? { get }
}

/// A GATT characteristic, as `BLETransport` reads it.
protocol BLECharacteristic: AnyObject {
    var uuid: CBUUID { get }
    var properties: CBCharacteristicProperties { get }
    var isNotifying: Bool { get }
    var value: Data? { get }
}

/// Everything the radio tells `BLETransport`, in seam terms.
///
/// Every method is named apart from its CoreBluetooth counterpart on purpose:
/// an overload set differing only in parameter type (`CBPeripheral` vs
/// `any BLEPeripheral`) would let a forwarding witness silently call *itself*.
///
/// It refines the two CoreBluetooth delegate protocols because its only
/// conformer, `BLETransport`, must be a real delegate anyway — and that
/// refinement is what lets `CBPeripheral.attachDelegate` and the live central
/// factory hand the delegate straight through with no downcast.
protocol BLEDelegate: CBCentralManagerDelegate, CBPeripheralDelegate {
    func bleDidUpdateState(_ central: any BLECentral)
    /// iOS state restoration. Cross-platform at this seam even though only the
    /// iOS delegate witness ever calls it in production: the logic is pure
    /// bookkeeping over seam values, and gating it to iOS would put the two
    /// branches this package cares about most — adoption, and the mismatch
    /// teardown — beyond the reach of `swift test`.
    func bleWillRestoreState(_ central: any BLECentral, peripherals: [any BLEPeripheral])
    func bleDidDiscoverPeripheral(_ peripheral: any BLEPeripheral, advertisementData: [String: Any])
    func bleDidConnect(_ peripheral: any BLEPeripheral)
    func bleDidFailToConnect(_ peripheral: any BLEPeripheral, error: Error?)
    func bleDidDisconnect(_ peripheral: any BLEPeripheral, error: Error?)
    func bleDidDiscoverServices(_ peripheral: any BLEPeripheral, error: Error?)
    func bleDidDiscoverCharacteristics(_ peripheral: any BLEPeripheral, for service: any BLEService,
                                       error: Error?)
    func bleDidWriteValue(_ peripheral: any BLEPeripheral, for characteristic: any BLECharacteristic,
                          error: Error?)
    func bleDidUpdateNotificationState(_ peripheral: any BLEPeripheral,
                                       for characteristic: any BLECharacteristic, error: Error?)
    func bleDidUpdateValue(_ peripheral: any BLEPeripheral, for characteristic: any BLECharacteristic,
                           error: Error?)
}

/// Builds the central a `BLETransport` drives, given its delegate, its serial
/// queue, and the construction options a restore identifier implies. The live
/// factory returns a real `CBCentralManager`; tests substitute a fake radio.
typealias BLECentralFactory = (any BLEDelegate, DispatchQueue, [String: Any]?) -> any BLECentral

// MARK: - Live conformances
//
// Extensions on the CoreBluetooth classes themselves, never wrappers: object
// IDENTITY is load-bearing in `BLETransport` (`discardRestorationLeftover`
// distinguishes a restored leftover from the active link with `===`, and the
// system hands back one `CBPeripheral` instance per identifier). A wrapper
// would need an instance registry to preserve that; an extension gets it free.
//
// The three `as?` bridges below are total by construction: a real
// `CBCentralManager`/`CBPeripheral` is only ever handed values that came out
// of its own delegate callbacks, which are CoreBluetooth objects. Fakes live
// in the test world, where the central, the peripherals, the services and the
// characteristics are all fakes together — the two worlds never mix, because
// the factory that builds the central is what chooses the world.

extension CBCentralManager: BLECentral {
    func beginScan() { scanForPeripherals(withServices: nil) }

    func endScan() { stopScan() }

    func connectPeripheral(_ peripheral: any BLEPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        connect(peripheral)
    }

    func cancelConnection(to peripheral: any BLEPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(peripheral)
    }

    func knownPeripheral(withIdentifier identifier: UUID) -> (any BLEPeripheral)? {
        retrievePeripherals(withIdentifiers: [identifier]).first
    }
}

extension CBPeripheral: BLEPeripheral {
    var discoveredServices: [any BLEService]? { services }

    func attachDelegate(_ delegate: any BLEDelegate) { self.delegate = delegate }

    func discoverServices(only serviceUUIDs: [CBUUID]) {
        // Resolves to CoreBluetooth's `discoverServices(_:)` — a different
        // argument label, so this can never call itself.
        discoverServices(serviceUUIDs)
    }

    func discoverCharacteristics(only characteristicUUIDs: [CBUUID], for service: any BLEService) {
        guard let service = service as? CBService else { return }
        discoverCharacteristics(characteristicUUIDs, for: service)
    }

    func setNotify(_ enabled: Bool, for characteristic: any BLECharacteristic) {
        guard let characteristic = characteristic as? CBCharacteristic else { return }
        setNotifyValue(enabled, for: characteristic)
    }

    func writeWithResponse(_ data: Data, to characteristic: any BLECharacteristic) {
        guard let characteristic = characteristic as? CBCharacteristic else { return }
        writeValue(data, for: characteristic, type: .withResponse)
    }
}

extension CBService: BLEService {
    var discoveredCharacteristics: [any BLECharacteristic]? { characteristics }
}

extension CBCharacteristic: BLECharacteristic {}
