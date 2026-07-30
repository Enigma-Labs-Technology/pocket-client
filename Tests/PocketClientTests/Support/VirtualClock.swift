// pocket-client/Tests/PocketClientTests/Support/VirtualClock.swift
//
// The clock the hermetic tests hand to code whose guarantee is a *duration*.
import Foundation
import Testing

/// A `Clock` that answers `sleep` by moving itself forward instead of by
/// waiting. Time passes exactly as much as it is asked to, and no faster or
/// slower than that.
///
/// **Why this exists.** Several things in this package promise a duration: the
/// WiFi pre-flight answers a host that is simply elsewhere inside
/// `hostAddressWait` and holds on for the full `timeout` while DHCP is still
/// being refused; the bounded `NWPathMonitor` poll gives up at its bound rather
/// than holding a transfer behind a monitor with nothing to say. A test that
/// checks one of those by reading `ContinuousClock` around a call that really
/// sleeps is not testing the promise — it is testing how loaded the machine
/// running it happens to be, and it goes red on a busy CI runner while the code
/// under it is perfectly correct. That is exactly what happened: a 250 ms bound
/// measured 353 ms on a GitHub runner, and no amount of widening the bound fixes
/// a test of the wrong thing.
///
/// So the clock comes out of the test. `elapsed` is then the *budget the code
/// spent*, to the microsecond, and the assertions are equalities rather than
/// generous inequalities. Nothing here sleeps, so the tests are also faster.
///
/// `sleep` yields once so a virtual sleep is still a suspension point — code
/// under test that relies on other tasks making progress across it still gets
/// that — and it honours cancellation, which `resolveWiFiPathPin` depends on.
final class VirtualClock: Clock, @unchecked Sendable {
    /// An offset from the clock's own zero. Only differences are meaningful,
    /// which is all `ContinuousClock.Instant` promises either.
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Duration.zero

    /// Zero: this clock has no granularity to lose.
    var minimumResolution: Duration { .zero }

    var now: Instant { lock.lock(); defer { lock.unlock() }; return Instant(offset: current) }

    /// How much time the code under test has asked for since this clock was made.
    var elapsed: Duration { now.offset }

    /// Never backwards — a deadline already in the past leaves the clock alone,
    /// exactly as a real one would.
    ///
    /// Synchronous because `NSLock.lock()` is `noasync`; `sleep` reaches the lock
    /// through here, the same shape the joiners in this suite use.
    private func advance(to offset: Duration) {
        lock.lock()
        if current < offset { current = offset }
        lock.unlock()
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        advance(to: deadline.offset)
        await Task.yield()
    }
}
