// pocket-client/Tests/PocketClientTests/Support/InterfacePinningFakes.swift
//
// The seam the interface pin is held through, from the test side — plus the one
// probe that decides whether the two checks needing a *real* `NWInterface` can
// run here at all.
import Foundation
import Network
import Testing
@testable import PocketClient

/// A `WiFiInterfacePinning` that answers from a list written down here instead
/// of from Network.framework, and records what it was asked.
///
/// `NWInterface` has no public initializer, so this cannot set
/// `requiredInterface` and does not pretend to. It marks the parameters it was
/// handed instead, which is what lets a test prove the object the pin was applied
/// to is the object the socket was opened with. That is the property a revert to
/// `NWConnection(to: endpoint, using: .tcp)` breaks, and it is checked without
/// asking this machine for anything.
final class ListedInterfacePinning: WiFiInterfacePinning, @unchecked Sendable {
    /// The mark this fake leaves on parameters it required an interface of:
    /// `allowLocalEndpointReuse`, chosen because nothing in this package sets it
    /// and it changes nothing about an outbound connect — the fake must be
    /// visible without being consequential. `NWParameters.tcp` leaves it false, so
    /// true means this fake, and only this fake, reached that object.
    static func isMarked(_ parameters: NWParameters) -> Bool {
        parameters.allowLocalEndpointReuse
    }

    private let lock = NSLock()
    private let listed: [String]
    private var requests: [(name: String, bound: Duration)] = []
    private var parameters: NWParameters?

    /// `listing` is what Network.framework would answer here. Empty is the
    /// interesting case as often as not: it is what a CI runner presents, and
    /// what every loopback transfer in this suite gets, since loopback is
    /// legitimately absent from that list.
    init(listing listed: [String]) { self.listed = listed }

    func requireInterface(named name: String, of parameters: NWParameters,
                          within bound: Duration) async -> String? {
        record(name: name, bound: bound, parameters: parameters)
        guard listed.contains(name) else { return nil }
        parameters.allowLocalEndpointReuse = true
        return name
    }

    /// Synchronous, like the joiners here: `NSLock.lock()` is `noasync`.
    private func record(name: String, bound: Duration, parameters: NWParameters) {
        lock.lock()
        requests.append((name: name, bound: bound))
        self.parameters = parameters
        lock.unlock()
    }

    /// Every `requireInterface` call, in order.
    var asked: [(name: String, bound: Duration)] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    /// The parameters object handed to the most recent call, by identity.
    var handedParameters: NWParameters? {
        lock.lock(); defer { lock.unlock() }; return parameters
    }
}

/// What Network.framework lists on *this* host, probed once per process.
///
/// A host that lists nothing at all is ordinary rather than broken — a
/// virtualised CI runner lists nothing — so the two checks that genuinely need a
/// real `NWInterface` are **skipped** there: never faked green, never reported as
/// a failure, and always with a message saying what went unexercised. Exactly the
/// shape `SessionKeyStoreTests` uses for the data protection keychain on an
/// unsigned test runner.
///
/// A skip is only honest if it is not the coverage. It is not: the pin's whole
/// decision is held by hermetic tests that never consult this, and what remains
/// behind the skip is one thing — that the SDK enforces `requiredInterface` on a
/// socket. See `WiFiInterfacePinning`.
enum ListedInterfaceProbe {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var listed: [(name: String, isLoopback: Bool)] = []
        func record(_ found: [(name: String, isLoopback: Bool)]) {
            lock.lock(); listed = found; lock.unlock()
        }
        var value: [(name: String, isLoopback: Bool)] {
            lock.lock(); defer { lock.unlock() }; return listed
        }
    }

    /// Resolved once, off this thread, with a hard stop: a probe that cannot
    /// answer reports an empty list, which skips — it never hangs the suite.
    static let listed: [(name: String, isLoopback: Bool)] = {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let interfaces = await HostInterfaces.availableInterfaces(
                within: WiFiReadiness.maximumInterfaceSnapshotWait)
            box.record(interfaces.map { (name: $0.name, isLoopback: $0.type == .loopback) })
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            print("WiFiTransferTests: the interface probe did not answer in 5 s; "
                  + "treating this host as listing none and skipping the checks that need one.")
        }
        return box.value
    }()

    static var listsAnInterface: Bool { !listed.isEmpty }
    static var listsANonLoopbackInterface: Bool { listed.contains { !$0.isLoopback } }
}

/// Network.framework lists at least one interface here.
let requiresAListedInterface: ConditionTrait = .enabled(
    if: ListedInterfaceProbe.listsAnInterface,
    Comment(rawValue:
        "Network.framework lists no interface on this host (a virtualised CI runner lists none), "
        + "so the SDK's own enforcement of requiredInterface is not exercised here — the pin's "
        + "decision is held hermetically by "
        + "theConnectOpensTheSocketWithTheVeryParametersThePinWasAppliedTo and "
        + "theConnectReportsTheInterfaceThePinnerRequired, which do not consult this host"))

/// …and at least one of them is not loopback, so an applied pin can be told
/// apart from an unapplied one on a loopback destination.
let requiresANonLoopbackListedInterface: ConditionTrait = .enabled(
    if: ListedInterfaceProbe.listsANonLoopbackInterface,
    Comment(rawValue:
        "Network.framework lists no non-loopback interface on this host (a virtualised CI runner "
        + "lists none), so a pin that was applied cannot be told apart from one that was not — "
        + "the hermetic pair named above holds that distinction instead"))
