// pocket-client/Tests/PocketClientTests/Support/AsyncGate.swift
import Foundation

/// One-shot latch: `wait()` suspends until `open()`; both orders are safe.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let resumable = waiters
        waiters = []
        lock.unlock()
        for waiter in resumable { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
