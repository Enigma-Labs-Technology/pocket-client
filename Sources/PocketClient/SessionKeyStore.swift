// pocket-client/Sources/PocketClient/SessionKeyStore.swift
import Foundation
import Security

/// Errors thrown by ``SessionKeyStore``.
///
/// Deliberately separate from `PocketError`: Keychain persistence is an
/// opt-in convenience layered on top of the protocol client, not part of
/// the wire protocol.
public enum SessionKeyStoreError: Error, Equatable, Sendable {
    /// `save` was called with an empty string. An empty session key can
    /// never authenticate, so storing one is always a caller bug.
    case emptyKey
    /// The Keychain returned an item whose payload was missing or not
    /// valid UTF-8 — the item was not written by this store.
    case unexpectedItemData
    /// A Security framework call failed. `status` is the raw `OSStatus`
    /// (e.g. `errSecMissingEntitlement` = -34018) so the failure is
    /// diagnosable; pass it to `SecCopyErrorMessageString` for prose.
    case keychainFailure(status: OSStatus)

    /// True when the failure reflects device state rather than a missing or
    /// broken item, so retrying later can succeed. Currently that is
    /// `errSecInteractionNotAllowed`: with `afterFirstUnlockThisDeviceOnly`
    /// accessibility the item is unreadable until the first unlock after boot
    /// — the case a background-relaunched sync app hits. Callers must not read
    /// a transient failure as "no key stored"; only `load()` returning `nil`
    /// means that.
    public var isTransient: Bool {
        if case .keychainFailure(let status) = self { return status == errSecInteractionNotAllowed }
        return false
    }
}

extension SessionKeyStoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyKey:
            return "session key must not be empty"
        case .unexpectedItemData:
            return "Keychain item exists but its payload is not a UTF-8 string"
        case .keychainFailure(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Security error"
            return "Keychain operation failed: \(message) (OSStatus \(status))"
        }
    }
}

/// Opt-in Keychain persistence for the Pocket session key.
///
/// The session key (by convention the first 16 characters of the account's
/// Firebase UID) is the device credential: it authenticates the BLE session
/// *and* its first 8 characters seed the recorder's WiFi AP password. The
/// package itself never persists it — callers pass it to `PocketDevice`
/// per instance. An app that wants "pair once, sync forever" can use this
/// store instead of hand-rolling Keychain code.
///
/// Storage: one `kSecClassGenericPassword` item keyed on `service` +
/// `account`, UTF-8 encoded.
///
/// Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// - *AfterFirstUnlock*, not *WhenUnlocked*: a background sync (e.g. a BLE
///   reconnect waking the app while the phone is in a pocket) may need the
///   key while the device is locked, including after a reboot once the
///   user has unlocked at least once. *WhenUnlocked* would make background
///   syncs fail whenever the screen is locked.
/// - *ThisDeviceOnly*: the key is a pairing credential and the root of the
///   WiFi AP password, so it must never leave the device — this excludes
///   it from device-to-device backup restores and iCloud Keychain sync.
///   A new phone re-pairs by signing in again, which is the desired flow.
///
/// `kSecUseDataProtectionKeychain` is set on every call so macOS uses the
/// same iOS-style data protection keychain (on iOS the flag is a no-op):
/// without it, macOS writes to the legacy file-based login keychain, where
/// `kSecAttrAccessible` is ignored and access can raise blocking UI
/// prompts. Note this means a macOS process must be code-signed with an
/// application identifier to use the store; unsigned processes (such as
/// bare SwiftPM test runners) get `errSecMissingEntitlement` (-34018).
///
/// Key shape is the caller's responsibility: any non-empty string is
/// accepted. Today's recorders use 16-character keys (the CLI warns on
/// other lengths but does not reject them) and a future device may differ,
/// so this store deliberately does not enforce a length.
public struct SessionKeyStore: Sendable {
    /// The `kSecAttrService` value the item is stored under.
    public let service: String
    /// The `kSecAttrAccount` value the item is stored under.
    public let account: String

    public init(
        service: String = "com.privatepocket.pocket-client",
        account: String = "session-key"
    ) {
        self.service = service
        self.account = account
    }

    /// Persists `key`, overwriting any previously stored key (so re-pairing
    /// to a different account just works).
    ///
    /// - Throws: ``SessionKeyStoreError/emptyKey`` for an empty string,
    ///   ``SessionKeyStoreError/keychainFailure(status:)`` otherwise.
    public func save(_ key: String) throws {
        guard !key.isEmpty else { throw SessionKeyStoreError.emptyKey }
        let data = Data(key.utf8)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Overwrite in place. Re-assert accessibility too, in case an
            // older item was written with a different class.
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SessionKeyStoreError.keychainFailure(status: updateStatus)
            }
        default:
            throw SessionKeyStoreError.keychainFailure(status: addStatus)
        }
    }

    /// Returns the stored key, or `nil` if none is stored. Absence is a
    /// normal state (first launch, after `delete()`), not an error.
    ///
    /// **Only `nil` means "no key stored."** A thrown ``SessionKeyStoreError``
    /// can be transient — notably `errSecInteractionNotAllowed`, which this
    /// store's `afterFirstUnlockThisDeviceOnly` accessibility produces when the
    /// device has not been unlocked since boot. A background relaunch after a
    /// reboot can hit exactly that, so treating any failure as "not paired"
    /// would wrongly force the user to re-pair. Check
    /// ``SessionKeyStoreError/isTransient`` and retry after unlock instead.
    ///
    /// - Throws: ``SessionKeyStoreError`` for any failure other than
    ///   `errSecItemNotFound`.
    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw SessionKeyStoreError.unexpectedItemData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw SessionKeyStoreError.keychainFailure(status: status)
        }
    }

    /// Removes the stored key. Deleting when nothing is stored is a no-op,
    /// so `delete()` is safe to call unconditionally (e.g. on sign-out).
    ///
    /// - Throws: ``SessionKeyStoreError/keychainFailure(status:)`` for any
    ///   failure other than `errSecItemNotFound`.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw SessionKeyStoreError.keychainFailure(status: status)
        }
    }

    /// The attributes identifying the one item this store owns.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
