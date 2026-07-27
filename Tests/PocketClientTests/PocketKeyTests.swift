// pocket-client/Tests/PocketClientTests/PocketKeyTests.swift
import Foundation
import Testing
@testable import PocketClient

@Test func generatedKeyIsExactlySixteenCharacters() {
    for _ in 0..<200 {
        #expect(PocketKey.generate().count == 16)
    }
}

/// The firmware's charset handling outside `[A-Za-z0-9]` is UNKNOWN and this
/// is the user's only recorder, so every generated character must stay inside
/// the proven-good alphabet — and `&`, the protocol delimiter, must never appear.
@Test func generatedKeyUsesOnlyTheAllowedAlphabet() {
    let allowed = Set(PocketKey.alphabet)
    for _ in 0..<500 {
        let key = PocketKey.generate()
        #expect(key.allSatisfy { allowed.contains($0) })
        #expect(!key.contains("&"))
    }
}

@Test func alphabetIsExactlyAlphanumericAndExcludesTheDelimiter() {
    #expect(PocketKey.alphabet.count == 62)
    #expect(Set(PocketKey.alphabet).count == 62)   // no duplicates
    #expect(PocketKey.alphabet.allSatisfy { $0.isLetter || $0.isNumber })
    #expect(!PocketKey.alphabet.contains("&"))
}

/// Repeated generation must not repeat: a key that collided would silently
/// hand two devices the same credential (and the same Wi-Fi AP password).
@Test func repeatedGenerationDoesNotRepeat() {
    var seen = Set<String>()
    for _ in 0..<10_000 {
        seen.insert(PocketKey.generate())
    }
    #expect(seen.count == 10_000)
}

/// Not a proof of cryptographic quality — just a smoke test that the draw is
/// not stuck on a subset. Over 62 symbols × 16 positions × 4000 keys = 64000
/// characters, every alphabet symbol should appear many times; a generator
/// with a dead range (e.g. modulo bias dropping the top few symbols) would
/// leave gaps here.
@Test func everyAlphabetSymbolIsReachable() {
    var counts: [Character: Int] = [:]
    for _ in 0..<4000 {
        for character in PocketKey.generate() {
            counts[character, default: 0] += 1
        }
    }
    for symbol in PocketKey.alphabet {
        #expect((counts[symbol] ?? 0) > 0, "symbol \(symbol) never appeared")
    }
}

@Test func generatedKeysPassValidation() {
    for _ in 0..<200 {
        #expect(PocketKey.isValid(PocketKey.generate()))
    }
}

@Test func validationRejectsWrongLength() {
    #expect(!PocketKey.isValid(""))
    #expect(!PocketKey.isValid("short"))
    #expect(!PocketKey.isValid("012345678901234"))      // 15 — one short
    #expect(PocketKey.isValid("0123456789012345"))      // 16 — the valid boundary
    #expect(!PocketKey.isValid("01234567890123456"))    // 17 — one over
}

@Test func validationRejectsCharactersOutsideTheAlphabet() {
    // 16 characters, but each carries one forbidden character.
    #expect(!PocketKey.isValid("APP&SK&abcdefghi"))    // '&' — protocol delimiter
    #expect(!PocketKey.isValid("abcdefghijklmno "))    // trailing space
    #expect(!PocketKey.isValid("abcdefghijklmn-o"))    // hyphen
    #expect(!PocketKey.isValid("abcdefghijklmné0"))    // non-ASCII
    #expect(!PocketKey.isValid("abcdefghijklmn_0"))    // underscore
}

@Test func validationAcceptsAMixedCaseAlphanumericKey() {
    // A placeholder in the real key's shape: 16 mixed-case alphanumerics,
    // which is what a Firebase-UID prefix looks like. Not a live credential.
    #expect(PocketKey.isValid("ExampleKey000000"))
}
