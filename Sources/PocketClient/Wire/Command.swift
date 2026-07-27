import Foundation

/// Every command this package can send. Destructive device operations
/// (OTA, rebinding, WiFi provisioning) are deliberately absent — see the
/// safety rail in the plan's Global Constraints.
public enum Command: Sendable, Equatable {
    case auth(String)
    case battery
    case firmware
    case macAddress
    case wifiFirmware
    case storage
    case setClock(Date)
    case sliderQuery
    case recordingState
    case startRecording
    case stopRecording
    /// `APP&PAU` — present in the official app's string table, but firmware 1.7
    /// answers `MCU&UNKNOWN` (probed 2026-07-25), which surfaces as
    /// `PocketError.unknownCommand`. Kept so `pocket-cli probe-unverified` can
    /// re-test future firmware; there is deliberately no `pauseRecording()` API.
    case pauseRecording
    /// `APP&RESU` — same status as `.pauseRecording`.
    case resumeRecording
    case listDates
    case listRecordings(date: String)
    case download(RecordingID)
    case delete(RecordingID)
    /// `APP&SHUT` — aborts an in-flight upload / resets the WiFi state
    /// machine. On an idle device NO reply arrives (live-probe verified), so
    /// senders must not block waiting for `MCU&SHUT`.
    case wifiShutdown
    case wifiStatus
    /// `APP&WIFI` — credentials query; the device answers synchronously with
    /// `MCU&WIFI&<ssid>&<psk>` (capture-verified; there is no unsolicited
    /// credentials push). Deliberately argument-less: the forbidden
    /// provisioning command `APP&WIFI&CH&…` shares the prefix, and the
    /// no-arguments shape is what keeps them unconfusable.
    case wifiCredentials
    /// `APP&WIFIO` — starts the access point (capture-verified: `MCU&WIFIS&3`
    /// follows ~120 ms later; `APP&WIFI` alone does NOT start it).
    case wifiAccessPointOn
    /// `APP&WPING` — the WiFi-session keepalive (reply `MCU&WPING`).
    /// `APP&PING` appears in no capture and is not a real command.
    case wifiKeepalive
    /// `APP&U&WIFI` — a MODIFIER, not a standalone request: it reroutes the
    /// upload previously selected via `.download(id)` from BLE bulk to the
    /// TCP socket. Sending it without a prior selection does nothing useful.
    case wifiDownload
    case wifiClose

    public var wireFormat: String {
        switch self {
        case .auth(let key):             return "APP&SK&\(key)"
        case .battery:                   return "APP&BAT"
        case .firmware:                  return "APP&FW"
        case .macAddress:                return "APP&MAC"
        case .wifiFirmware:              return "APP&WF"
        case .storage:                   return "APP&SPACE"
        case .setClock(let date):        return "APP&T&\(DeviceClock.format(date))"
        case .sliderQuery:               return "APP&REC&SECEN"
        case .recordingState:            return "APP&STE"
        case .startRecording:            return "APP&STA"
        case .stopRecording:             return "APP&STO"
        case .pauseRecording:            return "APP&PAU"
        case .resumeRecording:           return "APP&RESU"
        case .listDates:                 return "APP&LIST_DIRS"
        case .listRecordings(let date):  return "APP&LIST&\(date)"
        case .download(let id):          return "APP&U&\(id.date)&\(id.timestamp)"
        case .delete(let id):            return "APP&D&\(id.date)&\(id.timestamp)"
        case .wifiShutdown:              return "APP&SHUT"
        case .wifiStatus:                return "APP&WIFIS"
        case .wifiCredentials:           return "APP&WIFI"
        case .wifiAccessPointOn:         return "APP&WIFIO"
        case .wifiKeepalive:             return "APP&WPING"
        case .wifiDownload:              return "APP&U&WIFI"
        case .wifiClose:                 return "APP&WIFIC"
        }
    }

    public var encoded: Data { Data(wireFormat.utf8) }
}
