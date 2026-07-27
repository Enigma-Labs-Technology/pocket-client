# Changelog

All notable changes to this package are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**The version is `0.x` on purpose.** Under semver, `1.0.0` is a promise of API
stability. Every verified claim in this package rests on one device running one
firmware version, and a firmware update can invalidate any of them — so the API
may still have to change to match what the hardware turns out to do. Read the
notes for a release before upgrading.

## [Unreleased]

### Fixed

- **iOS state restoration: a cancelled leftover no longer tears down the
  restored link.** When a relaunch handed back more than one live link, the
  transport adopted the first and cancelled the rest — but emptied its record of
  those cancelled peripherals *as it issued the cancels*, before CoreBluetooth
  could report them disconnected. Each of those callbacks then looked like a
  real teardown rather than the bookkeeping it was, and closed the transport,
  killing the link that had just been adopted. `connect()` failed
  `PocketError.disconnected` on exactly the background relaunch the feature
  exists for. The cancelled peripherals now stay recorded until their callbacks
  arrive, since removing each on arrival is the only thing that distinguishes
  bookkeeping from a teardown. (`compile-only` — reproduced and fixed against a
  fake radio; still not exercised on a phone.)

  The branch was unreachable by any test until `BLETransport` gained its
  internal CoreBluetooth seam in 0.1.0; the first test written against it found
  this. 0.1.0 shipped that test known-failing rather than silently weakened, so
  the suite in 0.1.0 ends on a `━` line. It is now an ordinary passing
  regression test and the suite is green.

## [0.1.0] — 2026-07-26

Initial release. A Swift package that speaks a Pocket voice recorder's own BLE
protocol — no vendor app, no cloud.

Claims below carry the grading used throughout this project
(`hardware`, `probed`, `compile-only`, `inferred`); see
[How claims are graded](README.md#how-claims-in-this-document-are-graded).
The sample size for every `hardware` claim is one physical device on one
firmware version.

### Added

- **Discovery.** `PocketScanner` picker feed with dedupe, RSSI refresh,
  ordering, and age-out; `BLETransport.connect()` for the first matching
  advertiser and `connect(to:)` for one specific device; link diagnostics.
  (`hardware`)
- **Authentication.** Session-key handshake, single-use transport/device
  lifecycle, one-request-at-a-time serialisation with a fast `PocketError.busy`.
  (`hardware`)
- **Device state.** Battery, firmware, Wi-Fi firmware, MAC, storage, clock set,
  slider position, recording state. (`hardware`)
- **Inventory.** Date listing and per-date recording listing, with opaque
  handling of non-date recording IDs. (`hardware`)
- **Download.** BLE transfer into memory or streamed to disk, and the Wi-Fi
  Quick Transfer path with its access-point handoff. Both verified
  byte-identical to a reference capture of the same recording. Completion is
  byte-count driven; there is no resume, because the protocol has no byte
  offset. (`hardware`)
- **Record control.** Start and stop. (`hardware`)
- **Live audio.** `liveAudio()` streaming. (`hardware`)
- **Events.** A single-consumer event stream; unrecognised frames surface
  verbatim as `.unmatchedResponse` rather than being dropped.
- **Key management.** `PocketKey` generation and validation, and an opt-in
  `SessionKeyStore` backed by the Keychain.
- **`pocket-cli`.** A macOS hardware harness: `scan`, `probe`, `connect`,
  `list`, `download`, `record`, `listen`, `raw`, `probe-unverified`, `adopt`,
  and the guarded `reset`. Rebinding (`adopt`) and the guarded wipe (`reset`)
  were each run end to end. (`hardware`)
- **Protocol reference** at `docs/protocol/ble-protocol.md`, with every claim
  graded by how it was established.
- **Hermetic test suite.** No hardware, no network; captured transcripts
  replayed against a fake transport.

### Safety properties

These are enforced in code, and they are the reason it is safe to run this
against a device with no recovery path. A fork that keeps the code and drops
these has kept nothing.

- Explicit-UUID GATT discovery on every path, including iOS state restoration.
  The three services believed to be factory-test and combo-chip OTA surfaces are
  never discovered, let alone written. (Their purpose is `inferred`; the
  inference justifies avoidance, not experimentation.)
- No `Command` case exists for `APP&OTA&`, `APP&WOTA`, `APP&OTA&WIFI&`, or
  `APP&WIFI&CH&`, so no code path in the library can emit one.
  `Command.wifiCredentials` is argument-less by construction.
- `APP&BLE&RESET` is not representable as a `Command`. Its bytes exist at one
  call site in `pocket-cli`, behind an explicit flag and a typed confirmation
  naming the device.
- `RawProbe` maps operator input through a fixed table of read-only probes; no
  user string is ever concatenated into a frame.
- A compiler-forced exhaustive walk over `Command` asserts that no generated
  wire frame contains an OTA, rebind, or provisioning substring.

### Known limitations

- `APP&PAU` and `APP&RESU` answer `MCU&UNKNOWN` on firmware 1.7, so there is no
  pause/resume API. (`probed` — a negative result is still a result.)
- CoreBluetooth state restoration and the iOS programmatic hotspot join
  (`SystemHotspotJoiner`) are `compile-only`. Neither has executed on a phone.
- Stopping a recording on the device sends nothing, so noticing a stop requires
  polling. `MCU&RT` fires once at connect and never repeats.
- A Wi-Fi transfer's TCP stream carries a short trailer past the announced byte
  count. Its meaning is `inferred` from a single sample; the announced count is
  authoritative and the surplus is ignored.
- No dependencies. iOS 17+, macOS 14+, Swift 6 toolchain.

[Unreleased]: https://github.com/Enigma-Labs-Technology/pocket-client/compare/0.1.0...HEAD
[0.1.0]: https://github.com/Enigma-Labs-Technology/pocket-client/releases/tag/0.1.0
