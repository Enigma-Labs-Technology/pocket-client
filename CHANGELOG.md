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

### Changed

- **Source-breaking for exhaustive switches: `WiFiSessionUse` gained
  `.restartedAfterReuseBroke(interruption:bytesDiscarded:)`.** It records a reuse
  the device **served** and that then failed mid-transfer — a distinct finding
  from `.restartedSession`, which is a refusal *before* any payload byte. A
  `switch` over `WiFiSessionUse` with no `default:` will no longer compile.

- **`WiFiBatchStop` gained `sessionUse`,** so the recording a run stopped on
  carries how it got its access point. Additive: the initialiser parameter is
  defaulted to `nil`. `WiFiBatchResult` gained `sessionUses`, `didAttemptReuse`,
  `reuseInterruptions`, `reuseVerdict` and `reuseVerdictText(elapsed:)`, and its
  `refusals` and `didReuseSession` now read the stop as well as the delivered
  recordings — see the verdict fix below for why that is a correction and not a
  convenience.

- **Source-breaking for exhaustive switches: `DeviceEvent` gained
  `.wifiConnectPath(String)`.** `DeviceEvent` is public, so a `switch` over it
  with no `default:` will no longer compile. Adding a `default:` (or a case for
  it) is the whole fix; nothing else about the enum changed. The event carries the
  Wi-Fi connect's interface decision and, on a failure, every `NWConnection` state
  it passed through.

- **`WiFiReadiness` gained `hostAddressWait`** (default 3 s), the Wi-Fi
  pre-flight's patience for an address that has not arrived yet. Additive: the new
  initialiser parameter is defaulted, so existing call sites are unaffected.

### Fixed

- **`pocket-cli` reported a date it could not parse as a fact about the
  recorder.** On 2026-07-28, `pocket-cli sync-wifi 20260728 2` printed

  ```
  no recordings on 20260728 — nothing to sync (try `pocket-cli list`)
  ```

  against a device that had **eight** recordings that day. The argument went
  straight onto the wire as `APP&LIST&20260728`; the recorder answers a directory
  it does not recognise with an empty listing rather than an error, and the CLI
  reported that empty listing as the device's inventory. It cost a hardware round,
  and it is the dangerous failure mode: a plausible, confident, wrong answer that
  sends somebody looking for a missing recording instead of at their command line.

  Three changes, and the compact form is deliberately **not** one of the things
  refused:

  - **Malformed dates never reach the radio.** `download` and `sync-wifi` both
    validate before Bluetooth is touched at all, and the refusal echoes what was
    given and names the forms that work. `2026-1-4`, `2026/01/04` and
    `2026-02-30` are all refused; a whole 14-digit recording ID is refused by
    naming the date it visibly contains ("its date is 2026-01-04, the first 8
    digits"), because taking a `list` output for a date is the likeliest way to
    get here.
  - **`20260104` is normalised to `2026-01-04`, not rejected.** It is exactly the
    first eight characters of the recording IDs `pocket-cli list` prints, so
    slicing a date off one is what a reasonable person does — and it is the
    argument that produced the defect.
  - **"No recordings on this date" and "the device has never heard of this date"
    are now different sentences.** A well-formed date the device serves nothing
    for costs one extra `APP&LIST_DIRS` (~89 ms on hardware, on a path that is
    about to open an access point anyway) and is answered with the dates that do
    have recordings, instead of with advice to go run another command. A device
    that lists the date but serves no files for it, and a device with no dates at
    all, each say so in their own terms.

  The same silent-empty trap one level down is closed with it: `download` with a
  timestamp that matches nothing now names the timestamps that day *does* have
  and can no longer print a bare `device has: none` for a date the device simply
  does not know. A timestamp is not validated by grammar and cannot be — hardware
  has produced IDs like `PH260105143000` — so the day's own listing is the
  authority, and it is printed.

- **`RecordingDate` and `PocketSession`/`PocketDevice.lookUpRecordings(forDate:)`
  are the API-side rule** (additive), returning `RecordingLookup.found` /
  `.refused` / `.empty`. `listRecordings(on:)` is unchanged and stays
  unvalidated on purpose: it also takes directories that came *from* the device,
  and those are not always dates — a library that refused non-date directories
  would make exactly those recordings unfetchable. Validation belongs where a
  *person* typed the string, and that is where it is applied.

- **A batch could deliver fewer recordings than transferring the same list one at
  a time would — the defect the first successful macOS Wi-Fi transfer exposed.**
  On 2026-07-30, `sync-wifi <date> 2` delivered recording 1 whole and then, on
  the still-live access point with no second join prompt, the device accepted a
  second TCP connection, reported `MCU&WIFIS&1`, announced the next file's length
  as `MCU&U&25242` — and the stream reset (`ECONNRESET`). The run stopped with one
  of two recordings delivered, while its own operator-facing text promised the
  worst case was "exactly what `pocket-cli download … wifi` does today, once per
  file".

  The fallback existed and did not fire. `transferOneRecording` classified a reuse
  failure as recoverable only when it happened *before* the payload phase — the
  gap poll, the TCP connect, the selection, the reroute — on the reasoning that a
  restart is safe only if no byte has flowed. The reset happened *inside* the
  payload phase, so it returned `.failed` and stopped the batch. **The reasoning
  was inverted**: a recording that broke on a session another recording opened has
  not yet had the one thing the one-at-a-time path would have given it, which is a
  session opened for it. Now every way a reuse can fail falls back the same way —
  any partial bytes are discarded, `APP&SHUT` + `APP&WIFIC` tears the session
  down, and the recording is fetched again from byte zero on a fresh session, once.
  A refusal and an interruption remain *reported* differently, because they answer
  different questions about the device; they are *recovered* identically, because
  the recording does not care which it was.

  The invariant now has a test that fails if it stops being true, across every
  shape a served-then-broken reuse can take: a reset before any byte, a reset after
  a partial write, and a complete payload that fails the integrity check.

- **A partial write from a broken reuse could have been left where a later run
  would find it.** It never reached the destination — the streaming sink writes to
  a `.<name>.partial-<uuid>` companion and publishes only after both integrity
  checks — but the recovery above makes the case reachable rather than terminal,
  so the discard is now explicit at that exit and asserted by a test that lists the
  directory afterwards.

- **The `sync-wifi` verdict contradicted its own transcript.** The 2026-07-30 run
  printed `INCONCLUSIVE — no recording was ever asked to reuse a session`
  immediately below a log of a second selection being served on one. Reuse was
  credited only from *delivered* recordings, and the recording carrying the attempt
  was the one the run stopped on — so the most informative outcome an experiment
  about failure can produce was the one outcome it could not report. The stop now
  carries its session use, every reuse question reads it, and the verdict has four
  terms instead of three, because serving a second selection and completing a
  transfer over one turned out to be separate facts. It now says, for that exact
  run: *the device served a second selection on a live session, and the transfer
  then failed*. The verdict moved into the library beside
  `AccessPointLifetime.verdictText` so it can be tested; an executable target
  cannot be.

- **The Wi-Fi pre-flight read a stale address as proof of an association, and said
  so in three confident sentences that were all wrong.** A connect failure from a
  host holding an address on the device's `/24` reported that "the association and
  the credentials are settled and out of the picture, and so is the access point's
  lifetime, because a device that had closed its AP would not still be leasing this
  address". macOS keeps the address, the netmask, the route and the ARP entry when
  a Wi-Fi interface disassociates, so **every run that has ever joined the recorder
  leaves behind a configuration that satisfies that check** — and it is most
  misleading exactly when somebody is testing repeatedly. The address is also not a
  lease the device is granting, so it says nothing whatever about the access
  point's lifetime. Hardware, 2026-07-30: `networksetup -getairportnetwork en0`
  reported *not associated* while `ifconfig en0` still showed `192.168.200.2`.

  The reasoning is deleted rather than reworded. What replaces it is evidence that
  can contradict an address: `IFF_RUNNING` from the same `getifaddrs` enumeration
  (the kernel's operational link state, as distinct from the administrative
  `IFF_UP`), and `ENETDOWN` from `Network.framework` on a connection *required* to
  use that interface — which cannot mean "the destination is unreachable from here"
  when the interface holds an address on the destination's own `/24`. `ENETDOWN`
  was accurate throughout the failing run while this package's prose was not, so
  where the framework gives a reason it is now preferred to any inference here.
  Both checks are **one-directional by construction**: they can establish that this
  host is not associated, and nothing available to this package can establish that
  it is. Neither is a shell tool and neither reads an SSID —
  `networksetup -getairportnetwork` is a command-line program with no API behind
  it, and SSID reads on current macOS are gated behind Location Services, so a
  check built on one would report "not associated" for a permissions reason.

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
  (`NWParameters.requiredInterface`), and sets nothing else.
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

  The refusal is not made on a timing guess. The pre-flight waits
  `WiFiReadiness.hostAddressWait` for an address that has not arrived, and extends
  that to the full `timeout` for as long as some interface holds a self-assigned
  `169.254` address — which means this host associated with an access point and is
  still being refused a lease, a join trying rather than a host elsewhere. The
  ceiling is `timeout` either way, so it can never wait longer than the connect it
  replaced.

- **A host that joined and never got a lease is no longer told to forget the
  network.** A self-assigned `169.254` address proves the association succeeded,
  so the password was accepted and DHCP is what failed. That case now has its own
  verdict naming the right repair — renew the lease — and says explicitly not to
  forget the network, because re-entering a credential that was accepted costs
  time and teaches nothing.

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
  `STOPPED on 20260105093000: wifi tcp connect timed out after 30.0 seconds` — the
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

- **The tests holding the Wi-Fi interface pin and the pre-flight no longer fail on
  CI.** Three of them broke the suite's own hermeticity rule and went red on every
  GitHub run while passing on a developer's Mac, which meant the mutation guarantee
  those two fixes rest on did not hold in the environment that gates merges. Two
  causes. They asked the machine for a real `NWInterface` — a type with no public
  initializer, so the only source is a live `NWPath`, and a virtualised runner's
  `NWPathMonitor` lists none at all, so `try #require(listed.first)` failed there by
  construction. And they measured budgets on the wall clock: a 250 ms bound around
  calls that really slept measured 353 ms on a loaded runner.

  Both now have seams. `WiFiInterfacePinning` resolves and applies the pin by
  interface *name* — which is what `HostInterfaceAddress.interfaceName` already is —
  so the pin's whole decision is tested against a written-down list, including that
  the parameters it constrains are the object the socket is opened with. The Wi-Fi
  pre-flight and the bounded `NWPathMonitor` poll take a `Clock`, so their budgets
  are checked exactly, in virtual time, without sleeping. The two checks that
  genuinely need a real `NWInterface` — that this SDK enforces `requiredInterface`
  on a socket — remain, and now *skip* with an explicit message on a host that lists
  none, the way the Keychain round-trips already skip on an unsigned test runner.
  Behaviour is unchanged: production passes a `ContinuousClock` and
  Network.framework's own interface list, exactly as before.

### Added

- **`ManualHotspotJoiner` warns about Ethernet before the join prompt.** With a
  wired link carrying this Mac's default route, macOS associates with the
  recorder's no-internet access point and then silently drops the association,
  leaving address, netmask, route and ARP entry in place so the host looks joined
  from every angle this process can see. It cost several hardware rounds to find,
  and unplugging the cable produced the first successful macOS Wi-Fi transfer. The
  joiner now asks `NWPathMonitor` whether the default path is wired and, if it is,
  leads the instructions with `0. UNPLUG ETHERNET FIRST` — above the Wi-Fi steps,
  which is the only point in the run where it can still be acted on. The
  instructions are built as a value rather than written straight to stdout so the
  warning can be tested.

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
