// pocket-client/Sources/pocket-cli/BatchSync.swift
//
// `pocket-cli sync-wifi` — the hardware experiment for one access-point session
// per SYNC rather than one per recording.
//
// This exists because the interesting part of that feature cannot be tested
// without a device. On 2026-07-30 it produced the first real answer: the
// recorder DOES serve a second `APP&U&<date>&<ts>` while its access point is
// still up, and the transfer over it then reset mid-stream. Whether that reset
// is avoidable is now the open question.
//
// `PocketSession.downloadOverWiFi(_ recordings:…)` attempts reuse and falls back
// to a session opened for that recording whenever the device refuses it or the
// transfer over it breaks, so a batch can never deliver fewer recordings than
// the same list fetched one at a time. This command's output is how we find out
// which of those happened.
//
// So the per-recording `session:` lines below are not progress decoration —
// they ARE the result, and so is the one under a STOPPED recording. Capture the
// transcript.

import Foundation
import PocketClient

/// Greedy word wrap, so a multi-sentence failure diagnosis reads as prose in a
/// captured transcript instead of as one line the terminal breaks wherever it
/// happens to run out of width. Whitespace-collapsing by construction, which is
/// what is wanted here: the input is a sentence, not layout.
///
/// Shared with `probe-ap-lifetime`, whose verdict is several paragraphs of the
/// same kind of prose. Both commands exist to produce transcripts somebody will
/// paste into the protocol reference, and a paragraph the terminal broke mid-word
/// is a paragraph that arrives there mangled.
func wrappedForTranscript(_ text: String, indent: String, width: Int = 76) -> String {
    var lines: [String] = []
    var current = ""
    for word in text.split(whereSeparator: \.isWhitespace) {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count <= width {
            current += " " + word
        } else {
            lines.append(current)
            current = String(word)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines.map { indent + $0 }.joined(separator: "\n")
}

/// Renders one recording's `WiFiSessionUse` as the finding it is.
private func sessionUseLine(_ use: WiFiSessionUse) -> String {
    switch use {
    case .openedSession:
        return "OPENED    — the full handshake, the join, and the association wait"
    case .reusedSession:
        return "REUSED    — served on the session an earlier recording opened: "
             + "no second join, no second handshake"
    case .restartedSession(let refusal):
        return "RESTARTED — the device would not serve this recording on the live session, "
             + "so it was torn down and reopened.\n              refusal: \(refusal)"
    case .restartedAfterReuseBroke(let interruption, let discarded):
        // The 2026-07-30 shape, and the informative one: the device DID serve
        // the second selection. Both halves have to be on the line or the
        // transcript reads as a plain refusal, which it is not.
        return "RESTARTED — the device SERVED this recording on the live session and the "
             + "transfer then failed.\n              interruption: \(interruption)"
             + "\n              \(discarded) partial byte(s) were discarded; the recording was "
             + "fetched again from byte zero\n              on a session of its own"
    case .ownSession:
        return "OWN       — reuse was already ruled out this run, so this recording "
             + "opened its own session"
    }
}

/// `pocket-cli sync-wifi <date> [count]` — fetch several recordings from one
/// day over ONE access-point session and report, per recording, whether the
/// session was reused or had to be restarted.
///
/// The device is already connected and authenticated; the caller owns the event
/// printer, so unmatched frames and the TCP trailer still surface as usual.
func runWiFiBatchSync(device: PocketDevice, date: String, count: Int) async throws {
    // Through `lookUpRecordings`, never `listRecordings`: this call site is where
    // `sync-wifi 20260728 2` reported "no recordings on 20260728" about a device
    // holding eight of them. A malformed date is refused before a frame is sent,
    // and an empty well-formed date is answered with the dates that DO exist —
    // one extra round trip on a path that is about to open an access point.
    let lookup = try await timed("lookUpRecordings \(date)") {
        try await device.lookUpRecordings(forDate: date)
    }
    let day: String
    let listed: [RecordingInfo]
    switch lookup {
    case .found(let normalized, let recordings):
        (day, listed) = (normalized, recordings)
    case .empty(_, let explanation):
        print(explanation)
        return
    case .refused(let reason):
        // Unreachable via the CLI, which refuses the same argument before it
        // connects; printed rather than assumed away.
        print("error: \(reason)")
        return
    }
    let recordings = Array(listed.prefix(count))
    let totalKB = recordings.reduce(0) { $0 + $1.estimatedBytes } / 1024
    // A backlog sync is where this matters, and those totals run to hundreds of
    // megabytes — "~354000 KB" is not a readable number.
    let totalSize = totalKB >= 1024 ? "~\(totalKB / 1024) MB" : "~\(totalKB) KB"

    print("""

    sync-wifi: \(recordings.count) of \(listed.count) recording(s) on \(day), \
    \(totalSize) estimated,
      over ONE access-point session instead of one per recording.

      THIS IS THE PART HARDWARE IS STILL SETTLING. On 2026-07-30 the device DID
      serve a second APP&U&<date>&<ts> on a live access point — it took a second
      TCP connection and announced the next file's length — and the stream then
      reset mid-transfer. So it does not refuse reuse, and reuse does not yet
      work. The run attempts it and falls back to a session opened for that
      recording whenever it is refused OR interrupted, discarding any partial
      bytes: a batch never delivers fewer recordings than the same list fetched
      one at a time would, and the worst case is exactly what
      `pocket-cli download … wifi` does today, once per file.

      Watch the "session:" line under each recording. That is the experiment.
      On this Mac the join is manual, so you should be asked to join the network
      ONCE if reuse works, and once per recording if it does not.

    """)
    if recordings.count < 2 {
        print("note: only one recording will be transferred, which cannot exercise reuse — "
              + "pass a count of 2 or more for a meaningful run\n")
    }

    // Progress is printed per recording; the fraction arrives on the transfer's
    // own executor, so the last-printed recording is tracked under a lock.
    let progress = BatchProgressPrinter(recordings: recordings)
    let runStart = ContinuousClock.now
    let result = try await device.downloadOverWiFi(
        recordings,
        into: .files { URL(fileURLWithPath: "\($0.id.timestamp).mp3") },
        onProgress: { id, fraction in progress.report(id, fraction) })
    let elapsed = ContinuousClock.now - runStart
    progress.finish()

    print("\nper recording:")
    for (index, outcome) in result.delivered.enumerated() {
        let path = "\(outcome.recording.id.timestamp).mp3"
        // Read the size back off the validated file rather than trusting the
        // announcement — the same eyeball check `download` prints.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let onDisk = (attributes?[.size] as? Int) ?? 0
        print("""
          [\(index + 1)/\(recordings.count)] \(outcome.recording.id.timestamp)  \
        \(outcome.recording.durationSeconds) s
              session: \(sessionUseLine(outcome.sessionUse))
              wrote \(path): \(onDisk) bytes (announced \(outcome.byteCount))
        """)
    }

    if let stopped = result.stopped {
        print("\n  STOPPED on \(stopped.recording.id.timestamp)")
        // The recording the run stopped on carries a finding too, and on
        // 2026-07-30 it carried the only interesting one in the whole run. A
        // stop that hides it is how that transcript came to print INCONCLUSIVE
        // under a log of reuse being served.
        if let use = stopped.sessionUse {
            print("      session: \(sessionUseLine(use))")
        }
        // The reason is a paragraph now, not a line: a failed Wi-Fi transfer's
        // diagnosis rides in it. That is the whole point — the 2026-07-28
        // transcript of this command showed `wifi tcp connect timed out after
        // 30.0 seconds` and nothing else, while the code that could have named the
        // cause was one call away — so it is wrapped rather than run off the edge
        // of the terminal.
        print(wrappedForTranscript(stopped.reason, indent: "    "))
        print("""
            \(result.delivered.count) recording(s) before it were delivered and are on disk —
            a mid-batch failure never discards what already arrived.
            not attempted: \(stopped.remaining.isEmpty
                                ? "none"
                                : stopped.remaining.map(\.id.timestamp).joined(separator: ", "))
        """)
    }

    // The verdict itself lives in the library, next to the result it reads and
    // next to `AccessPointLifetime.verdictText`, because it has been wrong before
    // and an executable target cannot be tested. Wrapped paragraph by paragraph,
    // exactly as `probe-ap-lifetime` renders its own.
    print("\nverdict:")
    for (index, paragraph) in result.reuseVerdictText(elapsed: elapsed)
        .components(separatedBy: "\n\n").enumerated() {
        if index > 0 { print("") }
        print(wrappedForTranscript(paragraph, indent: "  "))
    }
    print("\n  \(result.summary)")
}

/// Prints a per-recording percentage on one rewriting line, starting a new line
/// when the batch moves on to the next recording. Lock-guarded: the fractions
/// arrive off the transfer's executor, not this one.
private final class BatchProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let recordings: [RecordingInfo]
    private var current: RecordingID?

    init(recordings: [RecordingInfo]) { self.recordings = recordings }

    func report(_ id: RecordingID, _ fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        if current != id {
            if current != nil { print("") }   // end the previous \r line
            current = id
        }
        let position = (recordings.firstIndex { $0.id == id }.map { $0 + 1 }) ?? 0
        print(String(format: "\r  [%d/%d] %@  %3.0f%%",
                     position, recordings.count, id.timestamp, fraction * 100),
              terminator: "")
        fflush(stdout)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if current != nil { print(""); current = nil }
    }
}
