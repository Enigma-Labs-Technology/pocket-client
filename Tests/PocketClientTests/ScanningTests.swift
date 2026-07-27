// pocket-client/Tests/PocketClientTests/ScanningTests.swift
//
// The scan list (`BLEScanList`) and the radio-state mapping are the pure
// core of `PocketScanner` — everything a pairing picker's correctness rides
// on: what enters the list, what one more advertisement changes, how rows
// are ordered (and never reordered), and when silence removes one. These
// tests drive that core directly, with time injected, so no radio is needed.
//
// The CoreBluetooth shell around it (central construction, delegate feed,
// scan start/stop on subscriber count, the prune timer) is deliberately NOT
// tested here: CoreBluetooth cannot be faked (standing decision — no mock CB
// layer), and constructing a real central would touch the radio stack and
// its permission prompt. The shell is compile-verified only; the hardware
// harness (`pocket-cli scan`) proves it live. Likewise `connect(to:)` — its
// retrieve-and-connect path shares BLETransport's untestable delegate chain.
//
// (Mutating calls are bound to locals before `#expect` — the macro's
// captured receiver is immutable.)
import CoreBluetooth
import Testing
@testable import PocketClient

private let epoch = ContinuousClock().now
private func at(_ seconds: Double) -> ContinuousClock.Instant {
    epoch.advanced(by: .seconds(seconds))
}
private func makeList() -> BLEScanList {
    BLEScanList(namePrefix: PocketGATT.namePrefix)   // default 10 s age-out
}
private let deviceA = UUID()
private let deviceB = UUID()

// MARK: - Membership

@Test func repeatedAdvertisementsCollapseToOneRowWithTheLatestRSSI() {
    var list = makeList()
    let appeared = list.record(name: "PKT01_AB12", identifier: deviceA, rssi: -60, at: at(0))
    let refreshed = list.record(name: "PKT01_AB12", identifier: deviceA, rssi: -48, at: at(1))
    #expect(appeared)
    #expect(refreshed)   // a new reading is a visible change
    #expect(list.nearby == [NearbyPocket(identifier: deviceA, name: "PKT01_AB12", rssi: -48)])
}

/// Only our device family enters — same name gate as connect and
/// restoration: wrong prefix, nil name, and a truncated prefix are all
/// rejected; the bare prefix itself matches.
@Test func advertisersOutsideTheNamePrefixNeverEnterTheList() {
    var list = makeList()
    let wrongPrefix = list.record(name: "OTHER_AB12", identifier: deviceA, rssi: -40, at: at(0))
    let nameless = list.record(name: nil, identifier: deviceA, rssi: -40, at: at(0))
    let truncated = list.record(name: "PKT01", identifier: deviceA, rssi: -40, at: at(0))
    #expect(!wrongPrefix && !nameless && !truncated)
    #expect(list.nearby.isEmpty)
    let bare = list.record(name: "PKT01_", identifier: deviceA, rssi: -40, at: at(0))
    #expect(bare)
}

// MARK: - Ordering (the damping policy)

/// First-seen order is the reorder damping: two devices whose RSSI trades
/// places on every advertisement — normal jitter — must never swap rows,
/// or the list reshuffles under the user's thumb as they reach to tap.
@Test func rowsKeepFirstSeenOrderHoweverRSSIJitters() {
    var list = makeList()
    _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(0))
    _ = list.record(name: "PKT01_BBBB", identifier: deviceB, rssi: -80, at: at(0))
    for (rssiA, rssiB) in [(-90, -40), (-45, -85), (-70, -30)] {
        _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: rssiA, at: at(1))
        _ = list.record(name: "PKT01_BBBB", identifier: deviceB, rssi: rssiB, at: at(1))
        #expect(list.nearby.map(\.identifier) == [deviceA, deviceB])
    }
    // The damping is ordering-only: each row still shows its latest reading.
    #expect(list.nearby.map(\.rssi) == [-70, -30])
}

// MARK: - Change reporting and liveness

/// An advertisement that changes nothing visible reports no change (so the
/// shell does not re-render consumers for it) — but its liveness refresh
/// still counts: eleven seconds after first sight is only three after the
/// refresh, so the row survives the prune.
@Test func invisibleRefreshReportsNoChangeYetStillCountsAgainstAgeOut() {
    var list = makeList()
    _ = list.record(name: "PKT01_AB12", identifier: deviceA, rssi: -60, at: at(0))
    let visiblyChanged = list.record(name: "PKT01_AB12", identifier: deviceA, rssi: -60, at: at(8))
    let pruned = list.prune(at: at(11))
    #expect(!visiblyChanged)
    #expect(!pruned)
    #expect(list.nearby.count == 1)
}

/// CoreBluetooth reports RSSI 127 when no reading is available. The
/// sentinel must never blank a working indicator; a device first seen with
/// it still appears (identity matters more than signal), strength honestly
/// unknown until a real reading heals it.
@Test func unavailableRSSISentinelNeverBlanksARealReading() {
    var list = makeList()
    _ = list.record(name: "PKT01_AB12", identifier: deviceA, rssi: -60, at: at(0))
    let sentinelChange = list.record(name: "PKT01_AB12", identifier: deviceA, rssi: 127, at: at(1))
    #expect(!sentinelChange)
    #expect(list.nearby.first?.rssi == -60)
    let appearedUnread = list.record(name: "PKT01_CD34", identifier: deviceB, rssi: 127, at: at(1))
    #expect(appearedUnread)
    #expect(list.nearby.last?.rssi == nil)
    let healed = list.record(name: "PKT01_CD34", identifier: deviceB, rssi: -72, at: at(2))
    #expect(healed)
    #expect(list.nearby.last?.rssi == -72)
}

/// A renamed device (still ours) updates its row in place — identity is the
/// identifier, and the row does not move.
@Test func renamedDeviceUpdatesItsRowInPlace() {
    var list = makeList()
    _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(0))
    _ = list.record(name: "PKT01_BBBB", identifier: deviceB, rssi: -60, at: at(0))
    let renamed = list.record(name: "PKT01_AAA2", identifier: deviceA, rssi: -50, at: at(1))
    #expect(renamed)
    #expect(list.nearby.map(\.name) == ["PKT01_AAA2", "PKT01_BBBB"])
}

// MARK: - Age-out

/// A device that stops advertising ages out after 10 silent seconds —
/// strictly: the sighting exactly AT the limit survives (and that no-op
/// prune reports no change).
@Test func silentDevicesAgeOutAndTheBoundarySightingSurvives() {
    var list = makeList()
    _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(0))
    _ = list.record(name: "PKT01_BBBB", identifier: deviceB, rssi: -60, at: at(5))
    let boundaryPrune = list.prune(at: at(10))
    #expect(!boundaryPrune)
    #expect(list.nearby.count == 2)
    let latePrune = list.prune(at: at(10.5))
    #expect(latePrune)
    #expect(list.nearby.map(\.identifier) == [deviceB])
}

/// The age-out window is injectable (`PocketScanner.init(namePrefix:ageOut:)`
/// forwards it here) so it can be tuned the moment hardware reveals the real
/// advertisement cadence — and the strictly-greater boundary rule holds for
/// whatever window is chosen, not just the default.
@Test func ageOutWindowIsInjectableAndKeepsItsBoundaryRule() {
    var list = BLEScanList(namePrefix: PocketGATT.namePrefix, ageOut: .seconds(2))
    _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(0))
    let boundaryPrune = list.prune(at: at(2))
    #expect(!boundaryPrune)
    #expect(list.nearby.count == 1)
    let latePrune = list.prune(at: at(2.5))
    #expect(latePrune)
    #expect(list.nearby.isEmpty)
}

/// A device that returns after aging out is a NEW appearance and appends
/// like one — resurrecting its old position would make the list jump.
@Test func reappearingAfterAgeOutRejoinsAtTheEnd() {
    var list = makeList()
    _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(0))
    _ = list.record(name: "PKT01_BBBB", identifier: deviceB, rssi: -60, at: at(9))
    let pruned = list.prune(at: at(11))
    #expect(pruned)
    #expect(list.nearby.map(\.identifier) == [deviceB])
    let reappeared = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -55, at: at(12))
    #expect(reappeared)
    #expect(list.nearby.map(\.identifier) == [deviceB, deviceA])
}

/// `removeAll` is the fresh-session reset the shell performs whenever
/// scanning (re)starts: nothing stale survives it, and devices re-enter
/// normally afterwards.
@Test func removeAllStartsAFreshSession() {
    var list = makeList()
    _ = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(0))
    list.removeAll()
    #expect(list.nearby.isEmpty)
    let reentered = list.record(name: "PKT01_AAAA", identifier: deviceA, rssi: -50, at: at(20))
    #expect(reentered)
}

// MARK: - Radio-state mapping

/// Each way the radio can be unavailable maps to its own inspectable state:
/// "turn on Bluetooth", "allow Bluetooth access" and "no BLE hardware" need
/// different words in the UI, and only this distinction lets it say them.
@Test func eachRadioUnavailabilityStaysADistinctInspectableState() {
    #expect(PocketScanner.unavailableState(for: .poweredOff) == .poweredOff)
    #expect(PocketScanner.unavailableState(for: .unauthorized) == .unauthorized)
    #expect(PocketScanner.unavailableState(for: .unsupported) == .unsupported)
    #expect(PocketScanner.unavailableState(for: .unknown) == .starting)
    #expect(PocketScanner.unavailableState(for: .resetting) == .starting)
    #expect(PocketScanner.unavailableState(for: .poweredOn) == nil)
}
