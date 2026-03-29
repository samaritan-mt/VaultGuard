import Foundation
import Security
import LocalAuthentication

/// Manages per-vault passphrases in Keychain with Secure Enclave biometric ACL.
/// Passphrases are stored as raw [UInt8] and MUST be zeroed after use.
enum KeychainHelper {

    // MARK: - Error

    enum KeychainError: Error, LocalizedError {
        case unableToCreateAccessControl
        case saveFailed(OSStatus)
        case notFound
        case retrievalFailed(OSStatus)
        case deletionFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unableToCreateAccessControl: return "Unable to create Keychain access control flags."
            case .saveFailed(let s): return "Keychain save failed: \(s)"
            case .notFound: return "No passphrase found for this vault."
            case .retrievalFailed(let s): return "Keychain retrieval failed: \(s)"
            case .deletionFailed(let s): return "Keychain deletion failed: \(s)"
            }
        }
    }

    // MARK: - Store

    /// Stores a passphrase for the given vault UUID.
    /// - Parameters:
    ///   - passphrase: Raw passphrase bytes. Caller must zero after this call.
    ///   - vaultID: The vault's UUID (used as keychain key).
    static func store(passphrase: [UInt8], for vaultID: UUID) -> Result<Void, KeychainError> {
        var errorRef: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as CFTypeRef,
            [.biometryCurrentSet],
            &errorRef
        ) else {
            return .failure(.unableToCreateAccessControl)
        }

        let key = keychainKey(for: vaultID)
        let data = Data(passphrase)

        // Delete any existing entry first to avoid duplicates.
        deleteItem(key: key)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.vaultguard",
            kSecValueData: data,
            kSecAttrAccessControl: access,
            kSecUseDataProtectionKeychain: true
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            return .failure(.saveFailed(status))
        }
        return .success(())
    }

    // MARK: - Retrieve

    /// Retrieves the passphrase bytes for a vault, prompting Touch ID via the provided LAContext.
    /// The caller is responsible for zeroing the returned buffer after use.
    static func retrieve(for vaultID: UUID, context: LAContext, reason: String) -> Result<[UInt8], KeychainError> {
        let key = keychainKey(for: vaultID)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.vaultguard",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
            kSecUseOperationPrompt: reason
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failure(.retrievalFailed(errSecItemNotFound)) }
            var bytes = [UInt8](data)
            return .success(bytes)
        case errSecItemNotFound:
            return .failure(.notFound)
        default:
            return .failure(.retrievalFailed(status))
        }
    }

    // MARK: - Delete

    @discardableResult
    static func delete(for vaultID: UUID) -> Result<Void, KeychainError> {
        let key = keychainKey(for: vaultID)
        return deleteItem(key: key)
    }

    // MARK: - Private helpers

    @discardableResult
    private static func deleteItem(key: String) -> Result<Void, KeychainError> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.vaultguard"
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return .success(())
        }
        return .failure(.deletionFailed(status))
    }

    private static func keychainKey(for vaultID: UUID) -> String {
        "vault-\(vaultID.uuidString)"
    }
}

// MARK: - Passphrase generation

extension KeychainHelper {
    /// Generates a 64-character cryptographically random passphrase using SecRandomCopyBytes.
    /// Returns raw bytes that the caller must zero after use.
    static func generatePassphrase() -> Result<[UInt8], Error> {
        // 63 bytes from secure random pool, then hex-encode → 126 hex chars.
        // 126 chars keeps us under diskutil's 127-character passphrase limit
        // while retaining 504 bits of entropy — far more than sufficient.
        var rawBytes = [UInt8](repeating: 0, count: 63)
        let status = SecRandomCopyBytes(kSecRandomDefault, rawBytes.count, &rawBytes)
        guard status == errSecSuccess else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        // Hex-encode so the passphrase is printable ASCII (hdiutil stdinpass expects string)
        var hexBytes = [UInt8]()
        hexBytes.reserveCapacity(128)
        for byte in rawBytes {
            let hi = hexChar(byte >> 4)
            let lo = hexChar(byte & 0x0F)
            hexBytes.append(hi)
            hexBytes.append(lo)
        }
        // Zero the raw bytes before returning
        for i in rawBytes.indices { rawBytes[i] = 0 }
        return .success(hexBytes)
    }

    private static func hexChar(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? (0x30 + nibble) : (0x61 + nibble - 10) // '0'..'9' or 'a'..'f'
    }
}

// MARK: - Secure zero utility

extension KeychainHelper {
    /// Zeros a mutable byte buffer in a way the compiler cannot optimise away.
    static func secureZero(_ buffer: inout [UInt8]) {
        memset_s(&buffer, buffer.count, 0, buffer.count)
    }
}