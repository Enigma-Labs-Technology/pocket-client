import Foundation

public enum Response: Sendable, Equatable {
    case authOK
    case authError
    case battery(Int)
    case firmware(String)
    case macAddress(String)
    case wifiFirmware(String)
    case storage(StorageInfo)
    case clockSet
    case sliderPosition(SliderPosition)
    case recordingState(Bool)
    case recordingStarted(String)                                  // MCU&STA&<ts>
    case recordingStopped
    case recordingInProgress(since: String, elapsedSeconds: Int)   // MCU&RT&<ts>&<secs>
    case dateEntry(String)
    case dateSummary(count: Int)
    case fileEntry(RecordingInfo)
    case listSummary(count: Int)
    case transferSize(Int)
    case transferComplete                                          // MCU&OFF
    case deleted
    case wifiCredentials(ssid: String, passphrase: String)
    case wifiState(WiFiState)
    case shutdownAck                                               // MCU&SHUT (only when an upload was in flight)
    case wifiAccessPointOn                                         // MCU&WIFIO — AP start acknowledged
    case wifiClosed                                                // MCU&WIFIC
    case wifiUploadAck                                             // MCU&U&WIFI — upload rerouted to TCP
    case pong                                                      // MCU&WPING
    case unknown                                                   // MCU&UNKNOWN
    case unparsed(String)                                          // never silently dropped

    public static func parse(_ data: Data) -> Response {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ raw: String) -> Response {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = text.components(separatedBy: "&")
        guard f.count >= 2, f[0] == "MCU" else { return .unparsed(text) }

        func int(_ index: Int) -> Int? {
            guard f.count > index else { return nil }
            return Int(f[index])
        }

        switch f[1] {
        case "SK" where f.count == 3 && f[2] == "OK":   return .authOK
        case "SK" where f.count == 3 && f[2] == "ERR":  return .authError
        case "BAT":
            guard let v = int(2) else { return .unparsed(text) }
            return .battery(v)
        case "FW" where f.count == 3:                   return .firmware(f[2])
        case "MAC" where f.count == 3:                  return .macAddress(f[2])
        case "WF" where f.count == 3:                   return .wifiFirmware(f[2])
        case "SPA":
            guard let free = int(2), let total = int(3) else { return .unparsed(text) }
            return .storage(StorageInfo(freeMB: free, totalMB: total))
        case "T" where f.count == 3 && f[2] == "OK":    return .clockSet
        case "STE":
            guard let v = int(2), v == 0 || v == 1 else { return .unparsed(text) }
            return .recordingState(v == 1)
        case "REC" where f.count == 3 && f[2] == "CON":   return .sliderPosition(.conversation)
        case "REC" where f.count == 3 && f[2] == "CALL":  return .sliderPosition(.call)
        case "STA" where f.count == 3:                  return .recordingStarted(f[2])
        case "STO" where f.count == 2:                  return .recordingStopped
        case "RT":
            guard f.count == 4, let elapsed = int(3) else { return .unparsed(text) }
            return .recordingInProgress(since: f[2], elapsedSeconds: elapsed)
        case "DIRS" where f.count == 3:                 return .dateEntry(f[2])
        case "DIRS_SUM":
            guard let c = int(2) else { return .unparsed(text) }
            return .dateSummary(count: c)
        case "F":
            guard f.count == 5, let secs = int(4) else { return .unparsed(text) }
            return .fileEntry(RecordingInfo(id: RecordingID(date: f[2], timestamp: f[3]),
                                            durationSeconds: secs))
        case "LIST":
            guard let c = int(2) else { return .unparsed(text) }
            return .listSummary(count: c)
        case "U" where f.count == 3 && f[2] == "WIFI":  return .wifiUploadAck
        case "U":
            guard let size = int(2) else { return .unparsed(text) }
            return .transferSize(size)
        case "OFF" where f.count == 2:                  return .transferComplete
        case "D" where f.count == 2:                    return .deleted
        case "WIFI" where f.count == 4:                 return .wifiCredentials(ssid: f[2], passphrase: f[3])
        case "WIFIS":
            guard let v = int(2), let state = WiFiState(rawValue: v) else { return .unparsed(text) }
            return .wifiState(state)
        case "SHUT" where f.count == 2:                 return .shutdownAck
        case "WIFIO" where f.count == 2:                return .wifiAccessPointOn
        case "WIFIC" where f.count == 2:                return .wifiClosed
        case "WPING" where f.count == 2:                return .pong
        case "UNKNOWN" where f.count == 2:              return .unknown
        default:                                        return .unparsed(text)
        }
    }
}
