# Pocket BLE Protocol — v2 (verified by probing)

**How these findings were established.** Three sources, in roughly descending
order of how much of this document rests on each:

1. **Android HCI snoop logs** of the vendor's own app driving a real device: a
   baseline connect/status sweep, one complete Wi-Fi Quick Transfer, a
   record-start session, and a delete. Every frame quoted below was read out
   of one of these.
2. **Live probing** from macOS over a small Python/bleak harness. This is what
   settles anything the vendor app never does — `APP&PAU`/`APP&RESU`, USB
   mass-storage mode, rebinding to a new key, and the read-only probes.
3. **Ground truth for the file format**: a recording exported by the vendor's
   own app, compared byte for byte with the same recording pulled over this
   protocol, plus `ffprobe` for the container details.

> **The capture files and the probe harness are not part of this repository,
> and never will be.** The captures are recordings of a real person's voice,
> and because the protocol is plain ASCII, a capture of any session contains
> the session key in cleartext — publishing them would hand over the device
> along with the documentation. Citations below therefore describe *how* a
> claim was established rather than pointing at a file you can open. Nothing
> is missing that you are expected to have: a claim marked VERIFIED was
> verified against the evidence above, and stays verified whether or not the
> evidence ships. Where a single sample is all there was, the text says so.

Device: PKT01_EXAMPLE · MAC 00:00:5E:00:53:00 · FW 1.7 · Wi-Fi FW V9

> **Redacted for publication.** Every device-specific value in this document —
> BLE name, MAC, session key, Firebase UID, and recording timestamps — has
> been replaced by an obviously fake placeholder of the same shape and length
> (`ExampleKey000000`, `PKT01_EXAMPLE`, `00:00:5E:00:53:00`, an IANA
> documentation MAC; recording IDs are round synthetic times in January). The
> findings were made on one real device; the placeholders preserve the format
> so the parsing rules still read correctly, but none of them is a live
> credential or a real identifier.

## Link layer

- No BLE bonding required (nRF Connect shows NOT BONDED; zero SMP in captures)
- Device accepts one central at a time; stops advertising while connected
- Advertises as `PKT01_<COLOR>_<macsuffix>`

## GATT map (complete)

| Service | Characteristic | Props | Role |
|---|---|---|---|
| `180f` | `2a19` | read, notify | Standard battery level |
| `ffd0` | `ffd1` | write | TBD |
| | `ffd2` | notify | TBD |
| | `ffd3` | write, notify | TBD |
| `e49a3001-f69a-11e8-8eb2-f2801f1b9fd1` | `e49a3002-...` | write | TBD |
| | `e49a3003-...` | notify | TBD |
| `e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1` | `e49a25e0-...` | write | TBD (Wi-Fi config?) |
| | `e49a28e1-...` | notify | TBD |
| `001120a0-2233-4455-6677-889912345678` | `001120a2-...` | write | **Command channel (in)** |
| | `001120a1-...` | notify | **Bulk data channel (audio/file bytes)** |
| | `001120a3-...` | notify, write-no-resp | **Response channel** |

## Authentication

- Session key handshake is **mandatory**: commands are silently ignored before SK
- `APP&SK&<16 chars>` → `MCU&SK&OK` | wrong key → `MCU&SK&ERR` **then device drops the connection**
- The observed key (shown throughout as the placeholder `ExampleKey000000`) is
  **static** — reused successfully ≥20 min later and from a *different central*
  (Mac after Pixel). Treat as a device credential.
- **Provenance (verified): SK = first 16 chars of the user's Firebase Auth UID.**
  Evidence: app storage showed a 28-character UID (placeholder:
  `ExampleKey000000ExampleUID000`) whose 16-char prefix was exactly the SK.
  The app derives it locally — no cloud call at connect time. Device is provisioned with it
  during pairing. Wi-Fi AP password = first 8 chars of UID (= SK[:8]).
- Security note: UID is the root secret for BLE auth + Wi-Fi AP + all recordings on device.
  It appears in the app's local telemetry (Sentry breadcrumbs) — treat as sensitive.

### Rebinding to a key of your own (VERIFIED on hardware 2026-07-26)

The vendor's UID is only *a* key, not a required one. The firmware validates `APP&SK&` on
**length alone** (16 chars) — there is no separate provision/bind verb, and the binary contains
only `MCU&SK&OK` / `MCU&SK&ERR`, so an adoption is indistinguishable on the wire from an ordinary
successful auth.

**Trust-on-first-use after a reset is CONFIRMED**, not inferred as earlier revisions of this
document said. Sequence run end to end on `PKT01_EXAMPLE`:

1. authenticate with the current key
2. `APP&BLE&RESET` — clears the binding **and permanently erases every recording on the device**
   (the vendor's own reset sheet says so). Device acknowledges and reboots.
3. reconnect and send `APP&SK&<any 16 chars from [A-Za-z0-9]>` → `MCU&SK&OK`, and it **persists
   across reconnects**.

No physical button press was needed: the software reset alone leaves the device open to the next
key. (The physical gesture — triple-click the side button until the LED blinks red, then
immediately press and hold until the red blinking stops, releasing when it returns to breathing
blue — remains the recovery path if the software reset ever fails. Note that earlier revisions
described this gesture WRONGLY, inferred from the vendor app's tutorial artwork; the sequence
here came from the hardware.)

Charset: only `[A-Za-z0-9]` is proven good (Firebase UID prefixes are alphanumeric). `&` is the
protocol delimiter and must never appear. Behaviour outside alphanumerics is UNKNOWN — do not
explore it on a device you care about.

Verification that a new key took: `APP&WIFI` returns the AP password, which is `key[:8]` — the
only read-back of any part of the key. The old key should then answer `MCU&SK&ERR`.

That read-back is not merely a check: the AP password really does rotate with the binding, which
invalidates the saved Wi-Fi credential on every host that has joined the device's AP before. See
[A rebind propagates to the AP password](#a-rebind-propagates-to-the-ap-password-verified-on-hardware-2026-07-29)
— that consequence, not the rebind itself, is what breaks Wi-Fi transfers after a rotation.

Reversibility: the vendor app carries an "unregistered-device recovery" path using a
Remote-Config **fallback master key**, so rebinding is not cryptographically one-way. Re-adoption
needs the *original* account's app running near the device with that flag enabled, so a stranger's
phone cannot take it — but removing that app and deleting the device from the account is what
makes a rebind durable.

`APP&BLE&RESET` is otherwise still forbidden in this codebase: it exists only in
`pocket-cli reset --wipe-all-recordings`, behind a typed confirmation, and is deliberately not
expressible as a `Command` so neither `pocket-core` nor the iOS app can reach it.

## Command channel (write `001120a2`, responses on `001120a3`)

ASCII, `&`-delimited, request/response.

| Command | Response | Meaning |
|---|---|---|
| `APP&SK&<key>` | `MCU&SK&OK` / `MCU&SK&ERR` (+disconnect) | Session auth |
| `APP&BAT` | `MCU&BAT&100` | Battery % |
| `APP&FW` | `MCU&FW&1.7` | Firmware version |
| `APP&MAC` | `MCU&MAC&00005e005300` | Device MAC |
| `APP&WF` | `MCU&WF&V9` (also seen `ec9` — state-dependent, TBD) | Wi-Fi firmware |
| `APP&GET&USB` | `MCU&USB&0|1` | USB mass-storage mode state |
| `APP&USB&1` / `APP&USB&0` | `MCU&USB&1` / `MCU&USB&0` | **USB mass-storage on/off** (verified; enabling drops BLE once — USB stack reinit; reconnectable; state persists) |
| `APP&SPACE` | `MCU&SPA&059632&059636` | **Storage: free MB & total MB** (verified: Device Files UI shows "59632.0 MB free / 59636.0 MB total") |
| `APP&T&YYYYMMDDHHMMSS` | `MCU&T&OK` | Set clock (UTC) |
| `APP&REC&SECEN` | `MCU&REC&CON` (slider DOWN) / `MCU&REC&CALL` (slider UP) | **Slider mode query** — response reports physical slider position |
| `APP&STA` | `MCU&REC&CON` + `MCU&STA&<ts>` | **Start recording remotely (verified)** |
| `APP&STO` | `MCU&STO` | **Stop recording remotely (verified)** |
| `APP&STE` | `MCU&STE&0` (idle) / `MCU&STE&1` (recording active) | Recording status query |
| `APP&LIST_DIRS` | `MCU&DIRS&<date>` ×N, then `MCU&DIRS_SUM&<count>` | List date directories |
| `APP&LIST&<date>` | `MCU&F&<date>&<ts>&<secs>` ×N, then `MCU&LIST&<count>` | List recordings (ts=`YYYYMMDDHHMMSS`, **field 3 = duration seconds**) |
| `APP&U&<date>&<ts>` | `MCU&U&<size_bytes>` → raw bytes on `001120a1` → `MCU&OFF` | Download recording |
| `APP&D&<date>&<ts>` | `MCU&D` | **Delete recording (verified: file gone from subsequent LIST)** |
| `APP&SHUT` | `MCU&SHUT` — **only when an upload was in flight; NO reply on an idle device** (live-probe verified: don't block on it) | Abort in-flight upload / reset Wi-Fi flow |
| `APP&WIFIS` | `MCU&WIFIS&<n>` (0 off / 3 AP up / 2 client associated / 1 TCP client connected) | Wi-Fi state query |
| `APP&WIFI` | `MCU&WIFI&<ssid>&<psk>` (synchronous reply — there is no unsolicited credentials push) | AP credentials query, read-only. **Not to be confused with the forbidden provisioning command `APP&WIFI&CH&…`** |
| `APP&WIFIO` | `MCU&WIFIO` | **Start the Wi-Fi AP** (`MCU&WIFIS&3` ~114 ms later) |
| `APP&WPING` | `MCU&WPING` | Wi-Fi-session keepalive. **Extends the access point's lifetime** — measured 2026-07-29: ~59 s unassisted, still up at 180 s with a ping every 10 s ([evidence](#appwping-does-extend-the-access-point-hardware-2026-07-29)). Also keeps the BLE session from idling out. (`APP&PING` appears in **no** capture — it is not a real command) |
| `APP&U&WIFI` | `MCU&U&WIFI`, then repeat `MCU&U&<size>` | **Modifier, not standalone**: reroutes the upload previously selected by `APP&U&<date>&<ts>` to TCP :8475 |
| `APP&WIFIC` | `MCU&WIFIC` | Close Wi-Fi session / AP off (official app sends it twice) |

Unsolicited events:
- `MCU&REC&CON` + `MCU&STA&<ts>` — recording started (device button OR remote `APP&STA`)
- `MCU&RT&<start_ts>&<elapsed_secs>` — sent at connect when a recording is already in
  progress (reconnect-resilient; verified after mid-recording connection drop).
  **ONE-SHOT, NOT A TICK.** It fires once at connect and never repeats, so nothing on the
  wire advances a recording's elapsed time. Any UI clock must run locally, anchored to the
  last device-reported value. (Field-confirmed 2026-07-26: an app that rendered the last
  reported number showed a frozen "RECORDING 00:00" for an entire session.)
- **There is NO unsolicited stop event.** Stopping on the device sends nothing; `MCU&STO`
  exists only as the reply to a remote `APP&STO`. A client cannot learn that a recording
  ended by listening — it must poll `APP&REC&STATE` (→ `MCU&REC&<0|1>`, surfaced as
  `DeviceStatus.isRecording`).

## Live audio streaming (VERIFIED — HCI snoop of a record-start session)

During any active recording, the device streams the audio **in real time** on `001120a1`:
- Same MP3 framing as stored files (`fff348c4` syncs confirmed in stream)
- Rate ≈ 32 kbps real-time (~890 notifications/30 s, ~135 B avg payload)
- Live listen = decode the notification stream as MP3; no separate protocol
- Stream survives BLE reconnects (recording keeps running device-side regardless)

## Recording control session anatomy (app-driven, verified)

1. Connect → standard handshake (SK, USB, BAT, FW, MAC, WF, SPACE, T&, REC&SECEN, STE)
2. `LIST&` sweep over ~8–10 day window
3. `APP&STA` → `MCU&REC&CON` + `MCU&STA&<ts>` → live MP3 begins on data channel
4. (optional) reconnect mid-recording → device reports `MCU&RT&<ts>&<elapsed>`
5. `APP&STO` → `MCU&STO` → live stream ends
6. `APP&U&<date>&<ts>` → `MCU&U&<size>` → file download → `MCU&OFF`

## File format (VERIFIED against official export + ffprobe)

- **Raw MP3 elementary stream: MPEG-2 Layer III, 32 kbps, 16 kHz, mono, no CRC**
- 144-byte MP3 frames, sync header `FF F3 48 C4`
- No container/header — first bytes are already the first MP3 frame
- Downloaded `.bin` files are byte-identical to the app's exported `audio.mp3`
- Decode with anything: `ffmpeg -i rec.bin out.wav`; whisper takes it directly

## Download protocol details

1. `APP&U&2026-01-04&20260104101500`
2. `MCU&U&15302` — announces exact byte count
3. Raw MP3 streams on `001120a1` in 244-byte BLE notifications (last chunk short)
4. `MCU&OFF` — end-of-transfer marker
5. Throughput: 15 KB in <1 s over BLE

## Live monitoring

The `001120a1` stream during an active recording carries the same MP3 framing
(observed FFF348C4 headers mid-capture). Live-listen = decode notification stream.

## Wi-Fi Quick Transfer (CAPTURE-VERIFIED — HCI snoop of one complete app-driven sync, TCP side from a simultaneous packet capture)

The exact flow the official app performs (a single complete sync, decoded frame
by frame from that snoop; an earlier revision of this section was reconstructed
from prose and got the credentials/AP-start/selection steps wrong):

1. App: `APP&SHUT` — aborts the in-flight BLE upload if any (reply `MCU&SHUT`;
   **no reply arrives on an idle device** — do not block waiting for one)
2. App: `APP&WIFIS` → `MCU&WIFIS&0` (Wi-Fi off)
3. App: `APP&WIFI` → `MCU&WIFI&<SSID>&<PSK>` — **credentials are the synchronous
   reply to this request; nothing is ever pushed unsolicited.** SSID = BLE name
   (`PKT01_EXAMPLE`), WPA2 password = first 8 chars of the session key
   (`ExampleK`). This bare query is distinct from the FORBIDDEN provisioning
   command `APP&WIFI&CH&<ssid>&<psk>` — never append arguments.
4. App: `APP&WIFIO` → `MCU&WIFIO` — **this is what starts the AP** (a `WIFIS`
   poll 114 ms later already returns `3`; the credentials query alone does not
   start it — a poll between steps 3 and 4 still returned `0`)
5. App polls `APP&WIFIS` ~1×/s until `2` (phone associated; ~6.5 s in the
   capture), then **stops polling** and sends `APP&WPING` → `MCU&WPING`
   keepalives every ~10 s while the phone finishes DHCP and opens
   **TCP to 192.168.200.1:8475** (device = .1, phone = .2)
6. `MCU&WIFIS&1` = **TCP client connected** (the TCP SYN in the packet capture
   precedes it by ~0.4 s). NOT "transferring": state 1 is reported before any
   upload command.
7. App: `APP&U&<date>&<ts>` → `MCU&U&<size>` (e.g. 1,492,892) — selects the
   recording; BLE bulk briefly restarts on `001120a1` and must be discarded.
   ~230 ms later: `APP&U&WIFI` → `MCU&U&WIFI` + repeat `MCU&U&<size>`.
   **`APP&U&WIFI` is a MODIFIER**: it reroutes the upload selected by the
   preceding `APP&U&<date>&<ts>` to the TCP socket and names no recording
   itself — sent alone it has nothing to reroute.
8. Device pushes the **raw MP3** over TCP; `MCU&OFF` at completion
   (TCP FIN at the same instant); app: `APP&WIFIC` ×2 → `MCU&WIFIC`.
   Not entirely frameless at the tail: live hardware (2026-07-24, one sample)
   sent **10 surplus bytes after the announced length** on the TCP stream.
   Content not yet identified — only the length is known. The `MCU&U&<size>`
   announcement is authoritative (the BLE download of the same recording is
   byte-identical at exactly that length); clients must keep exactly the
   announced bytes and treat anything past them as a trailer, not payload.

State machine `MCU&WIFIS&<n>`: `0` off → `3` AP up → `2` client associated →
`1` TCP client connected on :8475. The keepalive is `APP&WPING`; `APP&PING`
appears in no capture.

Measured throughput: 1.49 MB in 2.13 s (~5.6 Mbps). File integrity: stream starts
with MP3 sync `fff348c4`, byte count matches the `MCU&U&` announcement.

**Trailing bytes after the file (observed 2026-07-25, live device).** The TCP
stream is *not* purely the file: after the announced byte count the device sent
**10 extra bytes — `BA 5A 02 8F 04` repeated twice**. They are not part of the
audio: a BLE download of the same recording yielded exactly the announced
26,396 bytes, whose sha256 matched an independently archived copy of that same
recording, and the file's own last five bytes are `08 D3 F6 8B AB`, so the
trailer is neither a duplicated tail nor audio data. Its meaning is unknown
from a single sample.

**Client rule:** treat `MCU&U&<size>` as authoritative — read exactly that many
bytes and ignore any surplus. A client that drains the socket until EOF will
overshoot and fail an exact-length integrity check (this is precisely how the
trailer was discovered).

### A rebind propagates to the AP password (VERIFIED on hardware 2026-07-29)

Step 3 above records *what* the AP password is (`key[:8]`) but said nothing
about *when* it is derived, and nobody had previously rebound a device and then
used Wi-Fi on it. That combination is now verified: the password tracks the
**live binding**, and the change survives both the `APP&BLE&RESET` and the
reboot a rebind requires.

Evidence, on `PKT01_EXAMPLE` after `APP&BLE&RESET` followed by adopting a
locally generated key:

1. `pocket-cli probe` — the BLE handshake succeeded with the new key in 180 ms,
   so the rebind held.
2. `pocket-cli raw WIFI` — the device answered `MCU&WIFI&PKT01_EXAMPLE&<psk>`
   where `<psk>` was the **new** key's first 8 characters, not the old key's. So
   the rebind propagated all the way into the Wi-Fi subsystem.
3. `pocket-cli download … wifi` — the AP came up and broadcast under the right
   name, and BLE stayed alive throughout (an `MCU&WPING` arrived mid-attempt).

**The consequence is the operationally important part: every device that has
ever joined that AP now holds a stale credential.** The SSID does not change
with the password — it *is* the BLE name (step 3) — so a Mac or phone that
joined before the rotation still matches the network by name, silently offers
the password it remembers, and fails. The failure was observed on both hosts of
the session above: iOS raised the system alert *"Unable to join the network
PKT01_…"*, and macOS (where the join is manual) produced no join error at all —
only `wifi tcp connect timed out after 30.0 seconds`, because nothing ever
associated with the AP. **Neither message distinguishes a stale credential from
an access point that is down**, and that ambiguity is what made this take the
three probes above to isolate. The device is the only witness that can tell them
apart: `APP&WIFIS` returning `3` and never `2` means the AP is up and nothing
joined it.

**An app cannot repair it.**
`NEHotspotConfigurationManager.removeConfiguration(forSSID:)` removes only
configurations the app itself created; neither iOS nor macOS exposes any API
that can remove a network the *user* saved. The person has to forget the network
by hand — macOS: System Settings > Wi-Fi > Advanced…, Known Networks; iOS:
Settings > Wi-Fi > the network's info button > Forget This Network.

**Nor can the SSID be changed to sidestep it.** The SSID is the BLE name (step
3), and the only SSID-bearing command in this protocol is the FORBIDDEN
`APP&WIFI&CH&<ssid>&<psk>` — which provisions the device onto a home network as
a *client*. It does not rename the device's own AP, so there is no supported way
to give a rotated key a fresh SSID and leave the stale entry harmless.

**Do not "solve" this by generating rotated keys that preserve the first eight
characters.** It would hold the AP password stable and avoid the problem
entirely, and it is a **bad idea**: those eight characters are precisely the
credential being rotated away from. Holding them stable leaves the old secret
opening the access point, which is most of what the rotation was for.

Security note: SK is the root secret for both BLE auth and the Wi-Fi AP password —
anyone holding SK can join the AP and pull every recording.

### Reusing one AP session for several recordings (VERIFIED on hardware, 2026-07-30)

**The device does serve a second selection on a live access point, and the
transfer over it then reset.** The first successful macOS Wi-Fi transfer,
`sync-wifi <date> 2`, delivered recording 1 whole (30282 bytes, announced
30282) and then, with the access point still up and **no second join prompt**:

```
[1/2] 20260104101500  100%   trailer after file: 10 bytes
MCU&OFF                       ← first file complete
wifi tcp connect will require en0 …   ← a SECOND connect, and no re-join
MCU&WIFIS&1                   ← the device: a TCP client is connected
MCU&U&25242                   ← the device announces the SECOND file's length
                              ← then: NWError 54, connection reset by peer
```

So the older framing of this section — "nobody has ever issued a second
`APP&U&<date>&<ts>` while the access point was still up", the device may "serve a
second file, refuse, or do something worse" — is superseded. The device accepted a
second TCP connection, accepted a second selection, and announced the length. It
does **not** refuse reuse.

**A later run on the same day completed both recordings over one session**, which
promotes reuse from *served* to *works*:

```
[1/2] 20260104101500  100%   wrote 30282 bytes (announced 30282)
MCU&OFF
wifi tcp connect will require en0 …   ← a second connect, and no re-join
MCU&WIFIS&1
MCU&U&25242                           ← the second file's length
[2/2] 20260104103000  100%   wrote 25242 bytes (announced 25242)
MCU&OFF · MCU&WIFIC

2 recording(s) delivered over 1 access-point session in 29.501 s
```

No second join, no second handshake, no reset. **Session reuse works on FW 1.7.**

**The reset is unexplained, not fixed.** It happened once and did not recur, and
nothing changed in between that touched it — the fallback added in response never
fired in the successful run, because there was nothing to fall back from. Two runs,
one each way, is not enough to call it transient with confidence. Treat a mid-stream
reset as something that can still happen and must never cost a recording, and if you
see one, the transcript is worth recording here.

**The reset must never cost a recording.** In the run above it did: the batch
stopped with one of two recordings delivered, because only a refusal observed
*before* the payload phase triggered the fallback. Since 0.1.5 a reuse that breaks
at any point falls back exactly as a refused one does — the partial bytes are
discarded, a session is opened for that recording, and it is fetched again from
byte zero. **A batch never delivers fewer recordings than the same list
transferred one at a time would.**

**Why it matters.** A session is expensive. Steps 1–5 cost the
`SHUT → WIFIS → WIFI → WIFIO` handshake plus about **6.5 s for the association
alone**, and on iOS `NEHotspotConfiguration.joinOnce` makes the OS discard the
configuration when the phone disassociates — so a session per recording means a
join prompt per recording. Watched on hardware 2026-07-29: a sync of ten
recordings (~354 MB in 30–50 MB files) asked the operator to join the network ten
times and paid the handshake ten times.

**How the client asks.** `PocketSession.downloadOverWiFi(_ recordings:…)`
*attempts* reuse and falls back cleanly, so the worst case is the
one-session-per-recording behaviour and never a wedged device:

1. Steps 1–5 run once. The access point stays up and the host stays associated.
2. Per recording: poll `APP&WIFIS`, open a **fresh TCP connection** to
   `192.168.200.1:8475` — the device closes the socket at `MCU&OFF` (TCP FIN at
   the same instant), so the socket never carries over; the AP and the
   association do — then `APP&U&<date>&<ts>` and `APP&U&WIFI` as in step 7.
3. `APP&WIFIC` ×2 once, at the end.

**What counts as a refusal.** Every one of these is observed *before* a single
payload byte of the new recording has flowed:

| Observation | Reading |
|---|---|
| `MCU&WIFIS&0` on the poll between recordings | The device closed its own session after `MCU&OFF`. The likeliest shape, if reuse turns out not to work. |
| `MCU&WIFIS&3` on that poll | The AP is up with no associated client: the *host* left the network between recordings (`joinOnce`). Restarting is what re-joins. |
| TCP connect to `:8475` refused or timed out | The device stopped listening after the first transfer. |
| `MCU&UNKNOWN`, no reply, or an unexpected shape to the second `APP&U&<date>&<ts>` | The device will not accept a second selection. |
| No `MCU&U&WIFI` for the second `APP&U&WIFI` | It accepted the selection but will not reroute it to the socket again. |

**What counts as an interruption.** Anything that fails *after* the device has
served the selection — the reset above, a truncated stream, a payload that fails
the integrity check. It is a different finding (the device did serve it) but it
gets the same recovery, because the recording has still never had a session of its
own. Any bytes already written are discarded: the client streams to a
`.<name>.partial-<uuid>` companion and removes it, so a broken reuse can never
publish a truncated file or leave one where a later run would mistake it for a
finished download.

On any refusal or interruption the client sends `APP&SHUT` + `APP&WIFIC`, leaves
the network, and opens a fresh session for that same recording — exactly one retry
— and then **stops attempting reuse for the rest of the run**, because a doomed
attempt plus a teardown per recording is worse than not trying.

Two deliberate non-refusals:

- **No answer to the `APP&WIFIS` poll.** Silence is not evidence. A firmware that
  stops answering `APP&WIFIS` must not be read as having closed its session; the
  selection decides.
- **`MCU&U&0` on a reused session.** Ambiguous in principle — the device *could*
  be declining by announcing nothing — but 0-second recordings genuinely exist,
  and treating it as a refusal would tear down a working session every time one
  turned up in a batch. Treated as `emptyRecording`, exactly as on a fresh
  session. **Open sub-question**, worth watching for on hardware.

**A restart waits for the AP to actually be off.** A restart is the only place in
this protocol that closes an access point and immediately reopens one, so it is
the only place that could send `APP&WIFIO` to a device whose AP has not finished
coming down. Whether that matters is unobserved — but the *fallback* is what has
to be trustworthy for the experiment to mean anything: a restart that half-works
would be read as the device refusing session reuse.

So before every reopen (never before the first session, which has nothing to wait
for) the client polls `APP&WIFIS` until it answers `MCU&WIFIS&0`. That is evidence
rather than a guessed sleep, `WIFIS` is already this sequence's state oracle, and
it is cheap: the device reports state transitions fast — a poll 114 ms after
`APP&WIFIO` already reads `3` (step 4) — so a prompt device costs exactly one
extra round-trip. The restart sequence is therefore:

```
APP&SHUT, APP&WIFIC          ← teardown
APP&WIFIS → MCU&WIFIS&0      ← the AP really is down
APP&SHUT, APP&WIFIS, APP&WIFI, APP&WIFIO   ← steps 1–4 of the next session
```

The wait is bounded (by the readiness timeout, capped at 5 s). **On expiry the run
stops and says so, naming the last state seen, and no second `APP&WIFIO` is
sent** — pressing on would build an access point on a state nothing can describe,
which is the failure mode most likely to be misattributed.

**The keepalive now spans the whole session.** `APP&WPING` used to cover one
stretch, the TCP connect, because a session lasted one transfer. Across a batch
there are gaps between files, so the client pings whenever the session has been
silent for the ping interval — and only then, so nothing pings on top of a
transfer that is already streaming bytes.

### The access point has a lifetime, and a manual join can outlast it (hardware, 2026-07-28)

The device brings its AP up on `APP&WIFIO` and does not hold it open
indefinitely. Where the join is manual — macOS, where the client prints
instructions and waits for the operator — the pause between `APP&WIFIO` and the
TCP connect is however long a person takes in System Settings, and a minute is
enough to lose the AP.

Observed on a Mac still joined to the recorder's AP, moments after a failed
transfer:

| Probe | Result | Reading |
|---|---|---|
| `ifconfig en0` | `inet 192.168.200.2 netmask 0xffffff00` | association and DHCP both succeeded |
| `route -n get 192.168.200.1` | `interface: en0`, no gateway | correct interface route, nothing hijacked |
| `ping 192.168.200.1` | `No route to host` | ARP unanswered |
| `nc -vz 192.168.200.1 8475` | `No route to host` | same, at the transfer port |

`No route to host` on a directly-connected subnet with a valid interface route
means the peer is not answering at layer 2 — the device had answered DHCP minutes
earlier and was gone by the time the transfer ran. The only symptom reaching the
process was `wifi tcp connect timed out after 30.0 seconds`.

`APP&WPING` therefore starts **before** the join rather than after it, so the
link (and the AP with it) survives a human-paced association. The AP lifetime is
measured in the next section: **~59 s unassisted**, which a person in System
Settings can easily outlast and a programmatic `NEHotspotConfiguration` join
never comes close to — which is why the phone path never showed this.

One correction to the table above, given that measurement. `No route to host`
was read at the time as a possible macOS routing quirk. It almost certainly was
not: those probes were typed by hand *after* a failed transfer, minutes past the
~59 s the AP survives, so the device's radio was simply off. macOS does not tear
down the interface address or the route when an AP vanishes, so the lease and the
`en0` route stayed in place, looking correct, describing a network that no longer
existed. ARP went unanswered because there was nothing there to answer. **Host-side
probes of this AP are only meaningful while something is holding it up** — run
them against `probe-ap-lifetime --keepalive`, not after a failure.

### `APP&WPING` does extend the access point (hardware, 2026-07-29)

It was worth testing rather than assuming: `APP&WPING` is described in the
command table only as the "Wi-Fi-session keepalive", and this client read that as
*extending the access point* when it might have kept nothing but the BLE session
alive. Two releases rested on the stronger reading. Nothing in any capture
separates the two, because the vendor app's join is programmatic and fast, so its
AP never came close to expiring.

`probe-ap-lifetime` settles it by bringing the AP up and polling `APP&WIFIS` to
destruction **with nothing joining it**, so no host-side variable can be mistaken
for the device's own behaviour. Two runs, identical but for the pings, 1 s poll
cadence, from the `MCU&WIFIO` ack:

| | keepalive OFF | keepalive ON (`--ping 10`) |
|---|---|---|
| AP up (`MCU&WIFIS&3`) | +0.060 s | +0.059 s |
| a client associated (`&2`) | +6.644 s | +6.524 s |
| `APP&WIFIS` polls answered | 57 of 57 | 171 of 171 |
| `APP&WPING` sent / answered | 0 / 0 | 17 / 17 |
| **AP lifetime** | **59.189 s** (`MCU&WIFIS&0`) | **still up at the 180 s cap** |

**The unassisted access-point lifetime on this device is ~59 s, and `APP&WPING`
extends it to at least 3× that.** Starting the keepalive before the join is
therefore correct, and the reasoning in the section above stands.

Both runs picked up an associated client at ~6.5 s that the probe did not create —
the Mac auto-joining a remembered network. It is reported as a confound, and for a
single run it is one. Across this pair it is not: the same association arrived at
the same moment in both, leaving the pings as the only difference. It also shows
the device holds the AP up for an associated client that never opens a socket —
state `2` persisted for the full 180 s and never advanced to `1`.

**What this rules out.** The keepalive covers the whole session: it starts on the
`MCU&WIFIO` ack before any joiner, is handed to the live session, and pings
through the TCP connect itself. So in the `sync-wifi` run that reached
`MCU&WIFIS&2` and then timed out connecting to `192.168.200.1:8475`, the access
point was up, the host was associated, and pings were flowing. **AP lifetime is
not what fails that transfer.** What remained was the device's TCP listener on
:8475, or this client's socket code — and the listener is ruled out by the capture
itself, which shows the official app's SYN *preceding* its `APP&U&…` selection, so
the listener is open before a recording is ever chosen.

**That leaves this client's socket code, and two defects were found in it** (both
in `Sources/PocketClient/Transport/WiFiTransfer.swift`, both fixed, neither yet
confirmed on hardware):

1. `NWConnection`'s `.waiting(NWError)` — the reason the path is not usable — was
   discarded by the connect's state handler, so a failing run could only ever
   report its own timeout. **This is why the cause could be proposed and
   eliminated three times.** The reason now reaches the thrown message and the
   whole state sequence reaches `DeviceEvent.wifiConnectPath`.
2. The connection was created with default parameters and named no interface.
   `Network.framework` runs its own path evaluation rather than following the BSD
   route table, and this AP provides no internet while the host runs a mesh VPN
   whose `utun` holds a default route — so a path that cannot reach
   `192.168.200.1` can be selected, or waited on indefinitely. A silent 30 s
   timeout with no error delivered to the caller is that signature exactly. It
   also explains why iOS worked: there the app joins with
   `NEHotspotConfiguration`, so the path belongs to the process. The connection
   now requires the interface holding this host's address on the device's `/24`.

Next hardware run: `pocket-cli sync-wifi <date> 2` on macOS. Whatever it does, the
transcript will now name the interface the connect required and either quote
`Network.framework`'s reason for refusing the path or state that it gave none.
Holding the AP up with `probe-ap-lifetime --keepalive --cap 300` and trying
`nc -vz 192.168.200.1 8475` from another shell while it runs remains the way to
cross-check the listener from outside this client.

### Ethernet blocks the join, and a stale address hides it (hardware, 2026-07-30)

That next run happened, and neither socket defect was the whole story. **A network
cable was.** With a wired link carrying the Mac's default route, macOS associates
with the recorder's no-internet access point and then **drops the association**,
while leaving the entire layer-3 configuration in place — address, netmask, route,
and the ARP entry. Unplugging Ethernet made the transfer work on the next attempt.

Two things follow, and the second is the nastier one.

**The host-side evidence lies.** After the association is dropped:

| Probe | Result | What it looks like | What is true |
|---|---|---|---|
| `ifconfig en0` | `inet 192.168.200.2` | joined, leased, routable | a leftover the host never cleaned up |
| `route -n get 192.168.200.1` | `interface: en0` | correct route | a route to nowhere |
| `arp -an` | an entry for the device | the peer was reachable | a cached entry, not a live one |
| `networksetup -getairportnetwork en0` | `not associated` | — | **the only host-side probe that told the truth** |
| `NWConnection` `.waiting` | `ENETDOWN` (POSIX 50) | — | **also true, and delivered to the process** |

This is why the address must never be read as an association. **Every run that has
ever joined the recorder leaves a configuration behind that satisfies a
subnet-based pre-flight**, and it is most misleading exactly when somebody is
testing repeatedly — the address is *always* there by the second attempt. Version
0.1.4's diagnosis went further and read the address as proof that the access
point was still up ("a device that had closed its AP would not still be leasing
this address"); it is not a lease the device grants, and that reasoning was
removed in 0.1.5.

Two facts can contradict an address, and the client now reads both. `IFF_RUNNING`
from `getifaddrs` — the kernel's operational link state, as distinct from the
administrative `IFF_UP` — and `ENETDOWN` on a connection *required* to use that
interface, which cannot mean "the destination is unreachable from here" when the
interface holds an address on the destination's own `/24`. Neither is a shell tool
and neither reads an SSID: `networksetup -getairportnetwork` is a command-line
program with no API behind it, and SSID reads on current macOS are gated behind
Location Services, so a check built on one would report "not associated" for a
permissions reason. **Note both are one-directional**: they can show that the host
is not associated; nothing available here can show that it is.

**The warning now precedes the join.** `ManualHotspotJoiner` asks
`NWPathMonitor` whether the default path runs over wired Ethernet and, if it does,
prints "UNPLUG ETHERNET FIRST" above the Wi-Fi steps — the point in the run where
it can still be acted on, rather than in a failure report afterwards. This cost
several hardware rounds to find.

`pocket-cli sync-wifi <date> [count]` remains the instrument for the *other* open
question — whether a live session will serve a second recording — and it cannot
answer this one, because everything it does happens downstream of a join.

## App behavior observations (from captures)

- Sync window: app issues `LIST&<date>` for a rolling 8-day window (today ± several days)
- Keepalive: `APP&BAT` every ~30 s while connected
- Unknown commands are answered with `MCU&UNKNOWN` (safe probing)
- **Slider emits no BLE events on movement** (hardware mic-mux); position is only
  readable via the `REC&SECEN` query
- `WF` answered `V9` from Mac probe, `ec9` from phone session — `ec9` is likely a build
  hash; app UI displays "Wi-Fi Firmware V9" (Device settings screen, verified)

## Open items

1. Not blocking. `ffd0` / `e49a3001` / `e49a25f8` = Wi-Fi/BLE combo-chip services
   (Wi-Fi OTA receive + provisioning; `ffd0` likely factory/test) — evidence:
   no references in app (Dart/Java strings, UUID fragments), zero traffic in all captures,
   Wi-Fi firmware strings contain a packetized BLE OTA receiver and app strings contain
   "WiFi OTA via BLE", `APP&OTA&WIFI&`, "BLE WiFi OTA requires MCU T22+ and WiFi V10+".
   MCU firmware is encrypted (`AOTA` container, entropy 8.0) — not analyzable offline.
   **Read-only policy: never write to these characteristics (brick risk).**
2. ~~**Will the device serve a second `APP&U&<date>&<ts>` while its access point
   is still up?**~~ **ANSWERED 2026-07-30: yes.** It accepted a second TCP
   connection with no re-join and announced the next file's length — see
   [Reusing one AP session for several recordings](#reusing-one-ap-session-for-several-recordings-verified-on-hardware-2026-07-30).
   **What replaces it: why did the transfer over that reused session reset
   (`ECONNRESET`) after the announcement?** One observation, so nothing is settled:
   it may be device behaviour to fall back from, or this client's socket handling.
   Not blocking — a reuse that breaks now falls back to a session opened for that
   recording, so a batch cannot deliver fewer recordings than one-at-a-time would.
   Next: `pocket-cli sync-wifi <date> 3` on macOS with Ethernet unplugged, and read
   the `session:` lines. Whether the reset repeats, whether it always lands at the
   same point, and whether the device reports `MCU&WIFIS&0` promptly after the
   teardown that follows it are all in that transcript.
   Sub-questions still open inside it: whether `MCU&U&0` on a reused session means
   "empty recording" or "declined", and whether the device needs a settling period
   between `APP&WIFIC` and the next `APP&WIFIO` beyond reporting `MCU&WIFIS&0`
   (which the client now waits for).
3. ~~**Does `APP&WPING` extend the access point, or only keep the BLE session
   alive?**~~ **ANSWERED 2026-07-29: it extends the AP.** ~59 s unassisted,
   still up at 180 s with pings — see
   [`APP&WPING` does extend the access point](#appwping-does-extend-the-access-point-hardware-2026-07-29).
   The AP comes up ~60 ms after the `MCU&WIFIO` ack (a single capture had said
   ~114 ms), and an associated client that opens no socket does not shorten its
   life.
4. ~~**Why does the TCP connect to `192.168.200.1:8475` time out on macOS even
   with the AP verifiably up?**~~ **ANSWERED 2026-07-30: a network cable.** With a
   wired link holding the default route, macOS associated with the no-internet
   access point and then dropped the association, leaving the address, route and
   ARP entry behind so the host looked joined. `ENETDOWN` from `Network.framework`
   was accurate throughout. Unplugging Ethernet produced the first successful
   macOS Wi-Fi transfer — see
   [Ethernet blocks the join, and a stale address hides it](#ethernet-blocks-the-join-and-a-stale-address-hides-it-hardware-2026-07-30).
   The client now warns before the join prompt and no longer reads an address as
   proof of an association.

Everything needed is mapped: auth, GATT, status, inventory, BLE download, Wi-Fi transfer,
delete, record control (STA/STO/PAU/RESU), live stream, slider query, USB mode,
storage stats.

## Additional commands discovered via APK string table (not all verified live)

| Command | Meaning (from context strings) |
|---|---|
| `APP&PAU` / `APP&RESU` | Pause / resume recording — **PROBED 2026-07-25 (FW 1.7): both answer `MCU&UNKNOWN`, i.e. NOT IMPLEMENTED.** Kept here as a string-table artefact; re-test on future firmware |
| `APP&LNP&` / `APP&LNS&` | Unknown (list-related?) |
| `APP&LOG&GET` / `APP&LOG&TAIL` / `APP&LOG&MARK` / `APP&LOG&ACK&` | Device debug-log fetch protocol |
| `APP&OTA&` / `APP&OT&` / `APP&OT&OVER` | MCU OTA firmware update over BLE — **never use** |
| `APP&OTA&WIFI&` / `APP&WOTA` | Wi-Fi chip OTA — **never use** |
| `APP&WIFI&CH&<ssid>&<password>` | Provision device onto home Wi-Fi — **forbidden here; do not confuse with the bare read-only credentials query `APP&WIFI`** |
| `APP&WIFID` / `APP&WIFI&SWITCH` | Wi-Fi disconnect / mode switch |
| `APP&BLE&OFF` / `APP&BLE&RESET` | BLE off / clear pairing binding (from UI hint: "Reset device with APP&BLE&RESET command to clear binding") |
| `APP&SK&SHORT` | SK variant (short-session?) |

Firmware images found hardcoded in the app (public S3):
`firmware/ota_firmware_T19.bin` (MCU, encrypted), `firmware/wifi_ver10_260202.bin`
(Wi-Fi V10 — we stay on V9)

## App UI findings (settings walkthrough)

- Device screen: Find Pocket (off), FW 1.7, Wi-Fi FW V9, Regenerate Voice Print,
  Lookup Device Files, Reset Device
- "Lookup Device Files" = on-device file browser: free/total MB, per-recording
  "Synced" status, "Quick Transfer" (Wi-Fi) / "Sync Normally" (BLE) buttons
- Developers section: API Keys / Webhooks / Documentation (no USB toggle in this app
  version — docs describe it, but direct probing found the commands anyway)
