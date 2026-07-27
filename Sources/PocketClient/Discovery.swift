// pocket-client/Sources/PocketClient/Discovery.swift
import Foundation
@preconcurrency import CoreBluetooth

/// A recorder found during a BLE scan.
public struct DiscoveredDevice: Sendable, Equatable {
    public let name: String
    public let identifier: UUID
}

/// One nearby Pocket as enumerated by `PocketScanner` — a picker row.
/// `identifier` is what `BLETransport.connect(to:)` takes; `rssi` is the
/// latest signal-strength reading in dBm (more negative = weaker), or nil
/// while the radio has not delivered a usable reading yet (CoreBluetooth
/// reports 127 when strength is unavailable).
public struct NearbyPocket: Sendable, Equatable, Identifiable {
    public let identifier: UUID
    public let name: String
    public let rssi: Int?

    public var id: UUID { identifier }

    public init(identifier: UUID, name: String, rssi: Int?) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
    }
}

/// The device's command GATT table — the ONLY service this package touches.
///
/// SAFETY: the recorder also exposes `ffd0`, `e49a3001-…` and `e49a25f8-…`
/// services carrying OTA and rebinding traffic. Discovering or writing them
/// risks bricking the hardware, so no code in this package may reference
/// them; service and characteristic discovery must always pass these
/// explicit UUIDs, never `nil` wildcards.
enum PocketGATT {
    static let service = CBUUID(string: "001120A0-2233-4455-6677-889912345678")
    static let bulk = CBUUID(string: "001120A1-2233-4455-6677-889912345678")
    static let command = CBUUID(string: "001120A2-2233-4455-6677-889912345678")
    static let response = CBUUID(string: "001120A3-2233-4455-6677-889912345678")
    static let namePrefix = "PKT01_"
}
