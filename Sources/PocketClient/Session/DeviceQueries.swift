// pocket-client/Sources/PocketClient/Session/DeviceQueries.swift
import Foundation

/// The answer to "give me the recordings this date argument names", with the
/// three ways that can turn out kept apart — because two of them used to arrive
/// as the same empty array, and reporting a rejected argument as an empty device
/// is the defect `RecordingDate` exists to prevent.
public enum RecordingLookup: Sendable, Equatable {
    /// The date was well-formed and the device served files for it. `date` is the
    /// normalised `YYYY-MM-DD` form — the one later `APP&U&…` and `APP&D&…` must
    /// use, which for a compact argument is *not* what the caller passed in.
    case found(date: String, recordings: [RecordingInfo])
    /// The argument is not a date, and **nothing was sent**. The payload is the
    /// message to print; it names what was given and the forms that work.
    case refused(String)
    /// A well-formed date the device served no files for. `explanation` says
    /// which kind of empty it is and names the dates that do have recordings.
    case empty(date: String, explanation: String)
}

extension PocketSession {
    public func status() async throws -> DeviceStatus {
        let battery = try await request(.battery) { if case .battery = $0 { true } else { false } }
        let firmware = try await request(.firmware) { if case .firmware = $0 { true } else { false } }
        let mac = try await request(.macAddress) { if case .macAddress = $0 { true } else { false } }
        let wifi = try await request(.wifiFirmware) { if case .wifiFirmware = $0 { true } else { false } }
        let space = try await request(.storage) { if case .storage = $0 { true } else { false } }
        let slider = try await request(.sliderQuery) { if case .sliderPosition = $0 { true } else { false } }
        let state = try await request(.recordingState) { if case .recordingState = $0 { true } else { false } }

        guard case .battery(let percent) = battery,
              case .firmware(let fw) = firmware,
              case .macAddress(let macAddress) = mac,
              case .wifiFirmware(let wifiFW) = wifi,
              case .storage(let storage) = space,
              case .sliderPosition(let position) = slider,
              case .recordingState(let isRecording) = state
        else { throw PocketError.unexpectedResponse("incomplete status") }

        return DeviceStatus(batteryPercent: percent, firmware: fw, macAddress: macAddress,
                            wifiFirmware: wifiFW, storage: storage, slider: position,
                            isRecording: isRecording)
    }

    /// The narrow recording-state query: one `APP&STE` → `MCU&STE&<0|1>`
    /// round-trip, against `status()`'s seven. This is the ONLY way to learn
    /// that a recording stopped on the device — a device-button stop sends
    /// nothing unsolicited — so it exists to be polled cheaply.
    ///
    /// (`APP&STE` queries; `APP&STA` — one letter away — STARTS a recording.
    /// The `Command` enum keeps them distinct cases so this method cannot
    /// drift onto the wrong wire string.)
    public func isRecording() async throws -> Bool {
        let response = try await request(.recordingState) {
            if case .recordingState = $0 { true } else { false }
        }
        guard case .recordingState(let recording) = response else {
            throw PocketError.unexpectedResponse("expected MCU&STE")
        }
        return recording
    }

    public func setClock(_ date: Date = Date()) async throws {
        _ = try await request(.setClock(date)) { $0 == .clockSet }
    }

    public func listDates() async throws -> [String] {
        let entries = try await requestCollecting(
            .listDates,
            element: { if case .dateEntry = $0 { true } else { false } },
            terminator: { if case .dateSummary = $0 { true } else { false } })
        return entries.compactMap { if case .dateEntry(let d) = $0 { d } else { nil } }
    }

    /// Lists one directory verbatim — `date` goes on the wire as given.
    ///
    /// Unvalidated on purpose: it also takes directories that came *from* the
    /// device, and those are not always dates (see
    /// `PocketSession.dateDirectory(fromTimestamp:)`). For a string a person
    /// typed, call `lookUpRecordings(forDate:)` instead — it validates first and
    /// never sends a date this client cannot vouch for.
    public func listRecordings(on date: String) async throws -> [RecordingInfo] {
        let entries = try await requestCollecting(
            .listRecordings(date: date),
            element: { if case .fileEntry = $0 { true } else { false } },
            terminator: { if case .listSummary = $0 { true } else { false } })
        return entries.compactMap { if case .fileEntry(let info) = $0 { info } else { nil } }
    }

    /// Resolves a **user-supplied** date argument to that day's recordings —
    /// the validating front door to `listRecordings(on:)`, and the one every
    /// operator-facing path uses.
    ///
    /// Two things it does that the raw listing cannot:
    ///
    ///   - A malformed date is refused with **no frame sent at all**
    ///     (`.refused`). The device answers an unrecognised directory with an
    ///     empty listing rather than an error, so an unvalidated argument comes
    ///     back indistinguishable from a genuinely empty day — which is exactly
    ///     how `sync-wifi 20260728` came to report "no recordings" about a device
    ///     holding eight of them. `20260728` itself is now normalised, not
    ///     refused; see `RecordingDate`.
    ///   - A well-formed date the device served nothing for costs one extra
    ///     `APP&LIST_DIRS` (~89 ms on hardware) so the answer can say *which*
    ///     kind of nothing it is and name the dates that do have recordings
    ///     (`.empty`).
    public func lookUpRecordings(forDate raw: String) async throws -> RecordingLookup {
        let date: String
        switch RecordingDate.normalize(raw) {
        case .refused(let reason): return .refused(reason)
        case .date(let normalized): date = normalized
        }
        let recordings = try await listRecordings(on: date)
        guard recordings.isEmpty else { return .found(date: date, recordings: recordings) }
        let dates = try await listDates()
        return .empty(date: date,
                      explanation: RecordingDate.noRecordingsText(date: date,
                                                                  availableDates: dates))
    }

    public func delete(_ id: RecordingID) async throws {
        _ = try await request(.delete(id)) { $0 == .deleted }
    }
}
