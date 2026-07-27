// pocket-client/Tests/PocketClientTests/SessionKeyStoreTests.swift
import Foundation
import Security
import Testing
@testable import PocketClient

/// A service name no real app uses, unique per call so parallel tests and
/// repeated runs never collide with each other or with a genuinely stored
/// session key.
private func uniqueTestService() -> String {
    "com.privatepocket.pocket-client.tests.\(UUID().uuidString)"
}

/// Probes once per process whether the data protection keychain is usable.
///
/// `SessionKeyStore` requires the data protection keychain, and on macOS
/// that requires a code-signed host with an application identifier. A bare
/// SwiftPM test runner is not one, so `SecItemAdd` can fail with
/// `errSecMissingEntitlement` (-34018) or similar. That is an environment
/// limitation, not a bug in the store — the affected tests are *skipped*
/// (never faked green) with an explicit message.
private enum KeychainProbe {
    private static let unavailableStatuses: Set<OSStatus> = [
        errSecMissingEntitlement,
        errSecNotAvailable,
        errSecInteractionNotAllowed,
    ]

    /// `nil` when the Keychain works here; otherwise the blocking OSStatus.
    static let blockingStatus: OSStatus? = {
        let store = SessionKeyStore(service: uniqueTestService())
        do {
            try store.save("availability-probe")
            try? store.delete()
            return nil
        } catch SessionKeyStoreError.keychainFailure(let status)
            where unavailableStatuses.contains(status) {
            print(
                "SessionKeyStoreTests: Keychain unavailable in this environment "
                + "(OSStatus \(status)); skipping round-trip tests."
            )
            return status
        } catch {
            // Any other failure is a real bug — let the tests run and fail.
            return nil
        }
    }()

    static var isAvailable: Bool { blockingStatus == nil }
}

private let requiresKeychain: ConditionTrait = .enabled(
    if: KeychainProbe.isAvailable,
    "Keychain unavailable in this test environment (unsigned test runner cannot use the data protection keychain) — round trip not exercised"
)

@Test(requiresKeychain) func saveLoadDeleteRoundTrip() throws {
    let store = SessionKeyStore(service: uniqueTestService())
    defer { try? store.delete() }

    try store.save("0123456789abcdef")
    #expect(try store.load() == "0123456789abcdef")

    try store.delete()
    #expect(try store.load() == nil)
}

@Test(requiresKeychain) func secondSaveOverwritesFirst() throws {
    let store = SessionKeyStore(service: uniqueTestService())
    defer { try? store.delete() }

    try store.save("first-account-key")
    try store.save("second-account-key")
    #expect(try store.load() == "second-account-key")
}

@Test(requiresKeychain) func loadReturnsNilWhenNothingStored() throws {
    let store = SessionKeyStore(service: uniqueTestService())
    #expect(try store.load() == nil)
}

@Test(requiresKeychain) func deleteWhenNothingStoredIsNoOp() throws {
    let store = SessionKeyStore(service: uniqueTestService())
    try store.delete()
    #expect(try store.load() == nil)
}

@Test(requiresKeychain) func storesDifferForDifferentAccounts() throws {
    let service = uniqueTestService()
    let primary = SessionKeyStore(service: service, account: "session-key")
    let other = SessionKeyStore(service: service, account: "other-account")
    defer {
        try? primary.delete()
        try? other.delete()
    }

    try primary.save("primary-key")
    #expect(try other.load() == nil)

    try other.save("other-key")
    #expect(try primary.load() == "primary-key")
    #expect(try other.load() == "other-key")
}

// Validation happens before any Keychain call, so this runs everywhere.
@Test func emptyKeyIsRejected() {
    let store = SessionKeyStore(service: uniqueTestService())
    #expect(throws: SessionKeyStoreError.emptyKey) {
        try store.save("")
    }
}
