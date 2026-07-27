import Foundation

/// Identifies one recording on the device. The device's key is the timestamp;
/// `date` is the directory it lives in.
///
/// `date` is normally `YYYY-MM-DD` derived from a 14-digit timestamp — but
/// live hardware also produces IDs that are not 14 ASCII digits (e.g.
/// "PH260105143000"), and for those `date` carries the raw ID verbatim
/// rather than a fabricated date. Consumers must not assume the
/// `YYYY-MM-DD` shape; see `PocketSession.dateDirectory(fromTimestamp:)`.
public struct RecordingID: Sendable, Hashable, Codable {
    public let date: String       // usually YYYY-MM-DD; see the type note
    public let timestamp: String  // usually YYYYMMDDHHMMSS; see the type note

    public init(date: String, timestamp: String) {
        self.date = date
        self.timestamp = timestamp
    }
}

enum DeviceClock {
    /// The device expects UTC in YYYYMMDDHHMMSS.
    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

public enum SliderPosition: Sendable, Equatable {
    case conversation   // MCU&REC&CON — slider down
    case call           // MCU&REC&CALL — slider up
}

/// `MCU&WIFIS&<n>` as observed in an HCI snoop of one complete app-driven
/// sync: the machine walks 0 → 3 (≈120 ms after `APP&WIFIO`) → 2 (phone
/// associated) → 1. State 1 means the TCP client is CONNECTED on :8475 (the
/// TCP SYN in the simultaneous packet capture precedes it by
/// ~0.4 s) — it is reported before any upload command, so it is not
/// "transferring".
public enum WiFiState: Int, Sendable, Equatable {
    case off = 0
    case tcpConnected = 1
    case clientJoined = 2
    case accessPointUp = 3
}

public struct StorageInfo: Sendable, Equatable {
    public let freeMB: Int
    public let totalMB: Int
    public init(freeMB: Int, totalMB: Int) {
        self.freeMB = freeMB
        self.totalMB = totalMB
    }
}

public struct RecordingInfo: Sendable, Equatable {
    public let id: RecordingID
    public let durationSeconds: Int
    public init(id: RecordingID, durationSeconds: Int) {
        self.id = id
        self.durationSeconds = durationSeconds
    }
    /// The device records a fixed 32 kbps MP3, so size is predictable from duration.
    public var estimatedBytes: Int { durationSeconds * 4000 }
}

public struct DeviceStatus: Sendable, Equatable {
    public let batteryPercent: Int
    public let firmware: String
    public let macAddress: String
    public let wifiFirmware: String
    public let storage: StorageInfo
    public let slider: SliderPosition
    public let isRecording: Bool

    public init(batteryPercent: Int, firmware: String, macAddress: String,
                wifiFirmware: String, storage: StorageInfo,
                slider: SliderPosition, isRecording: Bool) {
        self.batteryPercent = batteryPercent
        self.firmware = firmware
        self.macAddress = macAddress
        self.wifiFirmware = wifiFirmware
        self.storage = storage
        self.slider = slider
        self.isRecording = isRecording
    }
}

public enum DeviceEvent: Sendable, Equatable {
    case recordingStarted(RecordingID)
    case recordingInProgress(since: String, elapsedSeconds: Int)
    /// An `MCU&STO` that reached the unsolicited path. NOT a reliable stop
    /// signal: a device-button stop sends nothing at all (field-confirmed
    /// 2026-07-26) — `MCU&STO` exists only as the reply to a remote
    /// `APP&STO`, so this fires only when that reply misses its waiter
    /// (e.g. lands after the request timed out). A client that needs to
    /// notice stops must poll the recording state (`APP&STE`).
    case recordingStopped
    case disconnected
    /// A WiFi transfer proceeded without the device ever reporting a joined
    /// client (`MCU&WIFIS&2`) within the readiness window. A lenient-mode
    /// diagnostic, not an error: the transfer itself may still succeed.
    case wifiReadinessNotObserved
    /// A frame the device sent that satisfied no armed request matcher and is
    /// not a known unsolicited event, carrying the frame text verbatim (for
    /// `.unparsed` frames included). Before this case existed such frames
    /// were silently dropped, which made "the device answered in a shape we
    /// did not expect" indistinguishable from "the device never answered" —
    /// exactly the blindness that hid the real WiFi handshake on hardware.
    /// Observation only: yielding it never changes matching or timeouts.
    case unmatchedResponse(String)
    /// The device sent bytes on the WiFi TCP socket past the announced file
    /// length (live hardware appends a short trailer — 10 bytes observed,
    /// content not yet identified). The announced size is authoritative, so
    /// the transfer keeps exactly that many bytes and surfaces the surplus
    /// here for diagnosis: `byteCount` is the total surplus read, `preview`
    /// at most its first `TCPFetch.surplusPreviewLimit` bytes.
    case wifiTrailerReceived(byteCount: Int, preview: Data)
}

public enum TransferMode: Sendable, Equatable {
    case ble
    case wifi
    /// WiFi when the estimated size exceeds 1 MB, else BLE; falls back to BLE on WiFi failure.
    case auto
}
