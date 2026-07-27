# Contributing

Contributions are welcome. This file is the short version of the rules; the
reasoning behind them is in [Safety — read this first](README.md#safety--read-this-first),
which is worth reading once before you change anything that touches the wire.

## Running the tests

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test

# iOS compile check
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -scheme PocketClient -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
```

`DEVELOPER_DIR` must point at a full Xcode — the command-line-tools toolchain
cannot run the test target. Any Xcode supplying a Swift 6 toolchain will do;
the path above is one example, not a requirement. CI runs these same two
commands on every push and pull request.

The package requires `swift-tools-version: 6.0` and targets iOS 17+ / macOS 14+.

## The invariants

These are not style preferences. Each one is the reason it is safe to run this
package against hardware that has no recovery path.

- **Never add wildcard GATT discovery.** Every `discoverServices` and
  `discoverCharacteristics` call passes an explicit `PocketGATT` UUID list, and
  never `nil`. *Why:* three services on this device must never be discovered or
  written; a wildcard enumerates them. This holds on the iOS state-restoration
  path too — a restored peripheral gets the same explicit lists.

- **Never add a `Command` case for `APP&OTA&`, `APP&WOTA`, `APP&OTA&WIFI&`, or
  `APP&WIFI&CH&`.** *Why:* the MCU firmware is an encrypted container with no
  offline analysis and no reflash path outside the vendor, so a failed or
  malformed firmware write is a scrap device; the Wi-Fi provisioning command
  reconfigures the radio out from under the transfer protocol. `Command` is the
  safety boundary — if a frame has no case there, no code path in the library
  can produce it.

- **`Command.wifiCredentials` stays argument-less.** *Why:* the safe credentials
  query is bare `APP&WIFI`; the forbidden provisioning command is the same verb
  with arguments appended. Argument-less by construction is what keeps the two
  from ever drifting together. No representable command may extend the
  `APP&WIFI&` prefix.

- **`APP&BLE&RESET` stays confined to `pocket-cli`, behind its typed
  confirmation, and must remain unrepresentable as a `Command`.** *Why:* it
  permanently erases every recording and clears the binding, with no undo. Its
  bytes exist at exactly one call site, built raw, so that nothing in the
  library — and nothing that links the library — can reach it.

- **Never weaken the tests that enforce the above.** *Why:* they are the
  enforcement, not a description of it. `CommandTests` walks every `Command`
  case through a `next(after:)` switch with no `default`, so a new case will not
  compile until it is spliced into the walk and routed through the forbidden-
  substring assertions; the walk's length is asserted exactly, so splicing a
  case *out* fails too. If you add a `Command` case, join the walk and update
  that count — do not relax the assertion.

If you believe an invariant is wrong, open an issue and argue it. Do not open a
pull request that quietly relaxes one.

## Grade your evidence

If you add or change a capability, state how you established it, using the same
four tags as the rest of the project
([How claims are graded](README.md#how-claims-in-this-document-are-graded)):

| Tag | Means |
|---|---|
| `hardware` | Observed working against a real device. |
| `probed` | Settled by sending the frame and reading the answer — including negative results. |
| `compile-only` | Compiles, unit-tested where the logic is pure, never executed against real hardware. |
| `inferred` | Reasoned from firmware or app strings and from absent traffic. Not proven. |

**Do not round up.** "It compiled and looked right" is `compile-only`.
"The device did not error" is not `probed` — only a distinctive reply naming the
verb proves support, and only `MCU&UNKNOWN` proves absence. `inferred` is a
reason for caution, never a licence to act.

The sample size for every `hardware` claim in this repository is one device on
one firmware version. If yours behaves differently, that is a useful issue, not
a bug report — say which firmware you are on.

## The ordinary things

- **The test suite stays hermetic.** No hardware, no network, no sleeping on
  wall-clock time. Tests replay captured transcripts against the fake transport
  in `Tests/PocketClientTests/Support/`. If a change cannot be tested without a
  radio, factor the logic out of the radio until it can be — that is why the
  scan-list policy, the radio-state mapping, and the restoration plan selection
  are plain value types.
- **The package has no dependencies and should keep none.** It links Apple
  frameworks only: `CoreBluetooth`, `Network`, `Security`, and `NetworkExtension`
  on iOS. A dependency here is a supply-chain path into a process that writes to
  brickable hardware. Test-only dependencies count.
- **Do not hardcode a test count** in documentation, badges, or anything else
  that is not itself compiler-checked. It rots silently.
- **Never commit a session key, a packet capture, or a recording.** The protocol
  is plain ASCII, so a capture of any session contains the session key in
  cleartext, and recordings are somebody's voice. `.gitignore` covers the
  obvious cases; redact transcripts you paste into issues. Every identifier in
  this repository is a placeholder of the correct shape, and new ones should be
  too.

## Pull requests

- One concern per pull request; say what you changed and why in the description.
- New behaviour comes with tests. Behaviour that only exists on hardware comes
  with the grading tag that says so.
- Update the README and `docs/protocol/ble-protocol.md` when you change what is
  true, and add an entry to [`CHANGELOG.md`](CHANGELOG.md) under `Unreleased`.
- CI must be green. It runs the two commands above; there is nothing to
  reproduce locally that the workflow does differently.
- The project's documentation voice is plain and calibrated: state what was
  established and how, and claim nothing further.

By contributing you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), the license this project is released under.
