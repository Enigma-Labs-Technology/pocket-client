// pocket-client/Sources/pocket-cli/BatchSync.swift
//
// `pocket-cli sync-wifi` — the hardware experiment for one access-point session
// per SYNC rather than one per recording.
//
// This exists because the interesting part of that feature cannot be tested
// without a device. Whether the recorder will serve a second
// `APP&U&<date>&<ts>` while its access point is still up has never been
// observed: the packet capture the protocol was decoded from covered a
// single-file sync. `PocketSession.downloadOverWiFi(_ recordings:…)` therefore
// attempts reuse and falls back to one session per recording the moment the
// device refuses, and this command's output is how we find out which happened.
//
// So the per-recording `session:` lines below are not progress decoration —
// they ARE the result. Capture the transcript.

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
    let listed = try await timed("listRecordings \(date)") {
        try await device.listRecordings(on: date)
    }
    guard !listed.isEmpty else {
        print("no recordings on \(date) — nothing to sync (try `pocket-cli list`)")
        return
    }
    let recordings = Array(listed.prefix(count))
    let totalKB = recordings.reduce(0) { $0 + $1.estimatedBytes } / 1024
    // A backlog sync is where this matters, and those totals run to hundreds of
    // megabytes — "~354000 KB" is not a readable number.
    let totalSize = totalKB >= 1024 ? "~\(totalKB / 1024) MB" : "~\(totalKB) KB"

    print("""

    sync-wifi: \(recordings.count) of \(listed.count) recording(s) on \(date), \
    \(totalSize) estimated,
      over ONE access-point session instead of one per recording.

      THIS IS THE UNVERIFIED PART. Nobody has issued a second APP&U&<date>&<ts>
      while the AP was still up, so the device may serve it, refuse it, or do
      something else. The run attempts reuse and falls back to one session per
      recording the moment it is refused — the worst case is exactly what
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

    // The verdict. Only three things can be said honestly, and which one it is
    // depends entirely on what the device did.
    print("\nverdict:")
    if result.didReuseSession {
        print("""
          SESSION REUSE WORKS on this firmware.
            \(result.delivered.count) recording(s) came off the device over \
        \(result.sessionsOpened) access-point session(s)
            in \(milliseconds(elapsed)) ms. The device DID serve a second \
        APP&U&<date>&<ts> while its
            AP was up — which is what has never been observed before.
            Promote the capability from `unverified` in docs/protocol/ble-protocol.md
            and the README, and record this transcript as the evidence.
        """)
    } else if let refusal = result.refusals.first {
        print("""
          SESSION REUSE IS REFUSED on this firmware.
            The device would not serve a recording on a live session:
              \(refusal)
            The run fell back to one session per recording — \
        \(result.sessionsOpened) session(s) for
            \(result.delivered.count) recording(s), in \(milliseconds(elapsed)) ms — \
        which is exactly the
            pre-existing behaviour. Nothing was lost and no access point was left up.
            Record the refusal in docs/protocol/ble-protocol.md: it settles the open
            question in the negative, which is just as useful an answer.
        """)
    } else {
        print("""
          INCONCLUSIVE — no recording was ever asked to reuse a session.
            \(result.delivered.count) recording(s) delivered over \
        \(result.sessionsOpened) session(s). Reuse is only exercised
            from the SECOND recording onwards, and only if the first one succeeds,
            so run this again with two or more transferable recordings.
        """)
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
