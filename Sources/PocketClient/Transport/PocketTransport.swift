// pocket-client/Sources/PocketClient/Transport/PocketTransport.swift
import Foundation

/// The three GATT channels the recorder exposes, abstracted so the protocol
/// stack can be tested without CoreBluetooth.
public protocol PocketTransport: Sendable {
    /// Write to the command channel (001120a2).
    func send(_ data: Data) async throws
    /// Single-consumer stream of response-channel payloads (001120a3). Call once.
    func responseStream() -> AsyncStream<Data>
    /// Single-consumer stream of bulk data-channel payloads (001120a1). Call once.
    func bulkStream() -> AsyncStream<Data>
    func disconnect() async
}
