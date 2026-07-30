// pocket-client/Sources/PocketClient/Transport/WiFiTransfer.swift
import Foundation
import Network
#if os(iOS)
import NetworkExtension
#endif

/// Joining the recorder's access point. iOS can do this programmatically;
/// macOS asks the operator to join manually (the CLI prints instructions).
public protocol HotspotJoining: Sendable {
    func join(ssid: String, passphrase: String) async throws
    func leave() async
}

/// Joins programmatically on iOS. Requires the Hotspot Configuration
/// entitlement in the consuming app (Plan 3), not in this package.
///
/// A class, not a struct: `leave()` must remove the configuration for the
/// SSID that `join` actually applied, so the joined SSID is recorded under a
/// lock (join and leave can run on different tasks).
///
/// Fast in practice — seconds — which is the only reason the phone path never hit
/// the failure the macOS one did. It is not fast by construction: `apply` puts up
/// the system *"wants to join Wi-Fi network"* alert and returns when the person
/// answers it, which is the same shape of wait as the manual joiner's, just
/// usually shorter. It needs no protection of its own because
/// `openWiFiSession` starts the session keepalive before calling **any**
/// `HotspotJoining` — this one, the manual one, or a consumer's.
public final class SystemHotspotJoiner: HotspotJoining, @unchecked Sendable {
    private let lock = NSLock()
    private var joinedSSID: String?

    public init() {}

    // Synchronous accessors: NSLock's lock()/unlock() are `noasync` on the
    // iOS SDK, so async methods must reach the lock through sync helpers.
    private func recordJoined(_ ssid: String) {
        lock.lock(); joinedSSID = ssid; lock.unlock()
    }

    private func takeJoinedSSID() -> String? {
        lock.lock(); defer { lock.unlock() }
        let ssid = joinedSSID
        joinedSSID = nil
        return ssid
    }

    public func join(ssid: String, passphrase: String) async throws {
        #if os(iOS)
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        configuration.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
            recordJoined(ssid)
        } catch {
            // `alreadyAssociated` means the phone is ALREADY on this AP —
            // that is success, not failure (typical after a half-failed
            // earlier attempt left the association up). Failing it would
            // wrongly abort the retry, silently degrading `.auto` transfers
            // of large files to slow BLE. Record the SSID so `leave()` still
            // removes the configuration afterwards.
            let nsError = error as NSError
            if nsError.domain == NEHotspotConfigurationErrorDomain,
               nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                recordJoined(ssid)
                return
            }
            throw PocketError.wifiJoinFailed(error.localizedDescription)
        }
        #else
        throw PocketError.wifiJoinFailed(
            "macOS cannot join automatically — join SSID \(ssid) with password \(passphrase) manually")
        #endif
    }

    public func leave() async {
        #if os(iOS)
        guard let ssid = takeJoinedSSID() else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }
}

/// The name given to the thread `runOffTheCooperativePool` creates. Read by a
/// test, so the hand-off is proved rather than assumed.
let blockingWorkThreadName = "pocket-client.blocking-work"

/// Runs `work` — which may block its thread for an unbounded time — on a thread
/// of its own, suspending the caller until it returns.
///
/// `ManualHotspotJoiner` is the reason this exists. `readLine()` blocks until the
/// operator presses return, and on 2026-07-28 that was about a minute spent in
/// System Settings. Called straight from an `async` function, that minute is
/// spent holding one of Swift concurrency's cooperative threads — a pool with
/// roughly one thread per core — so the pool can stall, and a keepalive task that
/// is nominally "running concurrently" may not run at all. A ping going out
/// *during* that minute is the whole point (see `startWiFiSessionKeepalive`), so
/// the blocking read has to leave the pool. Nothing here would fail loudly if it
/// did not, which is exactly why it is a named function with a test on it.
///
/// A plain `Thread`, not a `DispatchQueue`: the work blocks for as long as a
/// person takes, and a queue's threads are shared with everything else on it.
///
/// Deliberately **not** cancellable — a blocking read cannot be interrupted, and
/// resuming early would leave the orphaned thread to swallow a later line of
/// stdin. That matches the bare `readLine()` this replaces; nothing regressed.
func runOffTheCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.name = blockingWorkThreadName
        thread.start()
    }
}

/// A joiner for macOS harness runs: prints instructions and waits for the
/// operator to join the AP by hand, then continues.
///
/// This join is a person, and takes as long as a person takes. Everything that
/// has to keep happening meanwhile — the `APP&WPING` keepalive that stops the
/// device's access point idling out from under the transfer — is arranged by
/// `openWiFiSession`, which starts the session keepalive **before** calling any
/// joiner.
public struct ManualHotspotJoiner: HotspotJoining {
    /// How this joiner learns whether a wired link is carrying the default
    /// route. A seam: the real answer comes from `NWPathMonitor` and therefore
    /// from whatever network the machine running the tests happens to be on,
    /// which is exactly what a hermetic test cannot depend on.
    let wiredDefaultRoute: @Sendable () async -> Bool

    public init() {
        self.init(wiredDefaultRoute: { await HostInterfaces.defaultPathIsWired() })
    }

    init(wiredDefaultRoute: @escaping @Sendable () async -> Bool) {
        self.wiredDefaultRoute = wiredDefaultRoute
    }

    /// The text the operator is shown, as a value rather than as stdout, so a
    /// test can read what they are about to be told.
    ///
    /// The Ethernet paragraph leads when it applies, because that is the one
    /// thing on this screen that has to be acted on *before* touching Wi-Fi
    /// settings — see `HostInterfaces.defaultPathIsWired` for what it cost.
    ///
    /// The password paragraph is not hypothetical either: on 2026-07-28 this
    /// path printed the correct post-rotation password and the operator still
    /// joined with the one the Mac remembered, because macOS matches a known
    /// network by SSID and never asks again. The AP password follows the session
    /// key (`key[:8]`), so every rotation invalidates it on every host that has
    /// joined before — and the only symptom reaching this process was a TCP
    /// connect that timed out.
    static func instructions(ssid: String, passphrase: String,
                             wiredDefaultRoute: Bool) -> String {
        let wired = wiredDefaultRoute ? """

          0. UNPLUG ETHERNET FIRST. A wired link is carrying this Mac's default
             route, and \(ssid) offers no internet. On 2026-07-30 that combination
             made macOS associate with the recorder and then silently DROP the
             association — while keeping the address, the route and the ARP entry,
             so everything here still looked joined and nothing could reach the
             device. Unplugging the cable is what made the transfer work. Plug it
             back in when the sync is done.
        """ : ""
        return """

        ACTION REQUIRED — the recorder's WiFi access point is now up.
        \(wired)
          1. Open System Settings > Wi-Fi on THIS Mac.
          2. Join the network named:  \(ssid)
             using the password:      \(passphrase)
             If this Mac has joined \(ssid) before AND the device's session key
             has been rotated since, macOS will silently reuse the OLD password
             and report only that it cannot join. Forget the network first —
             System Settings > Wi-Fi > Advanced…, Known Networks — then join
             with the password above.
          3. Once connected, come back here and press return to start the transfer.
        (Bluetooth control stays up; only the file bytes travel over WiFi.)
        waiting for return…
        """
    }

    public func join(ssid: String, passphrase: String) async throws {
        // Read before printing, so the warning is part of the instructions
        // rather than a line racing them from an event stream. Bounded by
        // `maximumInterfaceSnapshotWait`, and a monitor that never reports just
        // omits the paragraph.
        let wired = await wiredDefaultRoute()
        print(Self.instructions(ssid: ssid, passphrase: passphrase, wiredDefaultRoute: wired))
        // Off the cooperative pool. `readLine()` blocks its thread for as long
        // as the operator takes, and the session keepalive that is now running
        // behind this call needs a thread to run on — see
        // `runOffTheCooperativePool`.
        _ = await runOffTheCooperativePool { readLine() }
    }
    public func leave() async {
        // Runs on failure paths too, so it must not claim success.
        print("wifi step finished — you may rejoin your normal WiFi network now")
    }
}

/// What this package can say about a failed access-point join that the OS will
/// not say.
///
/// Both platforms report a join failure as one opaque line — iOS as the system
/// alert *"Unable to join the network <ssid>"*, macOS (where the join is
/// manual) as nothing at all, just a TCP connect that never completes. Neither
/// distinguishes a wrong password from an access point that is down, and on
/// 2026-07-28 that ambiguity took three hardware probes to resolve.
///
/// The package holds one fact the OS does not: the session key. The AP password
/// is the key's first `passphraseLength` characters
/// (`docs/protocol/ble-protocol.md`, Wi-Fi Quick Transfer step 3), and a rebind
/// propagates into it — VERIFIED on hardware. So comparing the key against the
/// password the device just reported over BLE settles whether the *device* is
/// self-consistent, and that is what decides where to look next: if it is, the
/// credentials offered to the OS were right and the fault is on this host.
///
/// Neither password appears in the guidance text. The reported one is a live
/// credential and the derived one is eight characters of the session key, so
/// the copy states only whether they agree — which keeps the error safe to
/// paste into a bug report.
enum WiFiJoinDiagnosis: Equatable, Sendable, CaseIterable {
    /// The device's reported AP password is exactly what this session's key
    /// implies. The device is self-consistent, so the credentials handed to the
    /// OS were correct and what remains is this host: in practice a saved
    /// network still holding the pre-rotation password.
    case deviceCredentialsCurrent
    /// The device reported a password that is **not** this key's first
    /// `passphraseLength` characters. Informative, never an error: the join used
    /// the device's value, which is authoritative, and the disagreement is a
    /// finding about this firmware's derivation rather than this failure's cause.
    case reportedPassphraseDiffers
    /// No comparison was possible — this session's key is shorter than the
    /// password itself. Real keys are `PocketKey.length`; only a hand-made
    /// short key reaches this.
    case notComparable

    /// The documented derivation: AP password = the session key's first 8 chars.
    static let passphraseLength = 8

    static func of(reportedPassphrase: String, derivedFromKey: String?) -> WiFiJoinDiagnosis {
        guard let derivedFromKey else { return .notComparable }
        return reportedPassphrase == derivedFromKey
            ? .deviceCredentialsCurrent
            : .reportedPassphraseDiffers
    }

    /// Reads after the failure text, in the register the rest of the package
    /// uses: what is known, then what to do about it.
    func guidance(ssid: String) -> String {
        // Shared tail — the repair is the same whatever the comparison said,
        // and it is the only repair there is.
        let hostSideRepair =
            "A password this host saved for \(ssid) before the session key was rotated is the "
            + "likely cause: the OS re-offers it silently and reports only that it cannot join. "
            + "Forget \(ssid) in Wi-Fi settings — macOS: System Settings > Wi-Fi > Advanced…, "
            + "Known Networks; iOS: Settings > Wi-Fi > the network's info button > Forget This "
            + "Network — then run this again. Neither iOS nor macOS exposes an API that can "
            + "remove a network the user saved, so nothing here can do it for you."
        switch self {
        case .deviceCredentialsCurrent:
            return "the AP password the device reported is exactly what this session's key "
                + "implies, so the device's own credentials are current. " + hostSideRepair
        case .reportedPassphraseDiffers:
            return "the AP password the device reported is not this session key's first "
                + "\(Self.passphraseLength) characters, which is the documented derivation — the "
                + "join used the device's value, which is authoritative, so that disagreement is "
                + "a firmware finding to record, not this failure's cause. " + hostSideRepair
        case .notComparable:
            return "this session's key is shorter than the \(Self.passphraseLength)-character AP "
                + "password, so the reported password could not be checked against it. "
                + hostSideRepair
        }
    }
}

/// What this package can say about a TCP connect that never completed.
///
/// Two causes have been proposed for the macOS failure and eliminated on
/// hardware: the access point's lifetime (measured 2026-07-29: ~59 s unassisted,
/// still up at the 180 s cap with `APP&WPING` every 10 s, and the keepalive now
/// starts on the `MCU&WIFIO` ack and pings through the connect itself), and the
/// device's listener not existing (the capture shows the official app's SYN
/// *preceding* its `APP&U&…` selection). Guessing again is not the plan. So this
/// reasons from evidence rather than from elimination:
///
/// 1. **This host's own routing configuration.** The device's address is a fixed
///    constant on a directly-connected `/24`, so no interface holding an address
///    on that `/24` means no route to the device exists and the connect cannot
///    succeed. The converse does **not** hold: an interface holding one is
///    configured to reach the device, which is not the same as being associated
///    with its access point — see `HostInterfaceAddress`.
/// 2. **The interface's link state.** `IFF_RUNNING`, from the same enumeration.
///    Clear means the interface is carrying no link, which contradicts the
///    address outright.
/// 3. **Network.framework's own reason.** `.waiting(NWError)` carries why the
///    path is not usable, and the state handler used to discard it. That
///    discarded value is why the cause was guessed at repeatedly — and on
///    2026-07-30 it was `ENETDOWN` throughout, which was accurate while this
///    package's own prose was not.
///
/// A diagnosis that confidently names the wrong cause is worse than a bare error.
/// That cuts both ways, and this type has been wrong in both directions: the
/// credential story is told only where the evidence is consistent with it (this
/// host holding nothing on the device's subnet, which is what a silently rejected
/// join looks like from here), and no verdict here declares the association,
/// the credentials or the access point's lifetime *settled* on the strength of an
/// address, because an address does not settle any of them.
enum WiFiConnectDiagnosis: Equatable, Sendable {
    /// No interface on this host holds an address on the device's subnet, so this
    /// host is not on the access point — whatever the device reported about some
    /// client. The strongest verdict available, and the only one that is about
    /// this process rather than about the device's view of the world.
    case hostNotOnTheAccessPoint(WiFiJoinDiagnosis)
    /// No interface holds an address on the device's subnet, but one holds a
    /// self-assigned `169.254` address — so this host **did** associate with an
    /// access point and DHCP never answered it. The join worked and the lease did
    /// not, which is a different failure with a different repair: renewing the
    /// lease, not forgetting a password that was accepted.
    case joinedButNeverLeased(interface: String)
    /// An interface holds an address on the device's subnet, its link is
    /// running, and the socket still never opened. Nothing here contradicts the
    /// address, so the subject is the path from this process to the device —
    /// carrying whatever reason Network.framework last gave for not being able to
    /// take it, or the fact that it gave none.
    /// `interfaceWasRequired` decides where the reader is sent next, and getting
    /// it wrong is how a diagnosis misattributes: if the connection really was
    /// constrained to that interface, then no VPN or default route can have
    /// captured it and blaming one would be false.
    case pathUnusableFromThisHost(interface: String, address: String,
                                  interfaceWasRequired: Bool, waitingReason: String?)
    /// An interface holds an address on the device's subnet and something
    /// **contradicts** it: the link under it is not running, or Network.framework
    /// reported the network down for a connection it was required to carry there.
    /// The address is a leftover, not an association.
    ///
    /// This case exists because its absence produced a confidently false
    /// diagnosis. Until 2026-07-30 an address on the device's `/24` was reported
    /// as proof that "the association and the credentials are settled and out of
    /// the picture, and so is the access point's lifetime, because a device that
    /// had closed its AP would not still be leasing this address". Every clause
    /// after the first was wrong: macOS retains address, netmask, route and ARP
    /// cache after disassociating, the retained address is not a lease the device
    /// is still granting, and the failing host had exactly this configuration
    /// while `networksetup` reported it not associated.
    case addressWithoutAnAssociation(interface: String, address: String, contradiction: String)
    /// The device reported its WiFi **off** (`MCU&WIFIS&0`) while this client was
    /// still waiting for the association: the access point came down on its own,
    /// and no credential ever got the chance to be wrong.
    case accessPointClosedItself
    /// The device reported a client on its AP (`MCU&WIFIS&2`, or `1` which
    /// subsumes it), the socket never opened, and this host's interfaces could
    /// not be checked against the endpoint — reached only when a caller overrode
    /// the endpoint with something that is not an IPv4 host:port, since
    /// `WiFiEndpoint.default` always is. The device's report is then all there is.
    case associatedThenUnreachable
    /// The device kept reporting its AP up with nothing on it (`MCU&WIFIS&3`, and
    /// never `2`), and — as above — there was no interface evidence to prefer to
    /// it. The shape a stale saved password makes.
    case nothingEverJoined(WiFiJoinDiagnosis)

    /// What is known about the access point's lifetime, for the one verdict where
    /// the device itself said the AP had gone: it is measured, not feared, and it
    /// is no longer a hypothesis about this failure. Says nothing about saved
    /// passwords — the device's own report rules that story out here, and
    /// repeating it anyway is how a diagnosis starts costing more than it saves.
    private static func lifetimeRepair(ssid: String) -> String {
        "The access point's lifetime is measured, not a mystery: on 2026-07-29 an unassisted AP "
        + "lasted about 59 s, while one held with APP&WPING every 10 s was still up at the 180 s "
        + "cap. This session pings from the MCU&WIFIO ack onwards — through the join and through "
        + "this connect — so an access point that went away anyway went away for some other "
        + "reason: the device rebooting, its WiFi switched off at the device, or another client "
        + "taking the session. Rejoin \(ssid) and run this again; if it repeats, "
        + "`pocket-cli probe-ap-lifetime` measures the lifetime directly. The host-side "
        + "signature, for the record: `ifconfig` still showing a \(WiFiEndpoint.clientSubnet) "
        + "address while `ping \(WiFiEndpoint.deviceHost)` answers `No route to host`. That "
        + "address is a leftover this host keeps — macOS does not drop the address, the route "
        + "or the ARP entry when the access point goes away — and not a lease the device is "
        + "still granting."
    }

    /// The repair that cost a whole debugging session to find, attached wherever
    /// the evidence says this host is holding a configuration it is no longer
    /// associated to. Hardware, 2026-07-30.
    private static let wiredEthernetRepair =
        "If a network cable is plugged into this Mac, unplug it and rejoin: with a wired link "
        + "carrying the default route, macOS associates with the recorder's no-internet access "
        + "point and then drops the association, leaving exactly this configuration behind. "
        + "Unplugging Ethernet is what made the first successful transfer work."

    /// Whether Network.framework's own reason names a network that is down
    /// (`ENETDOWN`, POSIX 50). `WiFiConnectWatcher` records `String(describing:)`
    /// of the `NWError` precisely so the code survives as far as this decision;
    /// both spellings the SDK has produced are matched, and nothing is matched on
    /// the bare number, which appears in unrelated places.
    static func namesADownNetwork(_ reason: String) -> Bool {
        reason.contains("ENETDOWN") || reason.contains("Network is down")
    }

    /// The evidence, if there is any, that an address on the device's subnet is a
    /// leftover rather than a live association — as a clause naming what says so.
    ///
    /// Asymmetric on purpose, and the asymmetry is the whole point. It can
    /// establish that this host is **not** associated; it can never establish
    /// that it is, and `nil` therefore means "nothing contradicted the address",
    /// never "the host has joined". Reading `nil` as an association is exactly
    /// the mistake the 2026-07-30 hardware run exposed, and it is why no verdict
    /// downstream of here calls the association settled.
    ///
    /// Neither source is a shell tool and neither reads an SSID:
    /// `networksetup -getairportnetwork` is a command-line program, not an API,
    /// and SSID reads on current macOS are gated behind Location Services — so a
    /// check built on one would report "not associated" for a permissions reason
    /// and land right back here, only failing in the other direction.
    ///
    /// Pure and static so it can be tested for each piece of evidence
    /// independently of a connect that would have to be provoked on real
    /// hardware to produce them.
    static func contradictionOfAddress(_ held: HostInterfaceAddress,
                                       waitingReason: String?,
                                       interfaceWasRequired: Bool) -> String? {
        if !held.linkIsRunning {
            return "\(held.interfaceName) is UP but not RUNNING — the kernel's own link-level "
                + "flag, so the interface is switched on and carrying no link, which an "
                + "associated Wi-Fi interface never is"
        }
        // The framework's reason, preferred over any inference of ours, because on
        // 2026-07-30 it was accurate throughout while this package's own prose was
        // not. Read only when the constraint was actually applied: unpinned,
        // ENETDOWN could be about some other interface entirely. Pinned, "the
        // destination is not reachable over this interface" is excluded by
        // construction — this interface holds an address on the destination's own
        // /24 — so what is left is the interface not being on a network.
        if interfaceWasRequired, let reason = waitingReason, namesADownNetwork(reason) {
            return "Network.framework reported the network down for a connection it was "
                + "required to carry on \(held.interfaceName) (\(reason)), and that interface "
                + "holds an address on the destination's own /24, so it cannot mean the "
                + "destination is unreachable from it — it means the interface is not on a "
                + "network"
        }
        return nil
    }

    /// Reads after the failure text, in the register the rest of the package
    /// uses: what is known, then what to do about it.
    func guidance(ssid: String) -> String {
        switch self {
        case .hostNotOnTheAccessPoint(let join):
            return "no interface on this host holds an address on the device's subnet, so THIS HOST "
                + "is not on \(ssid) — and that is evidence about this process, which MCU&WIFIS is "
                + "not: the device reports 2 for any associated client, and a Mac auto-joining a "
                + "remembered network satisfies that check while proving nothing about this "
                + "client. Join \(ssid) and run this again. " + join.guidance(ssid: ssid)
        case .joinedButNeverLeased(let interface):
            return "this host holds a self-assigned \(WiFiEndpoint.selfAssignedPrefix).x.x address "
                + "on \(interface) and no address on the device's subnet, which means it DID "
                + "associate with an access point — so the password was accepted — and DHCP never "
                + "answered. The join worked; the lease did not. Do NOT forget \(ssid): the "
                + "credential is not what failed here, and re-entering it would only cost time. "
                + "Renew the lease instead (macOS: System Settings > Wi-Fi > Details… for \(ssid) "
                + "> TCP/IP > Renew DHCP Lease), or leave the network and rejoin it, then run this "
                + "again. If it repeats, the device's DHCP server is the subject: "
                + "`pocket-cli probe-ap-lifetime --keepalive` holds the access point up so this "
                + "can be reproduced without a transfer in the way."
        case .pathUnusableFromThisHost(let interface, let address, let wasRequired,
                                       let waitingReason):
            let reason = waitingReason.map {
                "Network.framework's last reason for not proceeding was: \($0). "
            } ?? "Network.framework never gave a reason at all — the connection sat in .waiting "
                + "without ever saying why, which is what its own path evaluation failing to find "
                + "a usable route looks like, as distinct from a refused connect (immediate) or an "
                + "unreachable host (fast). "
            // Where to look next depends entirely on whether the constraint was
            // actually applied. Naming a VPN when the connection was pinned to
            // \(interface) would be a confident wrong cause — the thing this type
            // exists to avoid.
            let next = wasRequired
                ? "The connection WAS required to use \(interface), so nothing else can have "
                    + "captured this path: a VPN, a mesh client or a default route elsewhere are "
                    + "all excluded by that constraint, and so is any other interface on this "
                    + "host. What is left is between \(interface) and the device — a packet "
                    + "filter on this host, or the device no longer listening on "
                    + "\(WiFiEndpoint.devicePort). "
                : "The connection could NOT be required to use \(interface) (Network.framework "
                    + "does not list it), so it was left unconstrained — and an unconstrained "
                    + "connection is exactly what something else can capture: a VPN or mesh "
                    + "client owning the default route is the first thing to check, then a packet "
                    + "filter, then the device's listener on \(WiFiEndpoint.devicePort). "
            return "this host is CONFIGURED to reach the device directly (\(interface) holds "
                + "\(address) on the device's subnet, and its link is running) and the socket "
                + "still never opened. That configuration is not by itself proof of a live "
                + "association — macOS keeps an address after disassociating — but nothing "
                + "observed here contradicts it, so the subject is the path from this process to "
                + "\(WiFiEndpoint.deviceHost). " + reason + next
                + "From this host, `ifconfig \(interface)` should still show \(address) and "
                + "`nc -vz \(WiFiEndpoint.deviceHost) \(WiFiEndpoint.devicePort)` should connect. "
                + "If it does not, rejoin \(ssid) before looking any further: this client cannot "
                + "tell a live association from a leftover one by looking at addresses."
        case .addressWithoutAnAssociation(let interface, let address, let contradiction):
            return "\(interface) holds \(address) on the device's subnet, but that address is NOT "
                + "evidence that this host is on \(ssid): \(contradiction). macOS keeps the "
                + "address, the netmask, the route and the ARP entry when a Wi-Fi interface "
                + "disassociates, so every run that ever joined \(ssid) leaves one of these "
                + "behind — and it is most misleading exactly when somebody is testing "
                + "repeatedly. Rejoin \(ssid) and run this again. " + Self.wiredEthernetRepair
        case .accessPointClosedItself:
            return "the device reported its WiFi off (MCU&WIFIS&0) while this client was still "
                + "waiting for the association, so the access point came down before anything "
                + "could connect to it — that is the device's doing, not a credential this host "
                + "holds. " + Self.lifetimeRepair(ssid: ssid)
        case .associatedThenUnreachable:
            return "the device DID report a client on its access point (MCU&WIFIS&2), so something "
                + "was associated and its credentials were accepted — nothing about the password "
                + "is in question. This client could not check its own interfaces against the "
                + "endpoint, because the endpoint is not an IPv4 host:port, so the path is what "
                + "remains: give it the device's own address and this error will name the "
                + "interface it required and the reason Network.framework gave."
        case .nothingEverJoined(let join):
            return "the device never reported a client on its AP (no MCU&WIFIS&2), so nothing "
                + "joined \(ssid): " + join.guidance(ssid: ssid)
        }
    }
}

/// Tuning for the post-join readiness wait: the official app polls
/// `APP&WIFIS` about once a second until the device reports the client
/// association (`MCU&WIFIS&2`), then switches to `APP&WPING` keepalives every
/// ~10 s while the phone finishes DHCP and opens TCP (measured from an HCI
/// snoop of one complete app-driven sync).
/// The defaults mirror that cadence; `timeout` bounds both the association
/// wait and the TCP connect.
public struct WiFiReadiness: Sendable {
    public var timeout: Duration
    public var pollInterval: Duration
    public var pingInterval: Duration
    /// How long the pre-flight waits for this host to hold an address on the
    /// device's subnet before deciding it is not on the access point — when
    /// nothing about the host suggests a join is under way. See
    /// `PocketSession.resolveWiFiPathPin`, which extends this to `timeout` while
    /// a self-assigned address says DHCP is still being attempted.
    public var hostAddressWait: Duration

    public init(timeout: Duration = .seconds(30),
                pollInterval: Duration = .seconds(1),
                pingInterval: Duration = .seconds(10),
                hostAddressWait: Duration = WiFiReadiness.defaultHostAddressWait) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.pingInterval = pingInterval
        self.hostAddressWait = hostAddressWait
    }

    /// Cap on the post-teardown wait for `MCU&WIFIS&0` before a batch reopens the
    /// access point (`PocketSession.awaitWiFiOff`). `timeout` bounds that wait as
    /// well; this caps it, because a caller who set a generous association
    /// timeout did not thereby ask to wait that long for a state transition the
    /// device reports in about 100 ms.
    static let maximumAccessPointOffWait = Duration.seconds(5)

    /// Default for `hostAddressWait`: how long the pre-flight waits for an
    /// address that is not there yet, when nothing suggests a join is under way.
    ///
    /// Not zero, deliberately. On iOS the process joins the network itself and
    /// `NEHotspotConfiguration.apply` returns once the phone has associated,
    /// which can be *before* DHCP has handed it an address — and the iOS path
    /// works today, so the pre-flight must not declare the host off a network it
    /// is in the middle of joining. On macOS, where the join is a person and the
    /// association wait has already cost seconds, the address is there on the
    /// first look and nothing is waited for at all.
    ///
    /// It is a floor and not a verdict: `resolveWiFiPathPin` extends the wait to
    /// the full `timeout` for as long as this host shows a self-assigned address,
    /// because that is a join actively trying rather than a host somewhere else.
    /// So no transfer is refused on this number alone.
    public static let defaultHostAddressWait = Duration.seconds(3)

    /// Cap on the wait for Network.framework's own list of available interfaces
    /// (`HostInterfaces.availableInterface`). A monitor that never reports leaves
    /// the connection unpinned — which is exactly the behaviour that shipped —
    /// rather than holding a transfer up.
    static let maximumInterfaceSnapshotWait = Duration.milliseconds(500)
}

// MARK: - Which of this host's interfaces can reach the device

/// One IPv4 address this host holds, the interface holding it, and whether the
/// link under that interface is running.
///
/// The device's address is a fixed constant (`WiFiEndpoint.deviceHost`) on a
/// directly-connected `/24`, so an interface holding an address on that `/24` is
/// the only one **configured** to reach it, and none holding one means no route
/// to the device exists at all. That is what this list is evidence of — routing
/// configuration — and the distinction is not pedantry:
///
/// **An address is not an association.** macOS keeps the address, the netmask,
/// the route and the ARP entry after a Wi-Fi interface disassociates, so every
/// run that ever joined the recorder leaves behind a configuration that looks
/// exactly like a live one from here — and it is most likely to be stale
/// precisely when somebody is testing repeatedly. Observed on 2026-07-30:
/// `networksetup -getairportnetwork en0` reported *not associated* while
/// `ifconfig en0` still showed `192.168.200.2`, and everything aimed at the
/// device failed. Nothing in this package may read an address as proof that this
/// host has joined anything.
struct HostInterfaceAddress: Sendable, Equatable {
    /// BSD interface name — `en0`, `utun4`, `lo0`.
    let interfaceName: String
    /// Dotted-quad IPv4 address.
    let address: String
    /// The kernel's `IFF_RUNNING` for the interface: RFC 2863 operational
    /// status, as distinct from `IFF_UP`, which is only the administrative
    /// switch. Read from the same `getifaddrs` call as the address — no shell
    /// tool, no SSID, and nothing gated behind Location Services.
    ///
    /// Used in **one direction only**. Clear means the interface is carrying no
    /// link and therefore is certainly not associated. Set does *not* mean it is:
    /// this flag says the driver has resources allocated, not that a Wi-Fi
    /// supplicant is currently joined to a network, and inferring an association
    /// from it would repeat the mistake this field exists to catch.
    let linkIsRunning: Bool

    /// `linkIsRunning` defaults to `true` so a caller describing a host it
    /// already believes to be up — every synthetic host in the tests — states
    /// only what it means to state. The system enumeration always passes the
    /// real flag.
    init(interfaceName: String, address: String, linkIsRunning: Bool = true) {
        self.interfaceName = interfaceName
        self.address = address
        self.linkIsRunning = linkIsRunning
    }
}

/// Enumerates this host's IPv4 interface addresses. The seam the WiFi pre-flight
/// is tested through — see `PocketSession.hostInterfaces`.
typealias HostInterfaceLister = @Sendable () -> [HostInterfaceAddress]

enum HostInterfaces {
    /// The real host, through `getifaddrs`. Platform, not a dependency, and
    /// present on both iOS and macOS.
    static let system: HostInterfaceLister = { systemIPv4Addresses() }

    /// IPv4 addresses on interfaces that are up. IPv4 only and up only because
    /// of the question being asked: which interface can reach an IPv4 address on
    /// a directly-connected subnet. A down interface answers nothing.
    static func systemIPv4Addresses() -> [HostInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [HostInterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  let name = String(validatingCString: entry.pointee.ifa_name)
            else { continue }
            // `sin_addr.s_addr` is in network byte order, so its bytes in memory
            // order already read a.b.c.d — no endian conversion, and no
            // `getnameinfo` round trip through a C string to undo afterwards.
            let raw = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            let octets = withUnsafeBytes(of: raw) { Array($0) }
            found.append(HostInterfaceAddress(
                interfaceName: name,
                address: octets.map(String.init).joined(separator: "."),
                // Operational, not administrative. `IFF_UP` above only says the
                // interface is switched on; `IFF_RUNNING` says the link under it
                // is up. A Wi-Fi interface that has disassociated keeps its
                // address, so this is the one thing in the enumeration that can
                // contradict it.
                linkIsRunning: entry.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0))
        }
        return found
    }

    /// The `NWInterface` Network.framework currently lists under `name`, or nil
    /// when it lists none.
    ///
    /// Loopback is legitimately absent from that list, so a nil here is ordinary
    /// and means "leave the connection unpinned" — the behaviour that shipped.
    static func availableInterface(named name: String, within bound: Duration) async -> NWInterface? {
        await availableInterfaces(within: bound).first { $0.name == name }
    }

    /// Every `NWInterface` Network.framework currently considers available.
    ///
    /// A monitor that never reports yields an empty list, which leaves the
    /// connection unpinned rather than holding a transfer up.
    static func availableInterfaces(within bound: Duration) async -> [NWInterface] {
        await firstReportedPath(within: bound)?.interfaces ?? []
    }

    /// Whether this host's **default** path — the one an unconstrained
    /// connection takes, i.e. what the default route resolves to — currently
    /// runs over wired Ethernet.
    ///
    /// This is the condition that cost an entire debugging session on
    /// 2026-07-30. The recorder's access point offers no internet. With a wired
    /// link up and carrying the default route, macOS associated with that access
    /// point and then **dropped the association**, while leaving the whole
    /// layer-3 configuration — address, netmask, route, ARP entry — in place. The
    /// transfer then failed with every host-side symptom pointing somewhere else,
    /// and unplugging Ethernet was what made it work. So the operator is told
    /// before the join rather than after the failure (`ManualHotspotJoiner`).
    ///
    /// `false` on a monitor that never reports: a warning that cannot be
    /// substantiated is not printed, and nothing here gates a transfer on it.
    static func defaultPathIsWired(
        within bound: Duration = WiFiReadiness.maximumInterfaceSnapshotWait
    ) async -> Bool {
        guard let path = await firstReportedPath(within: bound) else { return false }
        return path.isSatisfiedOverWiredEthernet
    }

    /// What one `NWPath` report says, reduced to the two facts this package
    /// reads off it. Reduced *inside* the monitor's handler so nothing but plain
    /// values crosses the queue hand-off.
    private struct PathFacts {
        let interfaces: [NWInterface]
        let isSatisfiedOverWiredEthernet: Bool
    }

    /// The first path `NWPathMonitor` reports, or nil when it reports none
    /// within `bound`.
    ///
    /// `NWPathMonitor` is the only public source of these values — `NWInterface`
    /// has no public initializer — and it reports asynchronously, hence the
    /// bounded poll for its first report.
    private static func firstReportedPath(within bound: Duration) async -> PathFacts? {
        let snapshot = PathSnapshot()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            snapshot.record(PathFacts(
                interfaces: path.availableInterfaces,
                isSatisfiedOverWiredEthernet: path.status == .satisfied
                    && path.usesInterfaceType(.wiredEthernet)))
        }
        monitor.start(queue: .global())
        defer { monitor.cancel() }
        let step = min(.milliseconds(5), bound)
        let deadline = ContinuousClock.now + bound
        while ContinuousClock.now < deadline {
            if let facts = snapshot.value { return facts }
            if Task.isCancelled { break }
            try? await Task.sleep(for: step)
        }
        return snapshot.value
    }

    /// The monitor reports on its own queue; the poll above reads from the
    /// caller's. One lock, one hand-off.
    private final class PathSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var facts: PathFacts?
        func record(_ facts: PathFacts) {
            lock.lock(); self.facts = facts; lock.unlock()
        }
        var value: PathFacts? { lock.lock(); defer { lock.unlock() }; return facts }
    }
}

// NWEndpoint is written `Network.NWEndpoint` throughout this file: on iOS,
// NetworkExtension exports a legacy class of the same name, and the bare
// name fails to compile as ambiguous.
enum WiFiEndpoint {
    /// The device serves the file at this address once a client joins its AP.
    static let deviceHost = "192.168.200.1"
    static let devicePort: UInt16 = 8475

    /// The `/24` the device's access point lives on, **derived** from
    /// `deviceHost` rather than written out a second time: every piece of
    /// interface reasoning below compares against it, and a subnet spelled twice
    /// is a subnet that can disagree with itself.
    static var deviceSubnet: String? { ipv4SubnetPrefix(of: deviceHost) }

    /// The addresses the device's DHCP server leases from — `192.168.200.2` in
    /// the capture and on hardware. Named because `WiFiConnectDiagnosis` quotes
    /// it: still holding one of these while the device answers nothing is the
    /// signature of an access point that has gone away.
    static var clientSubnet: String { deviceSubnet.map { "\($0).x" } ?? deviceHost }

    static var `default`: Network.NWEndpoint {
        .hostPort(host: Network.NWEndpoint.Host(deviceHost),
                  port: Network.NWEndpoint.Port(rawValue: devicePort)!)
    }

    /// The first three octets of a dotted-quad IPv4 address — the `/24` it sits
    /// in — or nil when `address` is not one.
    ///
    /// A `/24` because that is what the device's access point is: the device at
    /// `.1`, the client leased `.2` (capture-verified, hardware-confirmed). "On
    /// the same `/24`" is therefore exactly "can reach the device directly".
    static func ipv4SubnetPrefix(of address: String) -> String? {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return octets.prefix(3).joined(separator: ".")
    }

    /// The `/16` a host gives itself when DHCP never answers (RFC 3927
    /// link-local, `169.254.0.0/16`).
    static let selfAssignedPrefix = "169.254"

    /// True when `address` is one the host assigned to itself because DHCP never
    /// answered. It is the signature of a join that **worked** — the host
    /// associated with an access point, so the credentials were accepted — and a
    /// lease that did not arrive. Forgetting the network is the wrong repair for
    /// it, and telling somebody to do that would send them to re-enter a password
    /// that was never the problem.
    static func isSelfAssigned(_ address: String) -> Bool {
        ipv4SubnetPrefix(of: address)?.hasPrefix(selfAssignedPrefix) == true
    }

    /// The dotted-quad IPv4 address `endpoint` names, or nil when it names
    /// something else — a hostname, an IPv6 literal, a Bonjour service. Only an
    /// IPv4 host:port can be compared against this host's own addresses;
    /// anything else leaves the connection unpinned, exactly as before.
    static func ipv4Host(of endpoint: Network.NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        let literal: String
        switch host {
        case .ipv4(let address): literal = "\(address)"
        case .name(let name, _):  literal = name
        default:                  return nil
        }
        return ipv4SubnetPrefix(of: literal) != nil ? literal : nil
    }
}

/// Which interface the WiFi TCP connect requires of itself, and why that one.
///
/// `NWConnection(to: endpoint, using: .tcp)` — default parameters — is what this
/// replaces, and the reason it had to be replaced is that Network.framework runs
/// its own path evaluation and does **not** simply follow the BSD route table.
/// The recorder's access point provides no internet, and a Mac running a mesh
/// VPN carries a `utun` holding a default route, so the framework can select —
/// or wait indefinitely for — a path that cannot reach `192.168.200.1`. A silent
/// 30 s timeout with no error delivered to the caller is the signature of that,
/// as distinct from a refused connect (immediate) or an unreachable host (fast).
///
/// It is also why iOS worked while macOS did not: on iOS the app joins with
/// `NEHotspotConfiguration`, so the path belongs to the process; on macOS the
/// join is external and nothing identified the interface.
enum WiFiPathPin: Sendable, Equatable {
    /// This host holds an address on the device's `/24`, on the interface named
    /// here. `alsoOnSubnet` is every *other* interface that also holds one —
    /// normally empty, and never ignorable when it is not: see `choose`.
    case interface(HostInterfaceAddress, deviceSubnet: String,
                   alsoOnSubnet: [HostInterfaceAddress])
    /// No interface holds an address on the device's `/24`: this host is not on
    /// the access point and the connect must not be attempted. Carries what the
    /// host *does* hold, so the message can say what was looked at.
    case hostNotOnTheDeviceSubnet(deviceSubnet: String, held: [HostInterfaceAddress])
    /// The endpoint is not an IPv4 host:port, so there is no subnet to compare
    /// this host's interfaces against. Behaves exactly as before this existed:
    /// default parameters, and the device's own report is the only evidence.
    case noSubnetToCompare

    /// Picks the interface *configured* to reach `endpoint` directly: the first
    /// holding an address on its `/24`, in enumeration order. Configured, not
    /// associated — see `HostInterfaceAddress` for why the difference matters and
    /// `WiFiConnectDiagnosis.contradictionOfAddress` for what can tell them apart.
    ///
    /// **A tie is real ambiguity, not a free choice.** An RFC1918 `/24` is not
    /// globally unique, so two interfaces sharing one can be on two entirely
    /// different physical networks and only one of them reach the device — this
    /// very development host has `en0` and `en7` both on `192.168.1.x`. First
    /// match wins because it is deterministic and because every match is a
    /// genuine candidate, but the losers are carried in `alsoOnSubnet` and named
    /// in the summary and the failure message, so a transfer that fails because
    /// the wrong one was chosen says which others were available instead of
    /// leaving that to be guessed. Trying each in turn is the obvious next step
    /// if a tie is ever seen in the field; it is not written speculatively,
    /// because a retry loop nobody has needed is another unverified guess.
    static func choose(reaching endpoint: Network.NWEndpoint,
                       among addresses: [HostInterfaceAddress]) -> WiFiPathPin {
        guard let host = WiFiEndpoint.ipv4Host(of: endpoint),
              let subnet = WiFiEndpoint.ipv4SubnetPrefix(of: host) else { return .noSubnetToCompare }
        let matches = addresses.filter { WiFiEndpoint.ipv4SubnetPrefix(of: $0.address) == subnet }
        guard let match = matches.first else {
            return .hostNotOnTheDeviceSubnet(deviceSubnet: subnet, held: addresses)
        }
        return .interface(match, deviceSubnet: subnet,
                          alsoOnSubnet: Array(matches.dropFirst()))
    }

    /// The interface to require of the connection, if any.
    var interfaceName: String? {
        if case .interface(let held, _, _) = self { held.interfaceName } else { nil }
    }

    /// TCP parameters for a connection that must use `interface`.
    ///
    /// `requiredInterface` is the pin, and **not** `requiredLocalEndpoint`.
    /// Measured on this SDK: a connection required to use `en0` while its
    /// destination is reachable only over loopback sits in
    /// `.waiting(POSIXErrorCode 50: Network is down)` rather than quietly going
    /// elsewhere, so `requiredInterface` is enforced — while
    /// `requiredLocalEndpoint` was ignored outright, including when the address
    /// it named belonged to no interface on the machine. Pinning with a
    /// mechanism the framework ignores would be another unverified guess, which
    /// is the thing this change exists to stop making.
    ///
    /// **Nothing else is set, and an earlier version's `prohibitedInterfaceTypes`
    /// was removed rather than corrected.** It derived the prohibited set from
    /// the chosen interface's *name* (`en*`/`lo*` ⇒ exclude `.other`, the class a
    /// mesh VPN's `utun` reports as), which is an inference stacked on a
    /// `requiredInterface` that already excludes every other interface outright —
    /// so it bought nothing where the pin applied, and where the pin did *not*
    /// apply it could prohibit the very interface the connection needed. That
    /// failure would arrive as a silent `.waiting`: indistinguishable from the
    /// defect being fixed, and it would be met by guidance confidently blaming a
    /// VPN for owning the default route. Producing exactly the misattribution
    /// this change exists to end is not a price worth paying for a redundancy.
    ///
    /// `interface` is nil when Network.framework does not list the chosen
    /// interface among the ones it considers available; the connection is then
    /// left unpinned — byte for byte the previous behaviour, a plain
    /// `NWParameters.tcp` — and the failure message says so rather than implying
    /// a pin that was never applied.
    func tcpParameters(requiring interface: NWInterface?) -> NWParameters {
        let parameters = NWParameters.tcp
        if let interface { parameters.requiredInterface = interface }
        return parameters
    }

    /// One line for the event stream, before the attempt: what this host looks
    /// like and what the connect is therefore going to do.
    var summary: String {
        switch self {
        case .interface(let held, let subnet, let alsoOnSubnet):
            return "wifi tcp connect will require \(held.interfaceName) — it holds \(held.address) "
                + "on the device's \(subnet).0/24"
                + (alsoOnSubnet.isEmpty ? "" : "; AMBIGUOUS — also on that /24: "
                    + Self.summarize(alsoOnSubnet, deviceSubnet: subnet)
                    + " (an RFC1918 /24 is not unique, so these may be different networks)")
        case .hostNotOnTheDeviceSubnet(let subnet, let held):
            return "wifi tcp connect pre-flight: NO interface on this host holds an address on the "
                + "device's \(subnet).0/24 — this host holds "
                + Self.summarize(held, deviceSubnet: subnet)
        case .noSubnetToCompare:
            return "wifi tcp connect: the endpoint is not an IPv4 host:port, so no interface is "
                + "required of it (unpinned, as before)"
        }
    }

    /// This host's addresses, for a message that must say what it looked at
    /// without publishing where this host lives.
    ///
    /// An address on the device's own subnet is printed in full — that subnet is
    /// the recorder's and is already written down in this repository — and every
    /// other address is reduced to its `/24` with the host octet elided. These
    /// messages are printed by `sync-wifi`, and its transcripts get pasted into
    /// a public protocol reference, where somebody's LAN or mesh address has no
    /// business being.
    static func summarize(_ addresses: [HostInterfaceAddress], deviceSubnet: String) -> String {
        guard !addresses.isEmpty else { return "no IPv4 address at all" }
        return addresses.map { held in
            let prefix = WiFiEndpoint.ipv4SubnetPrefix(of: held.address)
            let shown = prefix == deviceSubnet ? held.address : "\(prefix ?? held.address).x"
            return "\(held.interfaceName) \(shown)"
        }.joined(separator: ", ")
    }
}

/// Wall clock of the last activity, shared between whoever produces it and
/// whoever watches for its absence. Two watchers use this type, and they must
/// NOT share one instance:
///
/// - `TCPFetch.receive`'s stall watchdog, which must fire when the device stops
///   sending bytes;
/// - the WiFi session keepalive, which must send `APP&WPING` when the session
///   goes quiet (see `startWiFiSessionKeepalive`).
///
/// One shared instance would let every keepalive ping reset the stall watchdog,
/// and a dead transfer would then never time out. So each transfer keeps its
/// own monitor for the watchdog and *also* touches the session's, which is why
/// `receive` takes `sessionActivity` separately.
final class ActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    func touch() { lock.lock(); last = .now; lock.unlock() }
    func idleSince() -> Duration { lock.lock(); defer { lock.unlock() }; return .now - last }
}

/// Single-shot guard so an NWConnection state handler can resume its checked
/// continuation exactly once (`.ready`, `.failed`, and `.cancelled` can all
/// fire over the handler's lifetime).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// Watches one connect attempt's `NWConnection` states: decides what the connect
/// should do about each, and — the point of it — keeps what the non-terminal ones
/// said.
///
/// `.waiting(NWError)` carries Network.framework's own reason for not being able
/// to proceed, and the state handler this replaces threw it away:
///
///     default:
///         break   // .setup / .preparing / .waiting — keep waiting
///
/// A failing run could therefore only ever report its own timeout, which is why
/// the cause of the macOS WiFi failure was proposed and eliminated three times
/// over. `.waiting` repeats as conditions change, so the most recent reason is
/// the diagnosis and the whole sequence is the record.
///
/// A type of its own, driven by `observe`, so a test can put the exact state
/// sequence a failing run produces through the very code the connect runs — with
/// no radio and no access point.
final class WiFiConnectWatcher: @unchecked Sendable {
    /// What the connect should do about the state just observed.
    enum Outcome: Equatable {
        case ready
        /// Terminal failure, with the symptom line for it.
        case failed(String)
        case cancelled
        /// `.setup` / `.preparing` / `.waiting` — recorded, and kept waiting on.
        case keepWaiting
    }

    private let lock = NSLock()
    private var recorded: [String] = []
    private var reason: String?

    /// Records `state` and says what to do about it.
    func observe(_ state: NWConnection.State) -> Outcome {
        switch state {
        case .ready:
            note("ready", reason: nil)
            return .ready
        case .failed(let error):
            // `localizedDescription` here, keeping the message this path has
            // always produced; `.waiting` below wants the richer form.
            note("failed(\(error.localizedDescription))", reason: nil)
            return .failed("wifi tcp connect failed: \(error.localizedDescription)")
        case .cancelled:
            note("cancelled", reason: nil)
            return .cancelled
        case .waiting(let error):
            // The whole reason this type exists. `String(describing:)` rather
            // than `localizedDescription` because the POSIX code is the
            // diagnosis: ENETDOWN (50) is a path with no usable route,
            // EHOSTUNREACH (65) is a route with nothing on the other end, and
            // ECONNREFUSED (61) is a host that answered. "Network is down"
            // alone does not separate those.
            let described = String(describing: error)
            note("waiting(\(described))", reason: described)
            return .keepWaiting
        case .setup:
            note("setup", reason: nil)
            return .keepWaiting
        case .preparing:
            note("preparing", reason: nil)
            return .keepWaiting
        @unknown default:
            note("unrecognised state", reason: nil)
            return .keepWaiting
        }
    }

    /// One lock for both fields: a reader must never see a transition recorded
    /// without the reason that came with it.
    private func note(_ transition: String, reason newReason: String?) {
        lock.lock()
        recorded.append(transition)
        if let newReason { reason = newReason }
        lock.unlock()
    }

    /// Network.framework's most recent reason for not being able to proceed, or
    /// nil when it never gave one — which is itself a finding, and one this code
    /// previously could not state.
    var lastWaitingReason: String? { lock.lock(); defer { lock.unlock() }; return reason }

    /// Every state observed, in order.
    var transitions: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    /// The failure to throw for `symptom`, carrying everything observed so far.
    func failure(_ symptom: String, pin: WiFiPathPin, pinnedInterface: String?) -> WiFiConnectFailure {
        lock.lock(); defer { lock.unlock() }
        return WiFiConnectFailure(symptom: symptom, pin: pin, pinnedInterface: pinnedInterface,
                                  waitingReason: reason, transitions: recorded)
    }
}

/// A WiFi TCP connect that produced no socket, carrying everything the attempt
/// learned about why.
///
/// Not a `PocketError`: it lives only between `TCPFetch.connect` and
/// `PocketSession.diagnosed(connectFailure:…)`, which reads the evidence, picks
/// the diagnosis it implies, and turns the pair into the
/// `PocketError.transferFailed` every caller already handles.
struct WiFiConnectFailure: Error, Sendable, Equatable {
    /// The bare symptom, in the words the message used to have all to itself.
    let symptom: String
    /// Which interface the connect chose, and why that one.
    let pin: WiFiPathPin
    /// The interface actually required of the connection — nil when the chosen
    /// one could not be required (Network.framework did not list it) or when
    /// there was nothing to choose. Distinguishing "pinned and still failed"
    /// from "could not pin" is the difference between two quite different next
    /// steps, so it is never implied.
    let pinnedInterface: String?
    /// Network.framework's most recent `.waiting` reason, or nil when it gave
    /// none.
    let waitingReason: String?
    /// Every state the attempt passed through, in order.
    let transitions: [String]

    /// What the connect did with this host's network, in a clause.
    private var pinStatement: String {
        switch pin {
        case .interface(let held, let subnet, let alsoOnSubnet):
            let holds = "holds \(held.address) on the device's \(subnet).0/24"
            let chosen = pinnedInterface == nil
                ? "\(held.interfaceName) \(holds), but Network.framework does not list it among its "
                    + "available interfaces, so the connection could not be required to use it"
                : "the connection required \(held.interfaceName), which \(holds)"
            guard !alsoOnSubnet.isEmpty else { return chosen }
            // A tie means the choice itself is a suspect, and a reader cannot
            // suspect what they were never told about.
            return chosen + " — but it was not the only candidate: "
                + WiFiPathPin.summarize(alsoOnSubnet, deviceSubnet: subnet)
                + " also hold addresses on that /24, and an RFC1918 /24 is not unique, so those "
                + "may be entirely different networks"
        case .hostNotOnTheDeviceSubnet(let subnet, let held):
            return "no interface on this host holds an address on the device's \(subnet).0/24, so "
                + "this host is not on the recorder's access point — this host holds "
                + WiFiPathPin.summarize(held, deviceSubnet: subnet)
        case .noSubnetToCompare:
            return "the endpoint is not an IPv4 host:port, so there was no subnet to compare this "
                + "host's interfaces against and no interface to require"
        }
    }

    /// The thrown message: the symptom, what the connect did about this host's
    /// interfaces, and the last reason Network.framework gave. Deliberately NOT
    /// the whole transition sequence — that is longer than an error message
    /// should be, and goes to `DeviceEvent.wifiConnectPath` instead.
    var detail: String {
        var text = "\(symptom) — \(pinStatement)"
        if let waitingReason { text += "; Network.framework's last reason: \(waitingReason)" }
        return text
    }

    /// The verbose line: what was pinned, and every state, in order.
    var pathReport: String {
        let states = transitions.isEmpty ? "none observed" : transitions.joined(separator: " -> ")
        return "wifi tcp connect path: \(pinStatement); states: \(states)"
    }
}

/// TCP client for the device's :8475 file push. The connection is
/// established FIRST (the device reports it as `MCU&WIFIS&1`) and only then
/// does the caller run the `APP&U&<id>` + `APP&U&WIFI` selection over BLE —
/// the capture shows the official app in exactly that order.
enum TCPFetch {
    /// Opens the connection and waits for `.ready`, bounded by `timeout` —
    /// without the bound, an unreachable endpoint leaves `NWConnection` in
    /// `.waiting` forever.
    ///
    /// `pin` is which of this host's interfaces may carry it, computed by
    /// `PocketSession.resolveWiFiPathPin`. A pin that says this host holds no
    /// address on the device's subnet is a connect that cannot succeed, and it
    /// fails here and now rather than spending the whole timeout discovering it.
    static func connect(to endpoint: Network.NWEndpoint,
                        timeout: Duration = .seconds(30),
                        pin: WiFiPathPin = .noSubnetToCompare) async throws -> NWConnection {
        let watcher = WiFiConnectWatcher()
        // The pre-flight. Nothing on the device's subnet means this host is not
        // on the access point, and the useful answer is "join it", now, naming
        // it — not a 30 s wait ending in a timeout that names nothing.
        if case .hostNotOnTheDeviceSubnet = pin {
            throw watcher.failure("wifi tcp connect not attempted", pin: pin, pinnedInterface: nil)
        }
        let required: NWInterface?
        if let name = pin.interfaceName {
            required = await HostInterfaces.availableInterface(
                named: name, within: WiFiReadiness.maximumInterfaceSnapshotWait)
        } else {
            required = nil
        }
        let pinnedInterface = required?.name
        let connection = NWConnection(to: endpoint, using: pin.tcpParameters(requiring: required))
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = ResumeOnce()
                    connection.stateUpdateHandler = { state in
                        switch watcher.observe(state) {
                        case .ready:
                            if once.first() { continuation.resume() }
                        case .failed(let symptom):
                            if once.first() {
                                continuation.resume(throwing: watcher.failure(
                                    symptom, pin: pin, pinnedInterface: pinnedInterface))
                            }
                        case .cancelled:
                            if once.first() {
                                continuation.resume(throwing: watcher.failure(
                                    "wifi tcp connect cancelled", pin: pin,
                                    pinnedInterface: pinnedInterface))
                            }
                        case .keepWaiting:
                            break   // .setup / .preparing / .waiting — recorded, still waiting
                        }
                    }
                    connection.start(queue: .global())
                }
            }
            group.addTask {
                // Doubles as the caller-cancellation path: the sleep throws
                // CancellationError when the group is cancelled.
                try await Task.sleep(for: timeout)
                throw watcher.failure("wifi tcp connect timed out after \(timeout)",
                                      pin: pin, pinnedInterface: pinnedInterface)
            }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
            } catch {
                // The state handler's continuation may still be pending;
                // cancelling the connection fires `.cancelled`, which resumes
                // it so the group can drain instead of deadlocking.
                connection.cancel()
                try Task.checkCancellation()
                throw error
            }
            connection.stateUpdateHandler = nil   // release the continuation capture
            return connection
        }
    }

    /// Cap on retained surplus (see `Received.surplusPreview`) so a
    /// pathological peer that streams garbage past the announced length
    /// cannot balloon memory.
    static let surplusPreviewLimit = 64

    /// What one fetch produced. The payload itself went to the transfer's
    /// `TransferSink` — never more than the announced bytes of it — so this
    /// carries only the bounded record of any surplus the device sent past
    /// that length. Live hardware appends a short trailer (10 bytes
    /// observed) after the file on the TCP stream; the announced size is
    /// authoritative — the BLE download of the same recording is
    /// byte-identical at exactly that length — so the trailer is
    /// diagnostics, not payload.
    struct Received: Sendable {
        /// Total surplus bytes read past `expected`; 0 when none was seen.
        let surplusCount: Int
        /// The first `surplusPreviewLimit` bytes of that surplus.
        let surplusPreview: Data
    }

    /// Reads exactly `expected` bytes from an already-connected socket into
    /// `sink` — surplus past `expected` never reaches it. `idleTimeout`
    /// bounds how long the connection may sit with no new bytes before the
    /// fetch is declared failed and the connection torn down.
    ///
    /// `sessionActivity`, when given, is touched alongside this fetch's own
    /// stall clock so the WiFi session keepalive can see that bytes are still
    /// flowing and stay off the wire. It is deliberately a second monitor and
    /// never the watchdog's own — see `ActivityMonitor`.
    static func receive(on connection: NWConnection,
                        expected: Int,
                        idleTimeout: Duration = .seconds(10),
                        into sink: TransferSink,
                        sessionActivity: ActivityMonitor? = nil,
                        onProgress: (@Sendable (Double) -> Void)?) async throws -> Received {
        let activity = ActivityMonitor()

        return try await withThrowingTaskGroup(of: Received?.self) { group in
            group.addTask {
                var received = 0
                var surplusCount = 0
                var surplusPreview = Data()
                while received < expected {
                    guard let part = try await nextChunk(connection) else { break }   // EOF
                    guard !part.isEmpty else { continue }
                    let needed = expected - received
                    if part.count > needed {
                        // The chunk crosses the announced length: keep exactly
                        // what completes the file, retain the overshoot
                        // (bounded) for diagnostics. No further reads happen —
                        // the loop condition is now false — so a trailer that
                        // arrives in a *later* TCP segment is simply left
                        // unread; only surplus already read is captured.
                        sink.consume(part.prefix(needed))
                        received += needed
                        let surplus = part.dropFirst(needed)
                        surplusCount += surplus.count
                        surplusPreview.append(surplus.prefix(surplusPreviewLimit - surplusPreview.count))
                    } else {
                        sink.consume(part)
                        received += part.count
                    }
                    activity.touch()
                    sessionActivity?.touch()
                    onProgress?(min(1.0, Double(received) / Double(max(expected, 1))))
                }
                return Received(surplusCount: surplusCount, surplusPreview: surplusPreview)
            }
            group.addTask {   // watchdog: resolves nil when the fetch must be aborted
                while true {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return nil }
                    if activity.idleSince() > idleTimeout { return nil }
                }
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next(), let received = first else {
                    // Watchdog fired (stall, dead endpoint, or caller
                    // cancellation). The reader is pinned inside a receive that
                    // will never call back on its own; cancelling the connection
                    // resumes it so the group can drain instead of deadlocking.
                    connection.cancel()
                    try Task.checkCancellation()
                    throw PocketError.transferFailed(
                        "wifi transfer stalled: no data for \(idleTimeout)")
                }
                connection.cancel()
                return received   // the sink may be short on EOF — finalize size-checks
            } catch {
                connection.cancel()
                throw error
            }
        }
    }

    private static func nextChunk(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { part, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: PocketError.transferFailed(error.localizedDescription))
                } else if let part, !part.isEmpty {
                    continuation.resume(returning: part)
                } else if isComplete {
                    continuation.resume(returning: nil)       // server closed the stream
                } else {
                    continuation.resume(returning: Data())    // empty wakeup; read again
                }
            }
        }
    }
}

extension PocketSession {
    /// WiFi Quick Transfer. Control stays on BLE for the whole flow; only the
    /// file bytes travel over TCP.
    ///
    /// The sequence is the one the official app performs, decoded frame by
    /// frame from an HCI snoop of one complete app-driven sync:
    ///
    /// 1. `APP&SHUT` — abort anything in flight (no reply when idle)
    /// 2. `APP&WIFIS` — state query (`MCU&WIFIS&0` on a fresh start)
    /// 3. `APP&WIFI` → `MCU&WIFI&<ssid>&<psk>` — credentials are the
    ///    synchronous reply to this request, never a push
    /// 4. `APP&WIFIO` → `MCU&WIFIO` — starts the AP (`MCU&WIFIS&3` follows)
    /// 5. join the AP, poll `APP&WIFIS` until `2` (phone associated)
    /// 6. open TCP to 192.168.200.1:8475 with `APP&WPING` keepalives while
    ///    the network stack gets ready (`MCU&WIFIS&1` = TCP connected)
    /// 7. `APP&U&<date>&<ts>` selects the recording, then `APP&U&WIFI`
    ///    reroutes that selection to the socket; read exactly `<size>` bytes
    /// 8. `APP&WIFIC` ×2 closes the session (`MCU&OFF` marks completion)
    ///
    /// Claims the same exclusive transfer slot as `downloadOverBLE` and the
    /// live stream: the device has one transfer engine, and a concurrent BLE
    /// bulk transfer would interleave with the WiFi control traffic.
    public func downloadOverWiFi(_ recording: RecordingInfo,
                                 endpointOverride: Network.NWEndpoint? = nil,
                                 joiner: HotspotJoining = SystemHotspotJoiner(),
                                 idleTimeout: Duration = .seconds(10),
                                 readiness: WiFiReadiness = WiFiReadiness(),
                                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        guard let data = try await downloadOverWiFi(recording, into: TransferSink.memory(),
                                                    endpointOverride: endpointOverride,
                                                    joiner: joiner, idleTimeout: idleTimeout,
                                                    readiness: readiness,
                                                    onProgress: onProgress) else {
            throw PocketError.transferFailed("internal: memory sink produced no data")
        }
        return data
    }

    /// Streaming variant: writes the bytes to `destination` as they arrive
    /// instead of accumulating them in memory. Same control flow, same
    /// integrity rules (announced count is authoritative, surplus trailer
    /// bytes never reach the file), same failure behaviour — the two shapes
    /// share one transfer implementation — plus the file guarantee: on ANY
    /// failure (including cancellation) nothing appears at `destination`,
    /// and a pre-existing file there is replaced only by a validated
    /// download.
    ///
    /// There is no resume: `APP&U&<date>&<ts>` takes no byte offset (no
    /// protocol command does), so a failed transfer restarts from byte zero.
    public func downloadOverWiFi(_ recording: RecordingInfo,
                                 to destination: URL,
                                 endpointOverride: Network.NWEndpoint? = nil,
                                 joiner: HotspotJoining = SystemHotspotJoiner(),
                                 idleTimeout: Duration = .seconds(10),
                                 readiness: WiFiReadiness = WiFiReadiness(),
                                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await downloadOverWiFi(recording, into: TransferSink.file(destination: destination),
                                       endpointOverride: endpointOverride,
                                       joiner: joiner, idleTimeout: idleTimeout,
                                       readiness: readiness, onProgress: onProgress)
    }

    /// The one WiFi transfer implementation both public shapes call — where
    /// the payload lands is the sink's business, never this function's, so
    /// the two shapes cannot drift. On any failure the sink is aborted: the
    /// partial payload must not survive looking like a recording.
    private func downloadOverWiFi(_ recording: RecordingInfo,
                                  into sink: TransferSink,
                                  endpointOverride: Network.NWEndpoint?,
                                  joiner: HotspotJoining,
                                  idleTimeout: Duration,
                                  readiness: WiFiReadiness,
                                  onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        do {
            return try await runWiFiTransfer(recording, sink: sink,
                                             endpointOverride: endpointOverride,
                                             joiner: joiner, idleTimeout: idleTimeout,
                                             readiness: readiness, onProgress: onProgress)
        } catch {
            sink.abort()
            throw error
        }
    }

    private func runWiFiTransfer(_ recording: RecordingInfo,
                                 sink: TransferSink,
                                 endpointOverride: Network.NWEndpoint?,
                                 joiner: HotspotJoining,
                                 idleTimeout: Duration,
                                 readiness: WiFiReadiness,
                                 onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        try beginTransfer()
        defer { endTransfer() }   // covers every exit path below

        // Steps 1–5. `openWiFiSession` cleans up after its own failures (it is
        // the only code that knows how far the sequence got), so nothing here
        // needs a catch around it.
        let session = try await openWiFiSession(joiner: joiner, readiness: readiness)
        // From here every exit must close the AP and leave the network so the
        // operator's own comes back. `leave()` is async, so a defer cannot
        // await it, and a fire-and-forget Task in a defer would race callers
        // that observe the joiner as soon as this function returns — hence
        // the explicit do/catch instead.
        do {
            // 6. TCP first — the selection that follows is served into this
            // socket, and the device reports it as MCU&WIFIS&1.
            let endpoint = endpointOverride ?? WiFiEndpoint.default
            // Which interface may carry it, decided once and read twice: the
            // connect requires it, and the diagnosis reasons from it.
            let pin = await resolveWiFiPathPin(to: endpoint, readiness: readiness)
            let connection: NWConnection
            do {
                connection = try await connectKeepingLinkAlive(
                    to: endpoint, readiness: readiness, pin: pin,
                    sessionActivity: session.activity)
            } catch {
                throw diagnosed(connectFailure: error, pin: pin, ssid: session.ssid,
                                passphrase: session.passphrase,
                                clientAssociationObserved: session.clientAssociationObserved,
                                lastReportedState: session.lastReportedState)
            }
            do {
                // 7. Select, reroute, read exactly the announced bytes, verify.
                let data = try await transferOverTCP(recording, connection: connection,
                                                     sink: sink,
                                                     sessionActivity: session.activity,
                                                     idleTimeout: idleTimeout,
                                                     onProgress: onProgress)
                // 8. Close the session.
                await closeWiFiSession(session, joiner: joiner, aborting: false)
                return data
            } catch {
                connection.cancel()   // idempotent; receive() may already have
                throw error
            }
        } catch {
            await closeWiFiSession(session, joiner: joiner, aborting: true)
            throw error
        }
    }

    // MARK: - The access-point session

    /// One live access-point session: what the device told us about it, the
    /// idle clock its keepalive reads, and the keepalive itself.
    ///
    /// Held for exactly one transfer by `runWiFiTransfer` and for a whole batch
    /// by `downloadOverWiFi(_ recordings:…)`. That is the only difference
    /// between the two — the sequence either side of it is identical.
    private struct WiFiSessionHandle {
        let ssid: String
        let passphrase: String
        /// The device reported an associated client (`MCU&WIFIS&2`, or `1`
        /// which subsumes it) during setup. Feeds the connect-failure
        /// diagnosis: the device is the only witness to whether anything ever
        /// joined the AP it was broadcasting.
        let clientAssociationObserved: Bool
        /// The last `MCU&WIFIS&<n>` the association wait actually saw, or `nil`
        /// when the device answered none. Distinguishes an access point that came
        /// down (`0`) from one that stayed up with nobody on it (`3`) — two
        /// failures with one symptom and opposite causes, which is the whole
        /// reason `WiFiConnectDiagnosis` needs it.
        let lastReportedState: WiFiState?
        let activity: ActivityMonitor
        let keepalive: Task<Void, Never>
    }

    /// What the association wait saw. `observed` is the readiness signal the call
    /// site is deliberately lenient about; `lastReportedState` is evidence kept
    /// for the failure message, never for control flow.
    private struct WiFiAssociationWait {
        let observed: Bool
        let lastReportedState: WiFiState?
    }

    /// Steps 1–5 of the capture-verified sequence: abort anything in flight,
    /// read the WiFi state, read the credentials, start the AP, join it, and
    /// wait (leniently) for the device to report the association. Returns a
    /// live session with its keepalive running.
    ///
    /// Cleans up after its own failures, and the cleanup differs by how far it
    /// got — which is why it lives here rather than in the callers:
    /// before `APP&WIFIO` there is no AP to close; after it there is, but
    /// nothing has joined yet, so there is nothing to leave; after the join
    /// both apply.
    private func openWiFiSession(joiner: HotspotJoining,
                                 readiness: WiFiReadiness) async throws -> WiFiSessionHandle {
        // 1–2. Abort any in-flight transfer and read the WiFi state. SHUT is
        // fire-and-forget: an idle device sends no MCU&SHUT (live-probe
        // verified), so blocking on a reply would hang the happy path.
        try await send(.wifiShutdown)
        _ = try await request(.wifiStatus, timeout: .seconds(5)) {
            if case .wifiState = $0 { true } else { false }
        }

        // 3. Credentials are the synchronous reply to APP&WIFI. This is NOT
        // the forbidden provisioning command APP&WIFI&CH&… — it carries no
        // arguments and only reads the AP's SSID/PSK.
        let credentials = try await request(.wifiCredentials, timeout: .seconds(5)) {
            if case .wifiCredentials = $0 { true } else { false }
        }
        guard case .wifiCredentials(let ssid, let passphrase) = credentials else {
            throw PocketError.unexpectedResponse("expected MCU&WIFI&<ssid>&<psk>")
        }

        // 4. APP&WIFIO is what actually starts the AP (querying credentials
        // does not). From here every failure exit sends a best-effort
        // APP&WIFIC: a failed WiFi attempt is exactly when the BLE fallback
        // runs, and a still-broadcasting AP competes with BLE for the same
        // 2.4 GHz radio.
        do {
            _ = try await request(.wifiAccessPointOn, timeout: .seconds(5)) {
                $0 == .wifiAccessPointOn
            }
        } catch {
            try? await send(.wifiClose)   // the AP may have started despite a lost ack
            throw error
        }

        // The session keepalive starts HERE — before the join, not after it.
        //
        // On macOS the join IS a person: `ManualHotspotJoiner` prints instructions
        // and blocks on `readLine()` while the operator opens System Settings,
        // forgets a stale network, finds the SSID and types a password. On
        // 2026-07-28 that pause was long enough for the device's access point to
        // come up, serve DHCP, and go away again before a single byte was asked
        // for — after which the Mac still held a `192.168.200.x` lease and
        // everything it aimed at the device answered `No route to host`, because
        // nothing was answering ARP any more. Every downstream symptom, up to and
        // including `wifi tcp connect timed out after 30.0 seconds`, follows from
        // that one pause.
        //
        // `awaitWiFiClientJoined` pings for exactly this reason — its own comment
        // says a "possibly human-paced association" must not idle out the BLE link
        // — and it starts one step too late to see the human. Starting the
        // session-long keepalive before the join covers that stretch and every
        // later one with a single mechanism, and covers every `HotspotJoining`
        // rather than just the blocking one: `SystemHotspotJoiner` waits on an iOS
        // permission alert, which is the same shape of pause and merely faster
        // today.
        let activity = ActivityMonitor()
        let keepalive = startWiFiSessionKeepalive(activity, readiness: readiness)
        // Every failure exit below must stop it; only the returned handle takes
        // ownership. A defer rather than a line per catch, so a path added later
        // cannot leak a pinger onto a closed access point.
        var handedOver = false
        defer { if !handedOver { keepalive.cancel() } }

        do {
            try await joiner.join(ssid: ssid, passphrase: passphrase)
        } catch {
            try? await send(.wifiClose)
            throw diagnosed(joinFailure: error, ssid: ssid, passphrase: passphrase)
        }

        do {
            // 5. Wait (leniently) for MCU&WIFIS&2: the capture shows the TCP
            // connect only after the device reports the association, and
            // connecting earlier just burns the timeout against a network
            // that is not routing yet.
            let wait = try await awaitWiFiClientJoined(readiness, sessionActivity: activity)
            if !wait.observed {
                // Lenient by design: if this firmware's state machine differs
                // from the capture, do not block a transfer that would work —
                // but make sure the fact is visible to the CLI/checkpoint.
                emitEvent(.wifiReadinessNotObserved)
            }
            handedOver = true
            return WiFiSessionHandle(
                ssid: ssid, passphrase: passphrase,
                clientAssociationObserved: wait.observed,
                lastReportedState: wait.lastReportedState,
                activity: activity,
                keepalive: keepalive)
        } catch {
            // Past the join, so the full teardown applies.
            try? await send(.wifiShutdown)
            try? await send(.wifiClose)
            await joiner.leave()
            throw error
        }
    }

    /// Closes the access point and leaves the network. Best effort throughout:
    /// this runs on paths where the link may already be gone, and an AP left
    /// broadcasting into the BLE fallback is worse than a lost error.
    ///
    /// `aborting` picks between the two shapes the capture and the field
    /// established:
    ///
    /// - a completed transfer sends `APP&WIFIC` **twice**, mirroring the vendor
    ///   app's traffic (the device tolerates the redundant close);
    /// - a failure first sends `APP&SHUT` to abort an upload that may already be
    ///   selected (no reply arrives when nothing is in flight) and then closes
    ///   once.
    private func closeWiFiSession(_ session: WiFiSessionHandle,
                                  joiner: HotspotJoining,
                                  aborting: Bool) async {
        session.keepalive.cancel()
        if aborting {
            try? await send(.wifiShutdown)
            try? await send(.wifiClose)
        } else {
            try? await send(.wifiClose)
            try? await send(.wifiClose)
        }
        await joiner.leave()
    }

    /// Keeps the device's WiFi session alive for as long as it is open.
    ///
    /// `APP&WPING` used to cover exactly one stretch — the TCP connect — because
    /// a session lasted exactly one transfer. A batch adds stretches the connect
    /// pinger never saw: between one recording's `MCU&OFF` and the next one's
    /// selection, and across the integrity check and file publish. This task
    /// spans the whole session instead.
    ///
    /// **Including the join.** It is started before `joiner.join` rather than
    /// after it (see `openWiFiSession`), because the longest silence in the whole
    /// sequence is the one where a person joins the network by hand — and that is
    /// the silence that cost every macOS Wi-Fi transfer up to 0.1.3.
    ///
    /// It reads `ActivityMonitor.idleSince()` — the clock the TCP reader already
    /// touches on every chunk — rather than timing itself, so a ping goes out
    /// only after `pingInterval` of genuine silence. That is the point: nothing
    /// pings on top of a transfer that is streaming bytes, which is what the
    /// single-transfer code was careful never to do.
    ///
    /// Sends via `sendWiFiSessionKeepalive` (fire-and-forget) and never
    /// `request`, so it cannot hold the session's single request slot — see that
    /// method for why a `.busy` here would be actively misleading.
    private func startWiFiSessionKeepalive(_ activity: ActivityMonitor,
                                           readiness: WiFiReadiness) -> Task<Void, Never> {
        Task { [weak self] in
            // Check often enough to notice an idle gap promptly, never hot: a
            // `pingInterval` of zero (tests use it to force pings) must not
            // become a spin loop.
            let tick = max(min(readiness.pingInterval, .seconds(1)), .milliseconds(50))
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                if Task.isCancelled { return }
                guard let self else { return }
                guard activity.idleSince() >= readiness.pingInterval else { continue }
                await self.sendWiFiSessionKeepalive()
                activity.touch()
            }
        }
    }

    /// The comparison behind every message below: the password the device just
    /// reported over BLE against the one this session's key implies.
    private func wifiJoinDiagnosis(reportedPassphrase: String) -> WiFiJoinDiagnosis {
        .of(reportedPassphrase: reportedPassphrase, derivedFromKey: apPassphraseImpliedByKey)
    }

    /// Appends this package's own diagnosis to a join failure, so the thrown
    /// error names the likeliest cause instead of only the symptom. A stale
    /// saved credential is a known, common cause — it happens to *everyone* who
    /// rotates a key — and is invisible from the OS's API surface.
    ///
    /// Only `PocketError.wifiJoinFailed` is rewritten: both built-in joiners
    /// throw it and it is the documented shape, while a custom joiner's own
    /// error type — and `CancellationError` — propagates untouched rather than
    /// being flattened into a string. The joiner's original text still leads;
    /// the diagnosis follows it.
    private func diagnosed(joinFailure error: Error, ssid: String, passphrase: String) -> Error {
        guard case PocketError.wifiJoinFailed(let detail) = error else { return error }
        return PocketError.wifiJoinFailed(
            "\(detail) — \(wifiJoinDiagnosis(reportedPassphrase: passphrase).guidance(ssid: ssid))")
    }

    /// A TCP connect that never completes is the shape this failure takes on the
    /// macOS path, where the join cannot fail: the operator pressed return and the
    /// only symptom reaching the process is a socket that never opens
    /// (`wifi tcp connect timed out after 30.0 seconds`, on 2026-07-28).
    ///
    /// The device is the witness, and which of two opposite stories it tells
    /// decides the guidance — see `WiFiConnectDiagnosis`. It reported a client, so
    /// the host was on the AP and the credentials are irrelevant; it reported its
    /// WiFi off, so the AP came down by itself; or it reported the AP up with
    /// nobody on it, which is the stale-credential shape and the only case that
    /// gets the credential text. The earlier version added credential guidance to
    /// the first case not at all and to the second one wrongly, and a diagnosis
    /// that names the wrong cause is worse than a bare error.
    ///
    /// Message only. The error case, the control flow, and the AP teardown are
    /// unchanged, and `CancellationError` passes through untouched.
    private func diagnosed(connectFailure error: Error, pin: WiFiPathPin,
                           ssid: String, passphrase: String,
                           clientAssociationObserved: Bool,
                           lastReportedState: WiFiState?) -> Error {
        let detail: String
        let waitingReason: String?
        let interfaceWasRequired: Bool
        if let failure = error as? WiFiConnectFailure {
            detail = failure.detail
            waitingReason = failure.waitingReason
            interfaceWasRequired = failure.pinnedInterface != nil
        } else if case PocketError.transferFailed(let text) = error {
            // A connect closure a test (or a consumer) supplied, which never saw
            // an NWConnection and has no path evidence to offer — so it cannot
            // have applied a constraint either.
            detail = text
            waitingReason = nil
            interfaceWasRequired = false
        } else {
            return error
        }
        let diagnosis: WiFiConnectDiagnosis
        switch pin {
        case .hostNotOnTheDeviceSubnet(_, let held):
            // A self-assigned address outranks everything else here: it says this
            // host associated with an access point — so the credential was
            // accepted — and DHCP never answered. Sending that person to forget a
            // password would be a confident wrong cause.
            if let stranded = held.first(where: { WiFiEndpoint.isSelfAssigned($0.address) }) {
                diagnosis = .joinedButNeverLeased(interface: stranded.interfaceName)
            } else {
                // Host-side, and decisive: this process is not on the access
                // point, whichever client the device happened to see.
                diagnosis = .hostNotOnTheAccessPoint(
                    wifiJoinDiagnosis(reportedPassphrase: passphrase))
            }
        case .interface(let held, _, _):
            // An interface is configured to reach the device. That is where the
            // reasoning starts, not where it ends: the address survives a
            // disassociation, so anything that contradicts it outranks it.
            if lastReportedState == .off {
                // The device itself said its WiFi was off. Direct evidence about
                // the access point beats any inference from this host.
                diagnosis = .accessPointClosedItself
            } else if let contradiction = WiFiConnectDiagnosis.contradictionOfAddress(
                held, waitingReason: waitingReason, interfaceWasRequired: interfaceWasRequired) {
                diagnosis = .addressWithoutAnAssociation(interface: held.interfaceName,
                                                         address: held.address,
                                                         contradiction: contradiction)
            } else {
                diagnosis = .pathUnusableFromThisHost(interface: held.interfaceName,
                                                      address: held.address,
                                                      interfaceWasRequired: interfaceWasRequired,
                                                      waitingReason: waitingReason)
            }
        case .noSubnetToCompare:
            // No interface evidence: fall back to reasoning from the device's
            // report alone, exactly as this did before the pre-flight existed.
            if clientAssociationObserved {
                diagnosis = .associatedThenUnreachable
            } else if lastReportedState == .off {
                diagnosis = .accessPointClosedItself
            } else {
                diagnosis = .nothingEverJoined(wifiJoinDiagnosis(reportedPassphrase: passphrase))
            }
        }
        return PocketError.transferFailed("\(detail) — \(diagnosis.guidance(ssid: ssid))")
    }


    /// Which of this host's interfaces the connect to `endpoint` may use.
    ///
    /// Waits for an address that is not there yet, rather than reading once: on
    /// iOS the process joins the network itself and
    /// `NEHotspotConfiguration.apply` returns once the phone has associated,
    /// which can be *before* DHCP has handed it an address. That path works
    /// today, and calling a host "not on the network" while it is in the middle
    /// of joining one would regress it. A host that already holds the address —
    /// every healthy run — resolves on the first look and sleeps not at all.
    ///
    /// **The budget is evidence-driven, not a fixed guess.** `hostAddressWait`
    /// (3 s) is what a host gets when nothing suggests a join is under way. For
    /// as long as some interface holds a self-assigned `169.254` address the
    /// budget is the full `readiness.timeout` instead, because that address means
    /// this host associated with an access point and is still being refused a
    /// lease — a join trying and failing, not a host somewhere else. The ceiling
    /// is `readiness.timeout` either way, so this can never wait longer than the
    /// connect it replaces would have, and it ends in a diagnosis rather than a
    /// bare timeout however long it takes.
    func resolveWiFiPathPin(to endpoint: Network.NWEndpoint,
                            readiness: WiFiReadiness) async -> WiFiPathPin {
        let lister = hostInterfaces
        var held = lister()
        var pin = WiFiPathPin.choose(reaching: endpoint, among: held)
        guard case .hostNotOnTheDeviceSubnet = pin else { return pin }
        let clock = ContinuousClock()
        let started = clock.now
        // Floored, exactly as the session keepalive's tick is: a caller who set a
        // zero poll interval did not ask for a spin loop.
        let step = max(min(readiness.pollInterval, readiness.hostAddressWait), .milliseconds(5))
        while true {
            let budget = held.contains { WiFiEndpoint.isSelfAssigned($0.address) }
                ? readiness.timeout
                : min(readiness.timeout, readiness.hostAddressWait)
            guard clock.now - started < budget else { return pin }
            if Task.isCancelled { return pin }
            try? await Task.sleep(for: step)
            held = lister()
            pin = WiFiPathPin.choose(reaching: endpoint, among: held)
            if case .interface = pin { return pin }
        }
    }

    /// Polls `APP&WIFIS` until the device reports `.clientJoined` (2) — or
    /// `.tcpConnected` (1), which subsumes it — sending `APP&WPING`
    /// keepalives between polls so a slow (possibly human-paced) association
    /// cannot idle out the BLE link. Reports `observed: false` when
    /// `readiness.timeout` elapses without either state being observed —
    /// deliberately not an error (see the call site) — and carries the last state
    /// the device did report, which is what tells an access point that came down
    /// from one nobody joined. Throws only for caller cancellation and a dead
    /// session.
    ///
    /// `sessionActivity` is touched around every poll and every ping, exactly as
    /// `connectKeepingLinkAlive` does it: the session keepalive fires only after
    /// `pingInterval` of genuine silence, so this stretch's own traffic keeps it
    /// off the wire instead of doubling it.
    private func awaitWiFiClientJoined(_ readiness: WiFiReadiness,
                                       sessionActivity: ActivityMonitor?) async throws
        -> WiFiAssociationWait {
        let clock = ContinuousClock()
        let deadline = clock.now + readiness.timeout
        var lastPing = clock.now
        var lastReportedState: WiFiState?
        while clock.now < deadline {
            try Task.checkCancellation()
            guard isAuthenticated else { throw PocketError.notAuthenticated }
            sessionActivity?.touch()
            let response = try? await request(.wifiStatus, timeout: .seconds(2)) {
                if case .wifiState = $0 { true } else { false }
            }
            sessionActivity?.touch()
            if case .wifiState(let state)? = response {
                lastReportedState = state
                if state == .clientJoined || state == .tcpConnected {
                    return WiFiAssociationWait(observed: true, lastReportedState: state)
                }
            }
            if clock.now - lastPing >= readiness.pingInterval {
                _ = try? await request(.wifiKeepalive, timeout: .seconds(2)) { $0 == .pong }
                sessionActivity?.touch()
                lastPing = clock.now
            }
            try? await Task.sleep(for: readiness.pollInterval)
        }
        return WiFiAssociationWait(observed: false, lastReportedState: lastReportedState)
    }

    /// After a teardown, waits for the device to report its WiFi actually **off**
    /// before the next `APP&WIFIO` starts it again.
    ///
    /// A batch restart is the only place in this protocol that closes an access
    /// point and immediately reopens one, so it is the only place that can ask a
    /// device to start an AP that has not finished coming down. Whether that
    /// matters is unobserved — but the fallback is precisely what has to be
    /// trustworthy when this meets hardware: a restart that half-works would be
    /// read as the device refusing session reuse, which is the one thing the run
    /// is trying to measure.
    ///
    /// Evidence, not a guessed sleep. `APP&WIFIS` is already this sequence's state
    /// oracle, and the device is quick with it — a poll 114 ms after `APP&WIFIO`
    /// already reads `3` (`docs/protocol/ble-protocol.md`, Wi-Fi Quick Transfer
    /// step 4) — so waiting for the state it reports costs almost nothing when all
    /// is well. Bounded by `readiness.timeout`, capped at
    /// `WiFiReadiness.maximumAccessPointOffWait`.
    ///
    /// On expiry it **throws**, naming the last state seen, rather than pressing
    /// on into a state it cannot describe. The caller reports that as the reason
    /// the batch stopped, and no second `APP&WIFIO` is sent.
    private func awaitWiFiOff(_ readiness: WiFiReadiness) async throws {
        let bound = min(readiness.timeout, WiFiReadiness.maximumAccessPointOffWait)
        let clock = ContinuousClock()
        let deadline = clock.now + bound
        var lastSeen = "no answer to APP&WIFIS"
        repeat {
            try Task.checkCancellation()
            guard isAuthenticated else { throw PocketError.notAuthenticated }
            // The per-poll timeout cannot outlive the overall bound, or a single
            // silent poll would overshoot it.
            let response = try? await request(.wifiStatus, timeout: min(.seconds(2), bound)) {
                if case .wifiState = $0 { true } else { false }
            }
            if case .wifiState(let state)? = response {
                if state == .off { return }   // the AP is down; safe to start it again
                lastSeen = "MCU&WIFIS&\(state.rawValue)"
            }
            try? await Task.sleep(for: readiness.pollInterval)
        } while clock.now < deadline
        try Task.checkCancellation()   // a cancelled caller gets CancellationError
        throw PocketError.transferFailed(
            "the device did not report its WiFi off (MCU&WIFIS&0) within \(bound) of APP&WIFIC "
            + "— last state: \(lastSeen). Refusing to send APP&WIFIO on top of an access point "
            + "that may still be coming down, because a restart that half-works would look like "
            + "the device refusing to serve a second recording, which is exactly what this run "
            + "is trying to establish.")
    }

    /// Opens the TCP connection while keeping the BLE link alive with
    /// `APP&WPING` keepalives — the capture's cadence for the stretch where
    /// the phone-side stack does DHCP and connects (~24 s there).
    ///
    /// Internal (not private) and parameterised over `connect` so a hermetic
    /// test can hold the connect open until a WPING request is armed and
    /// prove the winner's cancellation cannot wedge this group; the default
    /// is the real TCP connect, so production behaviour is unchanged.
    ///
    /// Emits `DeviceEvent.wifiConnectPath` twice over a failure and once over a
    /// success: what this host's interfaces made the connect decide, before it is
    /// attempted, and — when it fails — every `NWConnection` state it went
    /// through. That second line is the verbose form of the diagnosis the thrown
    /// message carries in one sentence.
    func connectKeepingLinkAlive(
        to endpoint: Network.NWEndpoint,
        readiness: WiFiReadiness,
        pin: WiFiPathPin = .noSubnetToCompare,
        sessionActivity: ActivityMonitor? = nil,
        connect: @escaping @Sendable (Network.NWEndpoint, Duration, WiFiPathPin) async throws
            -> NWConnection = { try await TCPFetch.connect(to: $0, timeout: $1, pin: $2) }
    ) async throws -> NWConnection {
        emitEvent(.wifiConnectPath(pin.summary))
        do {
            return try await withThrowingTaskGroup(of: NWConnection?.self) { group in
                group.addTask {
                    try await connect(endpoint, readiness.timeout, pin)
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: readiness.pingInterval)
                        if Task.isCancelled { break }
                        // Touched around the ping so the session keepalive — which
                        // fires only on `pingInterval` of silence — stays off the
                        // wire while this one is already covering the gap.
                        sessionActivity?.touch()
                        _ = try? await self.request(.wifiKeepalive, timeout: .seconds(2)) {
                            $0 == .pong
                        }
                        sessionActivity?.touch()
                    }
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let connection = first else {
                    try Task.checkCancellation()
                    throw PocketError.transferFailed("wifi tcp connect never completed")
                }
                sessionActivity?.touch()
                return connection
            }
        } catch let failure as WiFiConnectFailure {
            emitEvent(.wifiConnectPath(failure.pathReport))
            throw failure
        }
    }

    /// The connected stretch: select the recording, reroute it to the
    /// socket, read exactly the announced bytes into the sink, verify. The
    /// session close (`APP&WIFIC` ×2) belongs to `closeWiFiSession`, because a
    /// batch keeps the session open across several of these.
    private func transferOverTCP(_ recording: RecordingInfo,
                                 connection: NWConnection,
                                 sink: TransferSink,
                                 sessionActivity: ActivityMonitor?,
                                 idleTimeout: Duration,
                                 onProgress: (@Sendable (Double) -> Void)?) async throws -> Data? {
        await confirmWiFiTCPConnected(sessionActivity)
        let announced = try await selectRecordingOverWiFi(recording, sessionActivity: sessionActivity)
        // Same guard as the BLE path: a 0-byte recording must fail fast and
        // truthfully — before the device is told to serve it over the socket.
        guard announced > 0 else { throw PocketError.emptyRecording }
        try await rerouteSelectionToWiFi(sessionActivity)
        try await fetchOverTCP(connection: connection, expected: announced, sink: sink,
                               sessionActivity: sessionActivity, idleTimeout: idleTimeout,
                               onProgress: onProgress)
        // A cancelled caller gets CancellationError, not a bogus size error.
        try Task.checkCancellation()
        // Integrity rules are identical to BLE by construction — exact byte
        // count + FF F3 sync live in the shared sink, which also publishes a
        // file destination only now, after both checks pass.
        let data = try sink.finalize(announced: announced)
        sessionActivity?.touch()
        onProgress?(1.0)
        return data
    }

    /// One confirmation poll, as the official app does once its TCP connect
    /// succeeds (the device answers `MCU&WIFIS&1`). Lenient: the open socket is
    /// the ground truth, so the answer is observational.
    private func confirmWiFiTCPConnected(_ sessionActivity: ActivityMonitor?) async {
        _ = try? await request(.wifiStatus, timeout: .seconds(2)) {
            if case .wifiState = $0 { true } else { false }
        }
        sessionActivity?.touch()
    }

    /// 7a. Select the recording — the same frame as a BLE download, and the
    /// device may briefly restart BLE bulk for it (the capture shows ~15 KB of
    /// leakage). No bulk sink is installed on this path, so those notifications
    /// are discarded, never mixed into the file. Returns the announced length,
    /// unvalidated: the caller decides what a 0 means (it is a fact about the
    /// recording on a fresh session and ambiguous on a reused one).
    private func selectRecordingOverWiFi(_ recording: RecordingInfo,
                                         sessionActivity: ActivityMonitor?) async throws -> Int {
        sessionActivity?.touch()
        let sizeResponse = try await request(.download(recording.id), timeout: .seconds(30)) {
            if case .transferSize = $0 { true } else { false }
        }
        sessionActivity?.touch()
        guard case .transferSize(let announced) = sizeResponse else {
            throw PocketError.unexpectedResponse("expected MCU&U&<size>")
        }
        return announced
    }

    /// 7b. `APP&U&WIFI` is a modifier on the preceding selection: it reroutes
    /// the in-progress upload to the TCP socket. The `MCU&U&WIFI` ack can lag
    /// (~1.2 s in the capture); the repeated `MCU&U&<size>` that follows it
    /// arrives unarmed and surfaces as an observational event.
    private func rerouteSelectionToWiFi(_ sessionActivity: ActivityMonitor?) async throws {
        _ = try await request(.wifiDownload, timeout: .seconds(30)) { $0 == .wifiUploadAck }
        sessionActivity?.touch()
    }

    /// Reads exactly `expected` bytes into the sink and surfaces any surplus.
    private func fetchOverTCP(connection: NWConnection,
                              expected: Int,
                              sink: TransferSink,
                              sessionActivity: ActivityMonitor?,
                              idleTimeout: Duration,
                              onProgress: (@Sendable (Double) -> Void)?) async throws {
        let received = try await TCPFetch.receive(on: connection,
                                                 expected: expected,
                                                 idleTimeout: idleTimeout,
                                                 into: sink,
                                                 sessionActivity: sessionActivity,
                                                 onProgress: onProgress)
        // Live hardware sends a short trailer past the announced length
        // (10 bytes observed; content not yet identified). The announced size
        // is authoritative — the BLE download of the same recording is
        // byte-identical at exactly that length — so surplus is surfaced as a
        // diagnostic, never treated as payload or as an error.
        if received.surplusCount > 0 {
            emitEvent(.wifiTrailerReceived(byteCount: received.surplusCount,
                                           preview: received.surplusPreview))
        }
    }
}

// MARK: - One access-point session for several recordings

/// Where a batched WiFi run puts each recording's payload.
public enum WiFiBatchDestination: Sendable {
    /// Each recording's bytes come back in its outcome's `data`. Convenient at
    /// the device's observed sizes; a large backlog should prefer `.files`,
    /// which never holds a whole recording in memory.
    case memory
    /// Each recording streams to the URL this returns, with the same file
    /// guarantee as the single-recording streaming API: on ANY failure nothing
    /// appears at the destination, and a pre-existing file there is replaced
    /// only by a fully validated download. Outcomes carry no `data`.
    case files(@Sendable (RecordingInfo) -> URL)
}

/// How one recording in a batch got its access point.
///
/// This is the batch's whole experiment in one value. On 2026-07-30 hardware
/// answered the first half of it: the device **does** serve a second
/// `APP&U&<date>&<ts>` on a live access point — it accepted a second TCP
/// connection and announced the next file's length — and the stream then reset
/// mid-transfer. So "the device refuses reuse" is disproved and "reuse works" is
/// not yet established, which is why serving and completing are separate cases
/// here.
public enum WiFiSessionUse: Sendable, Equatable {
    /// Opened the batch's first access-point session: the full
    /// `APP&SHUT → APP&WIFIS → APP&WIFI → APP&WIFIO` handshake, the join, and
    /// the association wait — about 6.5 s for the association alone.
    case openedSession
    /// Served by the session an earlier recording opened: no second join, no
    /// second handshake. This is the saving the batch exists for, and observing
    /// it on hardware is what would promote the capability out of `unverified`.
    case reusedSession
    /// Reuse was attempted and the device would not serve this recording on the
    /// live session. The session was torn down properly and a fresh one opened
    /// for this recording, so nothing was lost; `refusal` records what the
    /// device did. After this the run stops attempting reuse — a doomed attempt
    /// plus a teardown per recording would be *worse* than the
    /// one-session-per-recording behaviour it falls back to.
    case restartedSession(refusal: String)
    /// Reuse was attempted, the device **served** it — a second TCP connection,
    /// a second `APP&U&<date>&<ts>`, a second `MCU&U&<size>` — and the transfer
    /// then broke, with `bytesDiscarded` payload bytes already received. Those
    /// bytes were thrown away, the session was torn down and reopened, and this
    /// recording was transferred again from byte zero on a session of its own.
    ///
    /// Observed on hardware 2026-07-30: `ECONNRESET` after the second file's
    /// length was announced. It is the most informative outcome a reuse attempt
    /// has — it separates "the device will not do this" from "the device will do
    /// this and something else then fails" — and before this case existed it was
    /// reported as neither, because the run simply stopped.
    ///
    /// Like `restartedSession`, it ends reuse for the rest of the run: a session
    /// that broke once is not evidence for trying again, and a doomed attempt
    /// plus a teardown per recording would be worse than falling back.
    case restartedAfterReuseBroke(interruption: String, bytesDiscarded: Int)
    /// Reuse had already been ruled out by an earlier `restartedSession` or
    /// `restartedAfterReuseBroke`, so this recording opened its own session
    /// without re-attempting it. Exactly the behaviour of calling
    /// `downloadOverWiFi(_:)` once per recording.
    case ownSession

    /// True when this recording was asked to ride a session another recording
    /// opened — whatever the device then did about it.
    public var attemptedReuse: Bool {
        switch self {
        case .reusedSession, .restartedSession, .restartedAfterReuseBroke: true
        case .openedSession, .ownSession: false
        }
    }
}

/// What one recording's transfer produced inside a batch.
public struct WiFiRecordingOutcome: Sendable, Equatable {
    public let recording: RecordingInfo
    public let sessionUse: WiFiSessionUse
    /// Payload bytes delivered — the device's announced length, which the
    /// integrity check proved was received exactly.
    public let byteCount: Int
    /// The payload, for a `.memory` destination; `nil` for `.files`, where the
    /// bytes are already at their validated path.
    public let data: Data?

    public init(recording: RecordingInfo, sessionUse: WiFiSessionUse,
                byteCount: Int, data: Data?) {
        self.recording = recording
        self.sessionUse = sessionUse
        self.byteCount = byteCount
        self.data = data
    }
}

/// The recording a batch stopped on, and what it left untried.
public struct WiFiBatchStop: Sendable, Equatable {
    public let recording: RecordingInfo
    /// How this recording got — or failed to get — its access point before the
    /// run stopped on it; `nil` when no session was ever opened for it.
    ///
    /// Carried here for the same reason `delivered` carries it: a recording the
    /// run stopped on is exactly where the most informative reuse attempt tends
    /// to live, and reading reuse off delivered recordings alone made the
    /// 2026-07-30 run report `INCONCLUSIVE — no recording was ever asked to reuse
    /// a session` directly underneath a log of a second selection being served on
    /// one. An experiment whose purpose is learning what happens when reuse fails
    /// cannot credit reuse only when it succeeds.
    public let sessionUse: WiFiSessionUse?
    /// One line naming the failure.
    public let reason: String
    /// The failure itself when it was one of this package's, so a caller can
    /// branch on it — e.g. drop a `.emptyRecording` and re-batch the rest.
    /// `nil` for anything else (a custom joiner's own error type, say).
    public let error: PocketError?
    /// The recordings after `recording`: never attempted, never touched.
    /// Deciding what to do about them — a BLE retry, a later batch, nothing —
    /// is the caller's call, which is why the run stops instead of guessing.
    public let remaining: [RecordingInfo]

    public init(recording: RecordingInfo, sessionUse: WiFiSessionUse? = nil, reason: String,
                error: PocketError?, remaining: [RecordingInfo]) {
        self.recording = recording
        self.sessionUse = sessionUse
        self.reason = reason
        self.error = error
        self.remaining = remaining
    }
}

/// The result of one batched WiFi run.
public struct WiFiBatchResult: Sendable, Equatable {
    /// One entry per recording delivered, in the order requested. A run that
    /// stops partway still reports these — a failure on recording 4 of 10 must
    /// not lose 1–3.
    public let delivered: [WiFiRecordingOutcome]
    /// `nil` ⇔ every requested recording was delivered.
    public let stopped: WiFiBatchStop?

    public init(delivered: [WiFiRecordingOutcome], stopped: WiFiBatchStop?) {
        self.delivered = delivered
        self.stopped = stopped
    }

    public var isComplete: Bool { stopped == nil }

    /// Every session use the run produced, in order — the recording it stopped
    /// on included.
    ///
    /// Every reuse question below is answered from this and never from
    /// `delivered` alone. A reuse attempt that ended the run is still a reuse
    /// attempt, and it is usually the most informative one there is.
    public var sessionUses: [WiFiSessionUse] {
        delivered.map(\.sessionUse) + (stopped?.sessionUse.map { [$0] } ?? [])
    }

    /// True when some recording was asked to ride a session another recording
    /// opened — whatever the device then did about it, and whether or not that
    /// recording was ultimately delivered. `false` is the only honest basis for
    /// calling a run inconclusive.
    public var didAttemptReuse: Bool { sessionUses.contains { $0.attemptedReuse } }

    /// True when at least one recording was **delivered** over a session another
    /// recording had already opened: reuse not merely served but completed. The
    /// device serving a second selection is a weaker (and now observed) fact —
    /// see `reuseInterruptions`.
    public var didReuseSession: Bool { sessionUses.contains(.reusedSession) }

    /// Every refusal observed, in order: the device declining to serve a
    /// recording on a live session, decided before a payload byte flowed.
    public var refusals: [String] {
        sessionUses.compactMap {
            if case .restartedSession(let refusal) = $0 { refusal } else { nil }
        }
    }

    /// Every reuse the device **served** and that then broke mid-transfer, in
    /// order, with the payload bytes discarded each time.
    ///
    /// Non-empty is the 2026-07-30 hardware finding: the device does accept a
    /// second TCP connection and a second `APP&U&<date>&<ts>` on a live access
    /// point, and the transfer then reset. It is neither a refusal nor a working
    /// reuse, and reporting it as either would misstate the only run that has
    /// ever produced it.
    public var reuseInterruptions: [(interruption: String, bytesDiscarded: Int)] {
        sessionUses.compactMap {
            if case .restartedAfterReuseBroke(let interruption, let bytes) = $0 {
                (interruption: interruption, bytesDiscarded: bytes)
            } else {
                nil
            }
        }
    }

    /// How many access-point sessions the *delivered* recordings needed. `1`
    /// with several recordings delivered is the win; `delivered.count` is the
    /// fallback. Counted over `delivered` only — a session opened for the
    /// recording the run stopped on is not included, because that recording
    /// produced no outcome.
    public var sessionsOpened: Int {
        delivered.filter { $0.sessionUse != .reusedSession }.count
    }

    /// One line for a log or a harness transcript.
    public var summary: String {
        let head = "\(delivered.count) recording(s) delivered over \(sessionsOpened) "
            + "access-point session(s)"
        let reuse: String
        if didReuseSession {
            reuse = " — the device DID serve a second selection on a live session"
        } else if let broken = reuseInterruptions.first {
            reuse = " — the device served a second selection on a live session and the transfer "
                + "then failed after \(broken.bytesDiscarded) byte(s): \(broken.interruption)"
        } else if let refusal = refusals.first {
            reuse = " — the device refused a second selection: \(refusal)"
        } else {
            reuse = ""
        }
        guard let stopped else { return head + reuse }
        return head + reuse + "; stopped on \(stopped.recording.id.timestamp): \(stopped.reason)"
    }

    /// What this run established about serving a second `APP&U&<date>&<ts>` on a
    /// live access point.
    ///
    /// Typed, and derived from `sessionUses` rather than from `delivered`, for a
    /// reason worth stating plainly: on 2026-07-30 the CLI printed
    /// `INCONCLUSIVE — no recording was ever asked to reuse a session` directly
    /// beneath a log of a second selection being served on one. Reuse was
    /// credited only when it succeeded, and the recording carrying the attempt
    /// was the one the run stopped on, so the most informative outcome the
    /// experiment can produce was the one outcome it could not report. An
    /// experiment for learning what happens when something fails must be able to
    /// say that it failed.
    public var reuseVerdict: WiFiReuseVerdict {
        if let broken = reuseInterruptions.first {
            return didReuseSession
                ? .servedButDidNotHold(interruption: broken.interruption,
                                       bytesDiscarded: broken.bytesDiscarded)
                : .servedThenBroke(interruption: broken.interruption,
                                   bytesDiscarded: broken.bytesDiscarded)
        }
        if didReuseSession { return .works(sessions: sessionsOpened, recordings: delivered.count) }
        if let refusal = refusals.first { return .refused(refusal) }
        // Never asked. Which of the two reasons it was matters: telling an
        // operator to "run this again with two or more recordings" when they
        // passed three and the run stopped on the first sends somebody to fix a
        // problem they do not have.
        return .notAttempted(stoppedOn: stopped?.recording.id.timestamp)
    }
}

/// What one batched run can honestly claim about session reuse. Typed rather
/// than only prose so a consumer — and the test suite — can branch on the
/// finding instead of matching strings.
///
/// Four terms, because the device turns out to have three distinguishable
/// behaviours plus a run that never asked. **Serving a second selection and
/// completing a transfer over one are separate facts**, and the only run that
/// has ever reached hardware is the one where the first happened without the
/// second — which the older three-term vocabulary (works / refused /
/// inconclusive) could only report as "inconclusive".
public enum WiFiReuseVerdict: Sendable, Equatable {
    /// A recording was delivered over a session another recording opened, and no
    /// reuse in the run broke. The capability, demonstrated.
    case works(sessions: Int, recordings: Int)
    /// Reuse both worked and broke in the same run: a reliability finding rather
    /// than a capability one.
    case servedButDidNotHold(interruption: String, bytesDiscarded: Int)
    /// The device served a second selection on a live session — a second TCP
    /// connection, a second `MCU&U&<size>` — and the transfer then failed.
    /// Observed on hardware 2026-07-30. It settles the older question in the
    /// POSITIVE (the device does not refuse reuse) and opens a new one (whether
    /// the reset is avoidable at all, or device behaviour to fall back from).
    case servedThenBroke(interruption: String, bytesDiscarded: Int)
    /// The device declined to serve a recording on a live session, before any
    /// payload byte flowed.
    case refused(String)
    /// No recording was ever asked to ride another's session. `stoppedOn` names
    /// the recording the run stopped on, when that is why.
    case notAttempted(stoppedOn: String?)

    /// One line, in the register the rest of this package uses for findings.
    public var headline: String {
        switch self {
        case .works:
            return "SESSION REUSE WORKS on this firmware."
        case .servedButDidNotHold:
            return "SESSION REUSE WORKS BUT DID NOT HOLD on this firmware."
        case .servedThenBroke:
            return "THE DEVICE SERVED A SECOND SELECTION ON A LIVE SESSION, AND THE TRANSFER "
                + "THEN FAILED."
        case .refused:
            return "SESSION REUSE IS REFUSED on this firmware."
        case .notAttempted:
            return "INCONCLUSIVE — no recording was ever asked to reuse a session."
        }
    }
}

extension WiFiBatchResult {
    /// The verdict as the paragraphs a transcript carries: the headline, what the
    /// device did, and what to do with the finding.
    ///
    /// In the library rather than in the CLI, alongside
    /// `AccessPointLifetime.verdictText`, for the same reason: it is a statement
    /// about what this run established, it has been wrong before, and a
    /// executable target cannot be tested here.
    public func reuseVerdictText(elapsed: Duration) -> String {
        let over = "\(delivered.count) recording(s) delivered over \(sessionsOpened) "
            + "access-point session(s) in \(elapsedSecondsText(elapsed))."
        let verdict = reuseVerdict
        var body = [verdict.headline]
        switch verdict {
        case .works:
            body.append("\(over) The device served a second APP&U&<date>&<ts> while its AP was "
                + "up AND the transfer over it completed. Promote the capability from "
                + "`unverified` in docs/protocol/ble-protocol.md and the README, and record this "
                + "transcript as the evidence.")
        case .servedButDidNotHold(let interruption, let bytes):
            body.append("\(over) At least one recording came off a reused session intact, and at "
                + "least one other was served on a live session and then failed after "
                + "\(bytes) byte(s): \(interruption)")
            body.append("That is a reliability finding, not a capability one — the device will do "
                + "this, and something about doing it repeatedly does not survive. Record BOTH in "
                + "docs/protocol/ble-protocol.md; a run that only worked would not have shown the "
                + "second half.")
        case .servedThenBroke(let interruption, let bytes):
            body.append("\(over) This settles the older question in the POSITIVE: the device does "
                + "NOT refuse reuse. It accepted a second TCP connection and announced the next "
                + "file's length. What then failed was the transfer: \(interruption)")
            body.append("\(bytes) partial byte(s) were discarded and the recording was fetched "
                + "again from byte zero on a session of its own, so this run delivered every "
                + "recording a one-at-a-time sync would have. Whether the failure is avoidable at "
                + "all is the open question now: it may be this client's socket handling, or it "
                + "may be device behaviour we can only fall back from. Record this transcript in "
                + "docs/protocol/ble-protocol.md against the reuse section.")
        case .refused(let refusal):
            body.append("The device would not serve a recording on a live session: \(refusal)")
            body.append("The run fell back to one session per recording — \(over) — which is "
                + "exactly the pre-existing behaviour. Nothing was lost and no access point was "
                + "left up. Record the refusal in docs/protocol/ble-protocol.md: it settles the "
                + "open question in the negative, which is just as useful an answer.")
        case .notAttempted(let stoppedOn):
            body.append(over)
            body.append(stoppedOn.map {
                "The run stopped on \($0) before a second recording could be asked, so it says "
                + "nothing about reuse either way — fix that failure first."
            } ?? "Reuse is only exercised from the SECOND recording onwards, so run this again "
                + "with two or more transferable recordings.")
        }
        return body.joined(separator: "\n\n")
    }
}

/// One line naming a failure, for a batch report a caller may log or print.
/// The string-carrying `PocketError` cases already hold a sentence, so their
/// detail is used verbatim; the rest get prose here rather than an enum dump.
/// Exhaustive on purpose — a new `PocketError` case must be given a sentence.
func wifiFailureText(_ error: Error) -> String {
    // A connect failure carries structured evidence and renders its own sentence.
    // `String(describing:)` on the struct would dump the fields instead, into the
    // one line a batch prints as its stop reason.
    if let connect = error as? WiFiConnectFailure { return connect.detail }
    guard let pocket = error as? PocketError else { return String(describing: error) }
    switch pocket {
    case .transferFailed(let detail):     return detail
    case .wifiJoinFailed(let detail):     return "could not join the device's WiFi AP: \(detail)"
    case .unexpectedResponse(let detail): return "protocol drift: \(detail)"
    case .busy(let what):                 return what
    case .emptyRecording:
        return "the device announced 0 bytes for this recording (MCU&U&0)"
    case .timeout(let command):
        return "no reply matching what this client expects for \(command.wireFormat)"
    case .unknownCommand(let command):
        return "the device answered MCU&UNKNOWN to \(command.wireFormat)"
    case .sizeMismatch(let expected, let received):
        return "received \(received) of \(expected) announced bytes"
    case .notMP3:
        return "the payload did not start with an MP3 frame header"
    case .notAuthenticated:
        return "the BLE session is no longer authenticated"
    case .disconnected:
        return "the BLE link dropped"
    case .authRejected:
        return "the device rejected the session key"
    case .deviceNotFound(let identifier):
        return "this system does not know peripheral \(identifier)"
    }
}

extension PocketSession {
    /// Transfers several recordings over **one** access-point session: the AP
    /// comes up once, every recording is fetched, and it closes once.
    ///
    /// **Why this exists.** A session is not cheap.
    /// `APP&SHUT → APP&WIFIS → APP&WIFI → APP&WIFIO`, the join, and the
    /// association wait cost about 6.5 s for the association alone, and on iOS
    /// `NEHotspotConfiguration.joinOnce` makes the OS discard the configuration
    /// when the phone disassociates — so a ten-recording sync done one session
    /// at a time asks the person to join the network **ten times** and pays the
    /// handshake ten times. Watched happening on hardware, 2026-07-29, across
    /// ~354 MB in 30–50 MB files.
    ///
    /// **The reuse itself is still `unverified`, but no longer unobserved.** On
    /// 2026-07-30 hardware served a second `APP&U&<date>&<ts>` on a live access
    /// point — a second TCP connection accepted, the next file's length announced
    /// — and the stream then reset mid-transfer. So the device does not refuse
    /// reuse; reuse does not yet work either.
    ///
    /// **The invariant, which holds however that resolves: this never delivers
    /// fewer recordings than the same list transferred one at a time would.**
    /// Reuse is attempted and every way it can fail falls back to a session
    /// opened for that recording. The device declining to serve it, and the
    /// device serving it and the transfer then breaking, are recorded as
    /// different findings (`.restartedSession` and `.restartedAfterReuseBroke`)
    /// because they answer different questions — but they get the same recovery,
    /// because a recording that has not yet had a session of its own has not yet
    /// had the chance the one-at-a-time path would have given it. The session is
    /// torn down properly (`APP&SHUT` + `APP&WIFIC`, then leave the network), any
    /// partial payload is discarded rather than published, a fresh session is
    /// opened, and the recording is transferred again from byte zero; that retry
    /// is exactly one, and reuse is not attempted again in the run. The worst
    /// case is therefore exactly the one-session-per-recording behaviour of
    /// `downloadOverWiFi(_:)`, never a wedged device, a half-open AP, or a
    /// truncated file. `WiFiBatchResult.didReuseSession`, `.refusals` and
    /// `.reuseInterruptions` say which happened; `pocket-cli sync-wifi` exists to
    /// run the experiment on hardware.
    ///
    /// **Partial progress is kept.** The run stops at the first recording it
    /// cannot deliver and reports what it already delivered — a failure on
    /// recording 4 of 10 must not lose 1–3 — leaving the rest untouched for the
    /// caller to decide about. That is not an error, so it does not throw:
    /// `WiFiBatchResult.stopped` carries the recording, the reason, and what was
    /// left. It throws only for what makes the batch impossible
    /// (`PocketError.busy` when another transfer holds the device's single
    /// transfer engine, `PocketError.notAuthenticated` before the handshake) and
    /// for caller cancellation.
    ///
    /// Every exit path closes the access point, cancellation included: a still-
    /// broadcasting AP competes with BLE for the same 2.4 GHz radio. An empty
    /// `recordings` array is a no-op that never touches the radio.
    ///
    /// Claims the same exclusive transfer slot as `downloadOverBLE`, the live
    /// stream, and the single-recording WiFi path — for the whole batch.
    public func downloadOverWiFi(
        _ recordings: [RecordingInfo],
        into destination: WiFiBatchDestination = .memory,
        endpointOverride: Network.NWEndpoint? = nil,
        joiner: HotspotJoining = SystemHotspotJoiner(),
        idleTimeout: Duration = .seconds(10),
        readiness: WiFiReadiness = WiFiReadiness(),
        onProgress: (@Sendable (RecordingID, Double) -> Void)? = nil
    ) async throws -> WiFiBatchResult {
        guard !recordings.isEmpty else { return WiFiBatchResult(delivered: [], stopped: nil) }
        try beginTransfer()
        defer { endTransfer() }   // covers every exit path below
        return try await runWiFiBatch(recordings, destination: destination,
                                      endpointOverride: endpointOverride, joiner: joiner,
                                      idleTimeout: idleTimeout, readiness: readiness,
                                      onProgress: onProgress)
    }

    /// What one recording's attempt did.
    ///
    /// `refused` and `broke` are the two non-terminal cases, and both are
    /// produced **only** on a reused session — a session opened for this very
    /// recording has nothing left to fall back to, so its failures are `failed`.
    /// The difference between them is not the recovery (both restart) but the
    /// finding: `refused` means the device would not serve this recording at all,
    /// `broke` means it did and the transfer then failed.
    private enum WiFiAttempt {
        case delivered(byteCount: Int, data: Data?)
        /// The live session would not serve this recording. Decided before a
        /// payload byte flowed, so there is nothing to discard.
        case refused(String)
        /// The live session served this recording and the transfer then failed,
        /// after `bytesDiscarded` payload bytes — which have already been thrown
        /// away by the time this is returned.
        case broke(String, bytesDiscarded: Int)
        case failed(String, PocketError?)
        case cancelled
    }

    private func runWiFiBatch(
        _ recordings: [RecordingInfo],
        destination: WiFiBatchDestination,
        endpointOverride: Network.NWEndpoint?,
        joiner: HotspotJoining,
        idleTimeout: Duration,
        readiness: WiFiReadiness,
        onProgress: (@Sendable (RecordingID, Double) -> Void)?
    ) async throws -> WiFiBatchResult {
        var delivered: [WiFiRecordingOutcome] = []
        var live: WiFiSessionHandle?
        /// Set by the first refusal. From then on every recording opens and
        /// closes its own session and reuse is never attempted again.
        var reuseRuledOut = false

        /// Set by the first actual teardown. Only a run that has already closed an
        /// access point can ask the device to start one that is still coming down,
        /// so only such a run waits for `MCU&WIFIS&0` first — the very first
        /// session opens exactly as the capture-verified single-transfer path does,
        /// with no extra frame.
        var hasClosedASession = false

        /// The single teardown path. Clearing `live` first makes it idempotent,
        /// so no exit can close twice and none can forget.
        func closeLive(aborting: Bool) async {
            guard let session = live else { return }
            live = nil
            hasClosedASession = true
            await closeWiFiSession(session, joiner: joiner, aborting: aborting)
        }

        /// Opens a session, first waiting out any access point this run already
        /// closed. `awaitWiFiOff` throws when the device never reports itself off,
        /// and that throw must reach the caller: pressing on would send
        /// `APP&WIFIO` into a state nothing here can describe.
        func openSession() async throws -> WiFiSessionHandle {
            if hasClosedASession { try await awaitWiFiOff(readiness) }
            return try await openWiFiSession(joiner: joiner, readiness: readiness)
        }

        /// `use` is what this recording's access point turned out to be, carried
        /// onto the stop so a run that ended on a reuse attempt still reports it.
        func stopping(at index: Int, using use: WiFiSessionUse?,
                      _ reason: String, _ error: PocketError?) -> WiFiBatchResult {
            WiFiBatchResult(
                delivered: delivered,
                stopped: WiFiBatchStop(recording: recordings[index], sessionUse: use,
                                       reason: reason, error: error,
                                       remaining: Array(recordings[(index + 1)...])))
        }

        do {
            for (index, recording) in recordings.enumerated() {
                if Task.isCancelled {
                    await closeLive(aborting: true)
                    throw CancellationError()
                }

                // Acquire a session. `live != nil` implies reuse is still on the
                // table: the loop closes the session after every recording once
                // it has been ruled out.
                let session: WiFiSessionHandle
                var use: WiFiSessionUse
                if let existing = live {
                    session = existing
                    use = .reusedSession
                } else {
                    do {
                        session = try await openSession()
                    } catch is CancellationError {
                        throw CancellationError()   // nothing open: openWiFiSession cleaned up
                    } catch {
                        return stopping(at: index, using: nil,
                                        wifiFailureText(error), error as? PocketError)
                    }
                    live = session
                    use = reuseRuledOut ? .ownSession : .openedSession
                }

                var attempt = await transferOneRecording(
                    recording, on: session, reusingSession: use == .reusedSession,
                    destination: destination, endpointOverride: endpointOverride,
                    idleTimeout: idleTimeout, readiness: readiness, onProgress: onProgress)

                // Reuse did not work for this recording — either the device
                // would not serve it, or it served it and the transfer broke.
                //
                // **The recovery is the same and it is not optional.** A batch
                // must never deliver fewer recordings than the same list
                // transferred one at a time would, and one at a time this
                // recording would have got a session opened for it. It has not
                // had one yet, so it gets one now. Until 2026-07-30 only the
                // first branch existed, and a mid-stream reset on a reused
                // session — which is what hardware actually does — stopped the
                // whole run with one of two recordings delivered.
                let reuseFailure: WiFiSessionUse?
                switch attempt {
                case .refused(let refusal):
                    reuseFailure = .restartedSession(refusal: refusal)
                case .broke(let interruption, let discarded):
                    reuseFailure = .restartedAfterReuseBroke(interruption: interruption,
                                                             bytesDiscarded: discarded)
                default:
                    reuseFailure = nil
                }
                if let reuseFailure {
                    reuseRuledOut = true
                    await closeLive(aborting: true)
                    use = reuseFailure
                    do {
                        let fresh = try await openSession()
                        live = fresh
                        // `reusingSession: false`, so this attempt can no longer
                        // come back `.refused` or `.broke`: the retry is exactly
                        // one, and its verdict is final.
                        attempt = await transferOneRecording(
                            recording, on: fresh, reusingSession: false,
                            destination: destination, endpointOverride: endpointOverride,
                            idleTimeout: idleTimeout, readiness: readiness, onProgress: onProgress)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return stopping(at: index, using: use,
                                        wifiFailureText(error), error as? PocketError)
                    }
                }

                switch attempt {
                case .delivered(let byteCount, let data):
                    delivered.append(WiFiRecordingOutcome(recording: recording, sessionUse: use,
                                                          byteCount: byteCount, data: data))
                case .failed(let reason, let error):
                    await closeLive(aborting: true)
                    return stopping(at: index, using: use, reason, error)
                case .cancelled:
                    await closeLive(aborting: true)
                    throw CancellationError()
                case .refused(let refusal):
                    // Unreachable: a refusal is retried on a FRESH session
                    // above, where setup failures come back as `.failed`.
                    // Handled rather than trapped — a wedged AP is worse than
                    // an odd error.
                    await closeLive(aborting: true)
                    return stopping(at: index, using: use,
                                    "internal: unhandled access-point session refusal: \(refusal)",
                                    nil)
                case .broke(let interruption, _):
                    // Unreachable for the same reason.
                    await closeLive(aborting: true)
                    return stopping(at: index, using: use,
                                    "internal: unhandled access-point session interruption: "
                                        + interruption,
                                    nil)
                }

                // Once reuse is ruled out, each recording closes its own
                // session — exactly what calling the single-recording API in a
                // loop does.
                if reuseRuledOut { await closeLive(aborting: false) }
            }
        } catch {
            await closeLive(aborting: true)
            throw error
        }
        await closeLive(aborting: false)
        return WiFiBatchResult(delivered: delivered, stopped: nil)
    }

    /// One recording on an already-open session.
    ///
    /// The split that matters is between the setup phase — the state check, the
    /// TCP connect, the selection, the reroute — and the payload phase. Nothing
    /// of this recording has been read during setup, so a setup failure on a
    /// REUSED session is the device declining a second selection and a clean
    /// restart costs only time. From the first payload byte on, a failure is
    /// this recording's transfer failing and the batch stops.
    private func transferOneRecording(
        _ recording: RecordingInfo,
        on session: WiFiSessionHandle,
        reusingSession: Bool,
        destination: WiFiBatchDestination,
        endpointOverride: Network.NWEndpoint?,
        idleTimeout: Duration,
        readiness: WiFiReadiness,
        onProgress: (@Sendable (RecordingID, Double) -> Void)?
    ) async -> WiFiAttempt {
        // Is the session still there at all? The device is the only witness to
        // its own AP, and its answer distinguishes the two ways reuse can die
        // before anything is even attempted. Asked before anything is allocated,
        // so a refusal here costs nothing but the round-trip.
        if reusingSession, let state = await liveWiFiState(session) {
            switch state {
            case .off:
                return .refused("the device reported its WiFi off (MCU&WIFIS&0) after the "
                                + "previous recording — it closed the session itself")
            case .accessPointUp:
                return .refused("the device reports its AP up with no associated client "
                                + "(MCU&WIFIS&3) — this host left the network between "
                                + "recordings (iOS discards a joinOnce configuration on "
                                + "disassociation)")
            case .clientJoined, .tcpConnected:
                break   // still associated; carry on
            }
        }

        let sink: TransferSink
        switch destination {
        case .memory:
            sink = TransferSink.memory()
        case .files(let url):
            do { sink = try TransferSink.file(destination: url(recording)) }
            catch { return .failed(wifiFailureText(error), error as? PocketError) }
        }

        // The batch reports progress per recording; the transfer machinery below
        // is shared with the single-recording path and takes a bare fraction.
        let id = recording.id
        let progress: (@Sendable (Double) -> Void)?
        if let report = onProgress {
            progress = { fraction in report(id, fraction) }
        } else {
            progress = nil
        }

        // A fresh TCP connection per recording: the device closes the socket at
        // `MCU&OFF` (TCP FIN in the capture, at the same instant), so the previous
        // one is spent. The AP and the association are what carry over, not the
        // socket. Its own do/catch, not folded into the selection below, because
        // from the moment it returns EVERY exit must cancel it — a refusal that
        // left a socket open would leak one per recording.
        let endpoint = endpointOverride ?? WiFiEndpoint.default
        let pin = await resolveWiFiPathPin(to: endpoint, readiness: readiness)
        let connection: NWConnection
        do {
            connection = try await connectKeepingLinkAlive(
                to: endpoint, readiness: readiness, pin: pin,
                sessionActivity: session.activity)
        } catch is CancellationError {
            sink.abort()
            return .cancelled
        } catch {
            sink.abort()
            if reusingSession {
                // Not terminal: the live session would not take a second socket,
                // so this recording gets a fresh one. No diagnosis belongs on a
                // refusal — the run is about to repair it itself. The lead-in is
                // deliberately about the session rather than about the device's
                // listener, because the pre-flight can now refuse here too: this
                // host having left the network between recordings is repaired by
                // the very same reopen (which asks for the join again).
                return .refused("the live session would not take a second TCP connection on "
                                + ":\(WiFiEndpoint.devicePort): " + wifiFailureText(error))
            }
            // A terminal connect failure, and the one the hardware run of
            // 2026-07-28 hit. It must carry the same diagnosis the
            // single-recording path attaches (`diagnosed(connectFailure:…)`),
            // because THIS is the text a batch prints as its stop reason: the
            // enrichment 0.1.2 added for exactly this failure never reached the
            // transcript, which reported only `wifi tcp connect timed out after
            // 30.0 seconds` and left the cause to be found by hand.
            let enriched = diagnosed(connectFailure: error, pin: pin, ssid: session.ssid,
                                     passphrase: session.passphrase,
                                     clientAssociationObserved: session.clientAssociationObserved,
                                     lastReportedState: session.lastReportedState)
            return .failed(wifiFailureText(enriched), enriched as? PocketError)
        }

        let announced: Int
        do {
            await confirmWiFiTCPConnected(session.activity)
            announced = try await selectRecordingOverWiFi(recording,
                                                          sessionActivity: session.activity)
        } catch is CancellationError {
            connection.cancel(); sink.abort()
            return .cancelled
        } catch {
            connection.cancel(); sink.abort()
            let text = wifiFailureText(error)
            return reusingSession
                ? .refused("the device would not serve another recording on the live session: \(text)")
                : .failed(text, error as? PocketError)
        }

        // A 0-byte announcement is a fact about the recording, not a refusal:
        // 0-second recordings exist on hardware, and a fresh session would
        // announce the same 0. It is admittedly ambiguous on a reused session —
        // the device *could* be declining by announcing nothing — but treating
        // it as a refusal would tear down a working session every time a
        // genuinely empty recording turned up in a batch. Recorded as an open
        // question in docs/protocol/ble-protocol.md.
        guard announced > 0 else {
            connection.cancel()
            sink.abort()
            return .failed(wifiFailureText(PocketError.emptyRecording), .emptyRecording)
        }

        do {
            try await rerouteSelectionToWiFi(session.activity)
        } catch is CancellationError {
            connection.cancel(); sink.abort()
            return .cancelled
        } catch {
            connection.cancel(); sink.abort()
            let text = wifiFailureText(error)
            return reusingSession
                ? .refused("the device acked a second selection but would not reroute it to the "
                           + "socket (APP&U&WIFI): \(text)")
                : .failed(text, error as? PocketError)
        }

        // Payload phase. Past here the device is pushing this recording's bytes.
        //
        // On a session opened for this recording, a failure here is the
        // transfer failing and the batch stops. On a REUSED one it is not the
        // end of the question: the device has now demonstrably served the
        // selection, so what failed is this attempt, and the recording has still
        // never been given a session of its own. It gets one.
        do {
            try await fetchOverTCP(connection: connection, expected: announced, sink: sink,
                                   sessionActivity: session.activity, idleTimeout: idleTimeout,
                                   onProgress: progress)
            try Task.checkCancellation()
            let data = try sink.finalize(announced: announced)
            session.activity.touch()
            progress?(1.0)
            return .delivered(byteCount: announced, data: data)
        } catch is CancellationError {
            connection.cancel(); sink.abort()
            return .cancelled
        } catch {
            connection.cancel()
            // Read before aborting, and abort before returning either way: the
            // partial payload must never survive a restart. `abort()` closes the
            // temp handle and removes the `.partial-<uuid>` companion, so a file
            // destination is untouched — a half-written recording left where a
            // later run could mistake it for a finished download is a worse
            // outcome than the failure that produced it, and the retry writes a
            // fresh temp of its own from byte zero.
            let partial = sink.bytesReceived
            sink.abort()
            let text = wifiFailureText(error)
            return reusingSession
                ? .broke(text, bytesDiscarded: partial)
                : .failed(text, error as? PocketError)
        }
    }

    /// The device's own view of its WiFi state, or `nil` when it did not answer.
    /// Silence is not evidence — a firmware that stops answering `APP&WIFIS`
    /// must not be read as having closed the session — so the caller carries on
    /// and lets the selection decide.
    private func liveWiFiState(_ session: WiFiSessionHandle) async -> WiFiState? {
        session.activity.touch()
        let response = try? await request(.wifiStatus, timeout: .seconds(2)) {
            if case .wifiState = $0 { true } else { false }
        }
        session.activity.touch()
        guard case .wifiState(let state)? = response else { return nil }
        return state
    }
}
