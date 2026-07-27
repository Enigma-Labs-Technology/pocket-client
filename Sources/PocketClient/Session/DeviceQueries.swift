// pocket-client/Sources/PocketClient/Session/DeviceQueries.swift
import Foundation

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

    public func listRecordings(on date: String) async throws -> [RecordingInfo] {
        let entries = try await requestCollecting(
            .listRecordings(date: date),
            element: { if case .fileEntry = $0 { true } else { false } },
            terminator: { if case .listSummary = $0 { true } else { false } })
        return entries.compactMap { if case .fileEntry(let info) = $0 { info } else { nil } }
    }

    public func delete(_ id: RecordingID) async throws {
        _ = try await request(.delete(id)) { $0 == .deleted }
    }
}
