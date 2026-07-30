// pocket-client/Sources/PocketClient/Wire/RecordingDate.swift
//
// Reading a date somebody typed, before it becomes a frame.
//
// On 2026-07-28, `pocket-cli sync-wifi 20260728 2` printed
//
//     no recordings on 20260728 — nothing to sync (try `pocket-cli list`)
//
// against a device that had eight recordings that day. The argument went
// straight onto the wire as `APP&LIST&20260728`; the recorder does not know that
// directory shape, answered `MCU&LIST&0` — it answers an unrecognised directory
// with an empty listing, not with an error — and the client reported that empty
// listing as a fact about the device. It cost a hardware round, and it is the
// dangerous kind of wrong: a confident, plausible answer that sends somebody
// looking for a missing recording instead of at their own command line.
//
// Three rules follow, and they are the whole file.
//
//   1. A malformed date never reaches the radio. It is refused by name — the
//      message echoes what was given and names the forms that would have worked
//      — before anything is sent.
//
//   2. `20260104` is not malformed. It is exactly the first eight characters of
//      the recording IDs `pocket-cli list` prints, so slicing a date off one is
//      what a reasonable person does. It is normalised to `2026-01-04`, not
//      rejected. A whole 14-digit ID passed as a date is refused, but by naming
//      the date it visibly contains rather than as a generic parse failure —
//      that confusion is the most likely way to get here.
//
//   3. An empty answer to a WELL-FORMED date is reported as the device's own
//      inventory, not as advice to run another command. "No recordings on this
//      date" and "the device has never heard of this date" are different facts,
//      the device can state both, and `APP&LIST_DIRS` costs one round trip
//      (~89 ms on hardware) on a path that is about to open an access point
//      anyway. See `noRecordingsText(date:availableDates:)`.
//
// What is deliberately NOT here is a check inside `listRecordings(on:)`. Device
// directories are not always dates: live hardware has produced recording IDs
// like "PH260105143000", and `PocketSession.dateDirectory(fromTimestamp:)`
// passes those through verbatim as a `RecordingID.date` on purpose. A library
// that refused non-date directories would make exactly those recordings
// unfetchable. Validation belongs at the boundary where a *person* typed the
// string, which is where `PocketSession.lookUpRecordings(forDate:)` applies it.
import Foundation

/// Reads and renders the date a person supplied: the two accepted forms, the
/// refusals, and the text for a date that came back empty.
///
/// Pure by construction — every function here is a value in, a string out, with
/// no clock, no locale, and no host state — because these strings are the entire
/// user-facing behaviour of the defect above, and an executable target cannot be
/// tested.
public enum RecordingDate {

    /// The outcome of reading a user-supplied date argument.
    public enum Normalization: Sendable, Equatable {
        /// A well-formed date, in the `YYYY-MM-DD` form the device's
        /// `APP&LIST&…`, `APP&U&…` and `APP&D&…` all take.
        case date(String)
        /// Not a date this client will send. The payload is the whole
        /// operator-facing message: what was given, and the way out.
        case refused(String)
    }

    /// Named in every refusal, so a rejection always carries the fix with it.
    public static let acceptedForms =
        "YYYY-MM-DD (2026-01-04) or the compact YYYYMMDD (20260104)"

    /// Appended to every refusal. The reassurance is the important half: the
    /// command failed *before* the radio, so nothing on the device changed and
    /// nothing about the device has been claimed.
    private static let nothingWasSent =
        "Nothing was sent to the device; `pocket-cli list` prints the dates it has."

    /// `"20260104"` or `"2026-01-04"` → `.date("2026-01-04")`; anything else →
    /// `.refused` with the message to print.
    ///
    /// Surrounding whitespace is trimmed (a quoted shell argument can carry it),
    /// but nothing else is guessed at. Separators this client has never seen the
    /// device use — `2026/01/04`, `2026.01.04` — are refused rather than
    /// reinterpreted: guessing at an input's meaning is what produced the defect
    /// at the top of this file, and the refusal names both forms that work.
    public static func normalize(_ raw: String) -> Normalization {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let bytes = Array(text.utf8)
        func isDigit(_ index: Int) -> Bool {
            bytes[index] >= UInt8(ascii: "0") && bytes[index] <= UInt8(ascii: "9")
        }
        let dash = UInt8(ascii: "-")

        guard !bytes.isEmpty else {
            return .refused("a date is required — expected \(acceptedForms). \(nothingWasSent)")
        }

        // Reduce both accepted shapes to the same eight digits, then judge those
        // once. Nothing below can accept a shape that did not survive this.
        let digits: String?
        if bytes.count == 8, (0..<8).allSatisfy(isDigit) {
            digits = text
        } else if bytes.count == 10, bytes[4] == dash, bytes[7] == dash,
                  (0..<10).allSatisfy({ $0 == 4 || $0 == 7 || isDigit($0) }) {
            digits = String(text.prefix(4) + text.dropFirst(5).prefix(2) + text.dropFirst(8))
        } else {
            digits = nil
        }

        guard let digits else {
            // 14 digits is not a near miss — it is a recording ID. `list` prints
            // those, and taking one for the date it visibly starts with is the
            // most likely way anybody arrives here, so say which date it holds
            // instead of reciting the grammar.
            if bytes.count == 14, (0..<14).allSatisfy(isDigit) {
                let sliced = "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-"
                           + "\(text.dropFirst(6).prefix(2))"
                return .refused("'\(text)' is a recording timestamp, not a date — its date is "
                              + "\(sliced), the first 8 digits. \(nothingWasSent)")
            }
            return .refused("'\(text)' is not a date — expected \(acceptedForms). \(nothingWasSent)")
        }

        guard let date = dashed(digits) else {
            return .refused("'\(text)' is not a real calendar date — check the month and day. "
                          + "\(nothingWasSent)")
        }
        return .date(date)
    }

    /// `"20260104"` → `"2026-01-04"`, or nil when those eight digits are not a
    /// day that exists (`20260230`, `20261301`, `20260229` in a non-leap year).
    ///
    /// Gregorian and UTC by construction rather than `Calendar.current`: the
    /// device's directories are UTC, and whether a date is well-formed must not
    /// depend on the host's calendar, locale, or time zone — that would make the
    /// same command succeed on one machine and fail on another.
    private static func dashed(_ digits: String) -> String? {
        guard let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = month
        components.day = day
        guard components.isValidDate else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// What to print when a **well-formed** date came back with no recordings.
    ///
    /// The old text was `no recordings on <date> — nothing to sync (try
    /// \`pocket-cli list\`)`, which stated one fact the client had not
    /// established ("no recordings") and deferred the one it could have
    /// ("which dates exist") to a command the user has to run themselves. The
    /// three cases below are distinguishable with `APP&LIST_DIRS`, they mean
    /// genuinely different things, and only one of them is about the date:
    ///
    ///   - the device lists no dates at all — nothing is on it, and the date in
    ///     the command is not the story;
    ///   - the device lists this date but served no files for it — the day is
    ///     real and empty, which is a device oddity worth seeing;
    ///   - the device does not list this date — the likely typo, answered with
    ///     the dates that would have worked.
    public static func noRecordingsText(date: String, availableDates: [String]) -> String {
        guard !availableDates.isEmpty else {
            return "no recordings on \(date) — and none anywhere on this device: "
                 + "APP&LIST_DIRS listed no dates at all."
        }
        let listed = availableDates.joined(separator: ", ")
        if availableDates.contains(date) {
            return "no recordings on \(date) — the device does list \(date) as a date it has, "
                 + "but served no files for it. Dates on the device: \(listed)"
        }
        return "no recordings on \(date) — the device has no such date. "
             + "Dates with recordings: \(listed)"
    }

    /// The same trap one level down: the date is real and populated, and the
    /// timestamp matches nothing in it.
    ///
    /// A timestamp is not validated the way a date is — it cannot be. The device
    /// has produced IDs that are not 14 digits ("PH260105143000"), so there is no
    /// grammar to check one against; the day's own listing is the only authority,
    /// and it is right here, so it is printed.
    public static func noSuchRecordingText(timestamp: String, date: String,
                                           onThatDate: [RecordingInfo]) -> String {
        "no recording \(timestamp) on \(date) — that date has \(onThatDate.count) "
            + "recording(s): \(onThatDate.map(\.id.timestamp).joined(separator: ", "))"
    }
}
