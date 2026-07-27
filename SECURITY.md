# Security policy

This package drives hardware that can be permanently destroyed by the wrong
write, and its safety properties are enforced in code but *explained* in
documentation. A fork inherits the code and none of the reasoning. This file is
the part of the reasoning that concerns reporting.

Read [Safety — read this first](README.md#safety--read-this-first) before
reporting anything. It states what the package refuses to do and why.

## Report privately

**Use GitHub's private vulnerability reporting.** It creates a draft advisory
visible only to you and the maintainers, with a private fork to work in.

- Go to the repository's **Security** tab → **Report a vulnerability**, or open
  <https://github.com/Enigma-Labs-Technology/pocket-client/security/advisories/new> directly.

Maintainers: this must be switched on for the button to exist — **Settings →
Advanced Security** (older UIs: *Code security and analysis*) → **Private
vulnerability reporting → Enable**. It is free on public repositories.

If that route is unavailable to you, open a public issue that says only that you
have a finding you do not want to describe publicly, and how to reach you. **Put
no frames, byte sequences, UUIDs, or reproduction steps in it.** A placeholder
issue is not a disclosure; a detailed one is.

### Why privately, and why it matters more here

For most packages, private reporting buys time to ship a patch. Here it buys
something the patch cannot deliver.

The characteristic hazard of this package is not data exfiltration — it is an
irreversible physical write. The MCU firmware is an encrypted `AOTA` container
that cannot be analysed offline, so a failed firmware write cannot be diagnosed,
undone, or reflashed by anyone outside the vendor. **There is no recovery path.
A bricked unit is scrap.**

That makes public disclosure asymmetric in a way it usually is not. A public
issue describing a working OTA sequence is a set of instructions that anyone can
follow immediately, against their own device or someone else's, and the damage
lands before a fix exists. No release we can ship un-bricks a device that was
already bricked by reading the issue. The people most likely to try it are
exactly the curious owners this project is for.

So: the finding stays private until there is something useful to say publicly,
and what we publish is calibrated — what is affected and what to change, without
a copy-paste recipe for the destructive frame.

## What to include

- What you observed, and how you established it. Use the same grading the rest
  of this project uses: hardware-verified, settled by probing, compile-only, or
  inferred. Say which. See
  [How claims in this document are graded](README.md#how-claims-in-this-document-are-graded).
- Device model, firmware version, and Wi-Fi firmware version, if the finding is
  device-side.
- The package version or commit.
- Whether you actually executed the dangerous path or reasoned about it. Both
  are useful; conflating them is not.

**Do not attach packet captures or device logs.** The protocol is plain ASCII,
so a capture of any session contains the session key in cleartext, and captures
of real use are recordings of somebody's voice. Redact session keys, MAC
addresses, and device names before pasting any transcript. If a capture is
genuinely necessary to explain the finding, say so in the advisory and we will
agree how to handle it — do not upload it first.

Please do not test a destructive hypothesis on hardware you cannot afford to
lose, and do not test it on hardware that is not yours.

## What happens next

This is a small project with one maintainer and no funded security programme, so
these are aims rather than guarantees:

- Acknowledgement within about a week.
- An assessment — including "this is working as documented, here is why" — once
  the report is understood.
- A fix or a documentation change in the next tagged release, and a published
  advisory once there is a version to point people at.
- Credit in the advisory if you want it, and none if you do not. There is no
  bounty.

If we disagree about whether something is a vulnerability, that disagreement
gets written down rather than closed silently.

**What a fix cannot do:** it cannot recover a bricked device, and it cannot
reach the vendor. We can change this package, this documentation, and the tests
that hold both in place. That is the whole of our remit.

## In scope

Anything in this repository — the `PocketClient` library, the `pocket-cli`
harness, the tests, and the protocol documentation under `docs/`.

Conventional software issues:

- Memory safety, data races, and concurrency bugs.
- Correctness bugs with a security consequence — a download that silently
  truncates, a parser that mis-frames, an error that is swallowed.
- Leakage of the session key: logged, written to disk, persisted with weaker
  Keychain accessibility than documented, or exposed in an error message. The
  key is the whole of the device's access control.

And, specific to this package, the hazard class that matters more than any of
the above — **anything that could cause a write to a forbidden service or a
forbidden command.** That is this project's characteristic failure, not a
conventional CVE, and it is in scope even when it requires an unlikely sequence
of events:

- Any path that reaches the three services the package must never discover or
  write — `ffd0`, `e49a3001-…`, `e49a25f8-…`. Their purpose is `inferred`, not
  proven; the inference is strong enough to justify never going near them.
- Any path that emits `APP&OTA&`, `APP&WOTA`, `APP&OTA&WIFI&`, or
  `APP&WIFI&CH&…`. These have no `Command` case by design; a way to produce one
  of these frames through the library's public API is a report.
- Any way to reach `APP&BLE&RESET` other than `pocket-cli reset` behind its
  flag and its typed confirmation.
- Any reintroduction of wildcard GATT discovery, on the scanned-connect path or
  the iOS state-restoration path.
- Any way operator input becomes frame bytes — `RawProbe` is a fixed lookup
  table precisely so that no user string is ever concatenated into a frame.
- Any weakening of the tests that enforce the above. The compiler-forced
  exhaustive walk over `Command` is load-bearing for safety, not for coverage.

Reports in this class are welcome even if you cannot demonstrate them on
hardware. "This code path could reach that service" is worth reading; "I bricked
my device proving it" is not what we are asking for.

## Out of scope

- **The vendor's firmware, the vendor's app, and the vendor's cloud.** This is
  an independent, reverse-engineered client with no relationship to the
  manufacturer — see the [Disclaimer](README.md#disclaimer). We cannot fix,
  triage, coordinate, or responsibly disclose anything about the vendor's own
  software, and accepting reports about it would imply a channel that does not
  exist. Take those to the vendor.
- **The protocol's inherent hazards**, which are documented rather than fixable:
  the device can be bricked by writes this package deliberately cannot make; a
  session key is a bearer credential with no rotation beyond rebinding; the wire
  is unencrypted plain ASCII; rebinding is reversible only through the vendor's
  app. These are properties of the device. They are described in the README and
  in `docs/protocol/ble-protocol.md`, and describing them again is not a report.
- **`pocket-cli reset --wipe-all-recordings` destroying recordings.** That is
  its purpose, stated in the flag name, gated behind the flag, an explicit
  session key, and a typed confirmation naming the device.
- Attacks requiring physical possession of an unlocked device that is already
  yours, or requiring the user to run code they wrote themselves.
- Anything in a fork. Report it to the fork.

## Firmware variance is a report, not a defect report

Every `hardware` claim in this repository rests on **one physical device running
one firmware version**. Behaviour on other hardware revisions, other colours, or
other firmware is unknown, and a firmware update can invalidate any of it.

So "it behaves differently on mine" is a genuinely useful contribution, and it is
not a vulnerability. **File it as a normal public issue**, with your firmware
version and what you saw — that is how the sample size stops being one.

The one exception is the reason this section exists: if the divergence you found
is a way to reach a forbidden service or command on your firmware, that is not a
variance report. Use the private channel above.
