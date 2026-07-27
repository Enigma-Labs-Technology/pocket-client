// pocket-client/Sources/PocketClient/Session/TransferSink.swift
import Foundation

/// Where one transfer's payload bytes land as they arrive, plus the
/// integrity rules every download path shares. Exactly one instance per
/// transfer attempt; BLE bulk and WiFi TCP feed the same implementation, so
/// the announced-byte-count rule and the FF F3 sync check cannot drift
/// between transports or between the in-memory and streaming shapes.
///
/// - The MP3 sync word (`FF F3`) is captured from the FIRST bytes as they
///   arrive: a file destination cannot cheaply re-read the whole payload
///   after the fact. The verdict is still delivered in `finalize`, after
///   the byte-count check — the same error precedence the original
///   whole-payload validation had.
/// - The exact announced byte count is checked in `finalize`;
///   completion elsewhere remains byte-count driven with `MCU&OFF` a hint.
/// - A file destination becomes visible at its real path ONLY after both
///   checks pass: bytes stream into a dot-prefixed `.partial-<uuid>`
///   companion in the destination's own directory (same volume, so the
///   final move is an atomic rename) and `abort()` removes it on every
///   failure path. A half-written file that looks like a recording is worse
///   than no file — and a pre-existing file at the destination is replaced
///   only by a fully validated download, never damaged by a failed one.
///
/// Lock-guarded, not an actor, for the same reason as `TransferBuffer`:
/// producers (the session actor's bulk sink, the TCP reader loop) deliver
/// chunks synchronously in stream order and must not hop through a task.
final class TransferSink: @unchecked Sendable {
    private let lock = NSLock()
    /// Non-nil ⇔ memory destination: the payload accumulates here.
    private var memory: Data?
    /// Non-nil ⇔ file destination with the temp file still open.
    private var handle: FileHandle?
    private let temp: URL?
    private let destination: URL?
    /// Every payload byte offered, INCLUDING bytes skipped after a write
    /// failure — the count check must report what the wire delivered.
    private var received = 0
    /// The first two payload bytes, captured for the sync check.
    private var header = Data()
    /// First write failure (e.g. disk full). Later writes are skipped —
    /// the file is already doomed — and the error surfaces in `finalize`.
    private var writeFailure: Error?
    /// Set by `finalize`/`abort`; a straggler chunk after either is dropped.
    private var closed = false

    private init(memory: Data?, handle: FileHandle?, temp: URL?, destination: URL?) {
        self.memory = memory
        self.handle = handle
        self.temp = temp
        self.destination = destination
    }

    /// A sink that accumulates the payload and returns it from `finalize` —
    /// the in-memory download shape.
    static func memory() -> TransferSink {
        TransferSink(memory: Data(), handle: nil, temp: nil, destination: nil)
    }

    /// A sink that streams the payload to disk. The temp companion lives in
    /// the destination's own directory — guaranteeing the same volume, hence
    /// an atomic rename in `finalize` — and its `.name.partial-<uuid>` shape
    /// is unmistakably not a recording if a crashed process ever strands it.
    static func file(destination: URL) throws -> TransferSink {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw PocketError.transferFailed("cannot create \(temp.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            return TransferSink(memory: nil, handle: handle, temp: temp, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw PocketError.transferFailed("cannot open \(temp.path): \(error)")
        }
    }

    /// Total payload bytes offered so far — the transfer's ground truth for
    /// progress and byte-count-driven completion.
    var bytesReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    /// Consumes the next payload chunk, in stream order. Never throws: the
    /// producers cannot propagate an error mid-stream (the bulk sink is a
    /// synchronous callback on the session actor), so a write failure is
    /// recorded here and surfaced by `finalize` instead.
    func consume(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }   // straggler after finalize/abort
        received += chunk.count
        if header.count < 2 { header.append(contentsOf: chunk.prefix(2 - header.count)) }
        guard writeFailure == nil else { return }   // doomed; keep counting only
        if memory != nil {
            memory?.append(chunk)
        } else if let handle {
            do { try handle.write(contentsOf: chunk) }
            catch { writeFailure = PocketError.transferFailed("cannot write transfer bytes: \(error)") }
        }
    }

    /// Runs the shared integrity rules and, only after they pass, publishes
    /// a file destination at its real path (atomic rename; an existing file
    /// is replaced, matching what `Data.write(to:)` gave in-memory callers).
    /// Returns the payload for memory destinations, nil for file ones.
    /// On ANY throw nothing was published — the caller must `abort()`.
    func finalize(announced: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let writeFailure { throw writeFailure }
        // Byte count first, then sync — the order the original whole-payload
        // validation applied, so every failure keeps its established story
        // (a truncated junk payload is a truncation, not "not MP3").
        guard received == announced else {
            throw PocketError.sizeMismatch(expected: announced, received: received)
        }
        guard header.count >= 2, header[header.startIndex] == 0xFF,
              header[header.index(after: header.startIndex)] == 0xF3 else {
            throw PocketError.notMP3
        }
        closed = true
        if let memory { return memory }
        guard let handle, let temp, let destination else {
            throw PocketError.transferFailed("internal: sink has neither memory nor file storage")
        }
        self.handle = nil
        do {
            try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            throw PocketError.transferFailed("cannot publish \(destination.path): \(error)")
        }
        return nil
    }

    /// Destroys the partial state: closes the temp handle and removes the
    /// temp file. Idempotent, and safe after a successful `finalize` — the
    /// temp no longer exists then, and the published file is never touched.
    /// Every failure exit of a transfer (throw or cancellation) runs this.
    func abort() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        if let handle {
            self.handle = nil
            try? handle.close()
        }
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }
}
