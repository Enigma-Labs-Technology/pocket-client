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

- **A failed Wi-Fi TCP connect threw away the one value that could explain it.**
  `NWConnection`'s `.waiting(NWError)` carries `Network.framework`'s own reason for
  not being able to use the path, and the connect's state handler discarded it
  (`default: break // .setup / .preparing / .waiting — keep waiting`). A failing run
  could therefore only ever report `wifi tcp connect timed out after 30.0 seconds`,
  which is precisely why the cause of the macOS failure was proposed three times
  and eliminated on hardware three times. Every non-terminal state is now recorded;
  the most recent `.waiting` reason goes into the thrown message — with its POSIX
  code, because `ENETDOWN (50)` is a path with no usable route while
  `EHOSTUNREACH (65)` is a route with nothing on the far end — and the whole
  transition sequence goes to the new `DeviceEvent.wifiConnectPath`, which
  `pocket-cli` prints. Independent of the fix below, and worth having whatever any
  future failure turns out to be.

- **The Wi-Fi TCP connect named no interface, so `Network.framework` was free to
  choose one that cannot reach the recorder.** `NWConnection(to:using: .tcp)` uses
  default parameters, and the framework runs its own path evaluation rather than
  simply following the BSD route table. The recorder's access point provides no
  internet, and a host running a mesh VPN carries a `utun` holding a default route
  — so the framework can select, or wait indefinitely for, a path that cannot reach
  `192.168.200.1`. A silent 30 s timeout with no error delivered to the caller is
  the signature of exactly that, as distinct from a refused connect (immediate) or
  an unreachable host (fast). It is also why iOS worked and macOS did not: on iOS
  the app joins with `NEHotspotConfiguration`, so the path belongs to the process,
  while on macOS the join is external and nothing identified the interface.

  The device's address is a fixed constant on a directly-connected `/24`, so this
  host's own address on that subnet identifies the right interface unambiguously.
  `getifaddrs` finds it and the connection then requires that interface
  (`NWParameters.requiredInterface`) and prohibits the classes it provably is not.
  `requiredInterface` rather than `requiredLocalEndpoint` because that is what
  measurement showed to be enforced on this SDK — the latter was ignored outright,
  including when the address it named belonged to no interface on the machine.

  **Not yet confirmed on hardware.** Both fixes are unit-verified, and the macOS
  transfer they exist to unblock has not been run since.

- **A Wi-Fi transfer from a host that is not on the access point now says so at
  once instead of timing out.** No interface holding an address on the device's
  subnet means this host cannot reach the device, whatever `MCU&WIFIS` reported —
  and that check is strictly better evidence than `MCU&WIFIS&2`, which the device
  returns for *any* associated client (hardware-confirmed: a Mac auto-joining a
  remembered network satisfies it while proving nothing about this process). The
  error names the SSID to join. `WiFiConnectDiagnosis`'s verdicts were revised to
  match: a run that reaches `2` and then fails to connect now points at the
  interface and the path, not at the access point's lifetime, which the 2026-07-29
  measurement eliminated.

- **Every Wi-Fi transfer from a Mac failed, silently, for as long as the path has
  existed — the keepalive did not cover the join.** `APP&WPING` started only after
  `joiner.join(ssid:passphrase:)` returned. On macOS that join *is* a person:
  `ManualHotspotJoiner` prints instructions and blocks on `readLine()` while the
  operator opens System Settings, forgets a network the Mac remembers, finds the
  SSID and types a password. On 2026-07-28 that pause was long enough for the
  device's access point to come up, serve DHCP, and go away again before a byte was
  asked for. The evidence, gathered on the Mac while still joined to the AP: a
  valid `192.168.200.2` lease and a correct `en0` route, and `No route to host`
  from both `ping 192.168.200.1` and `nc -vz 192.168.200.1 8475` — ARP unanswered,
  the device no longer there at layer 2. The only symptom that reached the process
  was `wifi tcp connect timed out after 30.0 seconds`.

  The keepalive now starts **before** the join and runs until the session closes,
  reusing the session-long pinger and the `WiFiReadiness.pingInterval` cadence
  rather than adding a third mechanism. It therefore covers every
  `HotspotJoining` — including `SystemHotspotJoiner`, which waits on the iOS
  *"wants to join"* alert: the same shape of pause, merely faster today, which is
  why the phone path never showed this. `ManualHotspotJoiner`'s `readLine()` now
  runs on a thread of its own, off Swift concurrency's cooperative pool, because a
  blocking read there can starve the very task that is supposed to be pinging. The
  association wait touches the session's idle clock around its polls, exactly as
  the TCP connect already did, so nothing double-pings. No new API, no wire-order
  change on any path that was already working.

- **A batched Wi-Fi run printed the raw failure instead of the diagnosis built for
  it.** `sync-wifi` reported only
  `STOPPED on 20260728003752: wifi tcp connect timed out after 30.0 seconds` — the
  join-failure guidance added in the previous release enriched the
  single-recording path only, so the transcript where the confusion actually
  happened never saw it. The batch path now attaches the same diagnosis to a
  terminal connect failure. A connect failure on a *reused* session is untouched:
  that is a refusal the run repairs by restarting, not a failure to explain.

- **A TCP connect that follows a successful association is no longer blamed on
  credentials.** The 2026-07-28 failure was an access point that had gone away,
  not a stale password, and pointing at the wrong cause costs more than a bare
  error. What a failed connect now says depends on what the device reported: a
  client on its AP (`MCU&WIFIS&2`) or its Wi-Fi off (`MCU&WIFIS&0`) both point at
  the access point's lifetime and say nothing about passwords; only the AP up with
  nothing ever on it (`MCU&WIFIS&3`) — the shape a stale credential makes — keeps
  the credential guidance. Message text only: no new error case, no control-flow or
  teardown change, and no credential in any of it.

### Added

- **A hardware probe for the assumption the last two releases rest on: does
  `APP&WPING` extend the access point, or only keep the BLE session alive?**
  `pocket-cli probe-ap-lifetime [--keepalive] [--cap <s>] [--poll <s>] [--ping <s>]`,
  and `PocketSession`/`PocketDevice.probeAccessPointLifetime(_:onStep:)` behind it.

  `APP&WPING` is documented as the "Wi-Fi-session keepalive", and this package read
  that as *extending the access point*: 0.1.3 pings during the TCP connect, and
  0.1.4 moved the pinger to start before the join precisely so a human-paced manual
  join would be covered by it. **Neither release measured it.** No capture
  separates the two readings either — the vendor app's join is programmatic and
  fast, so its access point never came close to expiring. What forces the question
  is a `sync-wifi` run on 2026-07-29 that reached `MCU&WIFIS&2` — the device itself
  confirming the Mac had associated — and whose TCP connect to
  `192.168.200.1:8475` still timed out after 30 s with the keepalive running
  throughout. Either the keepalive works and the fault is elsewhere (the device's
  listener, or this client's socket code), or it does not and no scheduling of it
  makes a manual join work at human speed.

  The probe brings the access point up (`APP&WIFIO`), polls `APP&WIFIS` on a fixed
  cadence, prints every state with an absolute elapsed time from the `MCU&WIFIO`
  ack, and stops when the device reports the access point off or at a cap — **with
  no join at all**. That is the design point: no association, no DHCP, no socket,
  so no host-side variable (a stale saved password, a slow person in System
  Settings, macOS auto-joining a remembered network) can be mistaken for the
  device's own behaviour, and the device's `APP&WIFIS` is the only witness. The
  keepalive is a flag, so the experiment is two runs — once silent for the
  unassisted baseline, once pinging — and the difference between the two lifetimes
  is the answer.

  **The verdict is typed, and honest about what one run cannot show.** Each of the
  four findings names the run that is still missing and what each possible
  comparison would mean, because a single run cannot distinguish the readings and a
  transcript that reads like an answer would be worse than no transcript. Two
  further honesty checks are built in: `APP&WPING` sent with no `MCU&WPING` back is
  called out, since a conclusion about a keepalive the device may never have
  received is worthless; and an association observed during a run that never joins
  marks the run confounded.

  The access point is closed on **every** exit, interruption included — a
  still-broadcasting AP competes with BLE for the same 2.4 GHz radio, which is why
  the transfer code already sends `APP&WIFIC` on all of its failure paths. The
  first Ctrl-C cancels the watch, closes the access point, and reports what was
  measured; only a second abandons the run, and says what that costs. The close
  frames go out from a task that does not inherit cancellation, so a cancelled run
  cannot skip them, and the probe confirms the close with one more `APP&WIFIS`
  rather than assuming it.

  Additive and read-only with respect to everything that already worked: no
  transfer behaviour changes, no new command, no new error case, and the probe
  claims the same exclusive transfer slot the downloads do so nothing can fight it
  for the radio. The AP password arrives with the SSID in the `APP&WIFI` reply and
  is discarded unread — nothing joins, so it is never needed and can never reach a
  transcript. Recorded as open item 3 in `docs/protocol/ble-protocol.md`, and as
  the second `unverified` entry in the README's ledger.

- **One Wi-Fi access-point session for a whole sync, instead of one per
  recording — the reuse itself `unverified`.** `PocketSession` and `PocketDevice`
  gained `downloadOverWiFi(_ recordings:into:…)`, which brings the access point up
  once, transfers N recordings, and closes it once. The existing
  single-recording API is unchanged; this is purely additive.

  The problem it addresses was watched on hardware on 2026-07-29: because a
  session lasts exactly one transfer and `NEHotspotConfiguration.joinOnce` makes
  iOS discard the configuration on disassociation, a ten-recording sync (~354 MB
  in 30–50 MB files) asked the operator to join the network **ten times** and paid
  the `SHUT → WIFIS → WIFI → WIFIO` handshake plus the ~6.5 s association wait ten
  times.

  **The device's part of this is genuinely unknown and the API says so.** Nobody
  has ever issued a second `APP&U&<date>&<ts>` while the access point was still
  up — the packet capture the protocol was decoded from covered a single-file sync
  — so the run *attempts* reuse and falls back cleanly. A refusal is always
  detected **before** a payload byte of the affected recording has flowed (the
  `APP&WIFIS` gap poll reporting `0` or `3`, a TCP connect the device will not
  accept, a selection it will not answer, a reroute it will not ack); the session
  is then torn down properly — `APP&SHUT` + `APP&WIFIC`, then leave the network —
  and a fresh one is opened for that recording, after which reuse is not attempted
  again in that run. **The worst case is therefore exactly the previous
  one-session-per-recording behaviour**, never a wedged device or a half-open
  access point. `WiFiBatchResult.didReuseSession` and `.refusals` report which
  happened. Both branches are unit-tested against a fake device; neither has run
  against hardware, which is what the new `unverified` grade in the README's
  claim table means.

  **A restart waits for the access point to actually be off.** A restart is the
  only place in this protocol that closes an AP and immediately reopens one, so
  before every reopen (never before the first session) the client polls
  `APP&WIFIS` until it reports `MCU&WIFIS&0` — evidence rather than a guessed
  sleep, using the state oracle this sequence already relies on, and one extra
  round-trip against a device that reports transitions in ~100 ms. The wait is
  bounded, and **on expiry the run stops and names the last state seen instead of
  sending `APP&WIFIO`** onto an access point that may still be coming down. The
  fallback is what has to be trustworthy for the hardware experiment to mean
  anything: a restart that half-works would be misread as the device refusing
  session reuse.

  Partial progress is kept and is not an error: the run stops at the first
  recording it cannot deliver — a failure on recording 4 of 10 must not lose 1–3 —
  and returns `WiFiBatchResult.stopped` naming the recording, the reason, the
  `PocketError` when it was one, and the recordings it never attempted. It throws
  only for `PocketError.busy` and caller cancellation. Every exit path closes the
  access point, cancellation included, because one left broadcasting competes with
  BLE for the same 2.4 GHz radio. Wi-Fi only by design: no `.auto`, no BLE
  fallback — a batch exists to avoid an AP handshake BLE does not have, and
  pushing 350 MB down a ~35 KB/s link is not a choice to make for the caller.

  **`APP&WPING` now spans the whole session** rather than just the TCP connect,
  gated on the idle clock the TCP reader already touches, so a ping goes out only
  after real silence and never on top of a transfer that is streaming bytes. It is
  fire-and-forget rather than a request: the session allows one armed waiter, and a
  keepalive holding it could fail the next `APP&U&<date>&<ts>` with `.busy`, which
  a batch would misread as the device refusing a second selection. Its `MCU&WPING`
  echo is absorbed the same way the 30 s `APP&BAT` keepalive's echo already was.

  **`pocket-cli sync-wifi <date> [count]`** is the hardware experiment: it
  transfers several recordings in one run and prints, per recording, whether the
  session was `REUSED` or had to be `RESTARTED` (with the refusal verbatim), then a
  verdict. Since the macOS join is manual, the run is its own control — one prompt
  if reuse works, one per recording if it does not. The open question and every
  refusal shape are recorded in
  [the protocol reference](docs/protocol/ble-protocol.md).

  One behaviour change on an existing path, from moving the session close out of
  the transfer: a single-recording Wi-Fi transfer that fails its **integrity
  check** (size mismatch, non-MP3) now sends `APP&SHUT` + one `APP&WIFIC` instead
  of two `APP&WIFIC` followed by `APP&SHUT` + a third. The frame order of a
  successful transfer, and of every other failure path, is unchanged.

- **A rebind propagates to the Wi-Fi AP password — VERIFIED on hardware
  (2026-07-28).** The protocol reference said the AP password is the session
  key's first 8 characters but never said *when* it is derived, and nobody had
  previously rebound a device and then used Wi-Fi on it. It follows the live
  binding: after `APP&BLE&RESET` plus an `adopt`, the device reported the **new**
  key's first 8 characters, surviving the reset and the reboot. The consequence
  is the operationally important part, and it is now documented in
  [the protocol reference](docs/protocol/ble-protocol.md) and the README: the
  SSID *is* the BLE name and does not change with the password, so **every host
  that has ever joined that AP now holds a stale credential**, and no app can
  clear it — `removeConfiguration(forSSID:)` only removes configurations the app
  itself created, and neither iOS nor macOS exposes any API that removes a
  user-saved network. It has to be forgotten by hand. (`hardware`, one device.)

- **A failed Wi-Fi join now names its most likely cause.** Both platforms report
  a join failure as one opaque line — iOS as *"Unable to join the network …"*,
  macOS as no join error at all, just a TCP connect that times out — and neither
  distinguishes a stale saved password from an access point that is down. That
  ambiguity cost three hardware probes to resolve. The package holds one fact the
  OS does not: the session key, from which the AP password is derived. It now
  compares that against the password the device reports over BLE and says whether
  the *device* is self-consistent. When it is, the error states that the
  credentials handed to the OS were right and the fault is this host's saved
  network, and names the manual repair. A disagreement is reported as a firmware
  finding, explicitly **not** as the failure's cause — the join uses the device's
  value, which is authoritative. Neither password appears in the message, so a
  failure stays safe to paste into a bug report.

  Carried on both shapes of the failure: the join error, and a TCP connect that
  fails while the device reported **no** client on its AP (`APP&WIFIS` at `3` and
  never `2`) — the macOS shape, where the join itself cannot fail. When the
  device *did* report an associated client the message is left alone: the host is
  demonstrably on the AP. `ManualHotspotJoiner` also warns the operator before
  they join, since on 2026-07-28 it printed the correct password and the operator
  still joined with the one the Mac remembered.

  No behaviour change to the transfer sequence, and no new error case:
  `PocketError.wifiJoinFailed` / `.transferFailed` carry richer detail strings.
  Callers that match on those strings will see the new text.

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
