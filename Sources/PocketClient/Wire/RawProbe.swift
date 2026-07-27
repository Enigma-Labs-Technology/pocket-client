// pocket-client/Sources/PocketClient/Wire/RawProbe.swift
import Foundation

/// The fixed allowlist behind `pocket-cli raw`: the only frames the probe
/// subcommand can ever put on the wire.
///
/// Safety argument, in full:
/// - Operator input is used **only** as a lookup key into `commands` below.
///   No user string is ever concatenated into a frame; the bytes sent are
///   `Command.encoded` of the mapped case, fixed at compile time.
/// - Every value is a read-only query or an idempotent WiFi teardown
///   (`SHUT`/`WIFIC`) — nothing that writes, deletes, rebinds, provisions,
///   or flashes.
/// - `Command` itself has no OTA/WOTA/rebind/provisioning case, so even a
///   bug in the lookup could not emit one: such frames are unrepresentable
///   in the type this API returns.
public enum RawProbe {
    /// Verb → fixed command. Keys are the exact wire verbs (uppercase).
    /// `WIFIO` (AP start) is deliberately absent: it changes device state,
    /// which the probe allowlist promises never to do beyond WiFi teardown.
    private static let commands: [String: Command] = [
        "WIFIS":     .wifiStatus,       // APP&WIFIS  — WiFi state query
        "WIFI":      .wifiCredentials,  // APP&WIFI   — AP credentials query (read-only)
        "SHUT":      .wifiShutdown,     // APP&SHUT   — abort upload / reset WiFi state machine
        "WIFIC":     .wifiClose,        // APP&WIFIC  — close WiFi AP
        "WPING":     .wifiKeepalive,    // APP&WPING  — WiFi-session keepalive
        "BAT":       .battery,          // APP&BAT    — battery percent
        "FW":        .firmware,         // APP&FW     — MCU firmware version
        "MAC":       .macAddress,       // APP&MAC    — BLE MAC
        "WF":        .wifiFirmware,     // APP&WF     — WiFi firmware version
        "SPACE":     .storage,          // APP&SPACE  — free/total MB
        "STE":       .recordingState,   // APP&STE    — recording yes/no
        "REC&SECEN": .sliderQuery,      // APP&REC&SECEN — slider position
        "LIST_DIRS": .listDates,        // APP&LIST_DIRS — recording dates
    ]

    /// Allowlisted verbs for help/refusal text, in a stable order.
    public static let allowedVerbs: [String] = commands.keys.sorted()

    /// The fixed command for an allowlisted probe verb (case-insensitive),
    /// or nil for anything else — `OTA`, `WOTA`, `BLE`, `WIFI&CH`, `SK`,
    /// `T&…`, `D&…`, `U&…` and every other non-listed string all fall
    /// through to nil; there is no partial or fuzzy matching.
    public static func command(forVerb verb: String) -> Command? {
        commands[verb.uppercased()]
    }
}
