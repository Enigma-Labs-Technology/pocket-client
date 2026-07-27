// pocket-client/Sources/PocketClient/PocketKey.swift
import Foundation

/// Generates and validates the recorder's 16-character session key ("binding
/// password", in the vendor's internal vocabulary).
///
/// The device's original key is the first 16 characters of the account's
/// Firebase UID. This type lets the app mint its *own* key instead, so it
/// never has to ask for one — the whole point of self-provisioning.
///
/// ## Why this exact shape
///
/// Offline analysis of the firmware (see the SK-provisioning investigation)
/// established two facts that pin the design:
///
/// - **Validation is length-only.** The firmware accepts any 16-character
///   value as the key; there is no charset check. So a random 16-character
///   string is a legal key.
/// - **The only proven-good domain is `[A-Za-z0-9]`.** Every key the firmware
///   has ever been given is a Firebase-UID prefix, which is alphanumeric. The
///   firmware's handling of anything outside that alphabet is UNKNOWN, and
///   this is the user's only recorder — so we deliberately never leave it.
///   `&` in particular is the protocol delimiter and would corrupt the frame.
///
/// ## Randomness
///
/// Keys are drawn from `SystemRandomNumberGenerator`, which on Apple platforms
/// is a cryptographically secure system CSPRNG (it wraps `arc4random_buf`).
/// Each character is chosen with `Array.randomElement(using:)`, whose stdlib
/// implementation of `RandomNumberGenerator.next(upperBound:)` uses rejection
/// sampling (Lemire's method) — so the draw is **uniform with no modulo bias**,
/// not `raw % 62`. The key is the device credential and the seed of its Wi-Fi
/// AP password, so weak randomness here would weaken both.
public enum PocketKey {
    /// The proven-good alphabet: uppercase, lowercase, digits — 62 symbols.
    /// Deliberately excludes `&` (protocol delimiter) and every other
    /// punctuation / whitespace / non-ASCII character (firmware behavior
    /// UNKNOWN outside `[A-Za-z0-9]`).
    public static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// The firmware's one hard requirement: the key is exactly 16 characters.
    public static let length = 16

    /// A fresh, uniformly random 16-character key from `alphabet`.
    ///
    /// Cryptographically secure and free of modulo bias (see the type's note).
    /// Repeated calls do not repeat in practice: the space is 62^16 ≈ 4.7×10^28.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        // `randomElement(using:)` never returns nil for a non-empty array;
        // `alphabet` is a compile-time constant of 62 elements.
        let characters = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }
        return String(characters)
    }

    /// Whether `key` is a value this package is willing to install: exactly
    /// `length` characters, every one of them in `alphabet`. Used to vet an
    /// operator-supplied key before it is sent to the device — the firmware
    /// would accept a wrong-length or exotic-charset key on length alone (or
    /// mis-parse it), so the check lives here, not on the device.
    public static func isValid(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == length else { return false }
        let allowed = Set(alphabet.map { $0.unicodeScalars.first! })
        return scalars.allSatisfy { allowed.contains($0) }
    }
}
