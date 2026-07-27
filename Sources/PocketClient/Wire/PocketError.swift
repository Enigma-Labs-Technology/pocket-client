import Foundation

public enum PocketError: Error, Equatable {
    case authRejected                      // MCU&SK&ERR — the device then drops the link
    case notAuthenticated
    case timeout(Command)
    case unknownCommand(Command)           // MCU&UNKNOWN
    case unexpectedResponse(String)
    case sizeMismatch(expected: Int, received: Int)
    case notMP3
    /// The device announced 0 bytes for the recording (0-second recordings
    /// exist on real hardware). Distinct from `.notMP3`, which would otherwise
    /// misdiagnose the empty payload as channel corruption.
    case emptyRecording
    /// `BLETransport.connect(to:)` was asked for a peripheral identifier this
    /// system does not know — the device was never seen by this phone, or the
    /// system forgot it (e.g. a factory reset gave it a new identity). The
    /// failure is immediate, and deliberately has no scan fallback: silently
    /// connecting to a *different* Pocket would defeat choosing one.
    case deviceNotFound(UUID)
    case busy(String)
    case wifiJoinFailed(String)
    case transferFailed(String)
    case disconnected
}
