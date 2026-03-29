import XCTest
@testable import VaultGuard

/// These tests hit the real Keychain and require Touch ID or device passcode at runtime.
/// On CI (no secure enclave), biometric tests will be skipped.
final class KeychainHelperTests: XCTestCase {

    func testPassphraseGenerationLength() {
        let result = KeychainHelper.generatePassphrase()
        switch result {
        case .success(let bytes):
            XCTAssertEqual(bytes.count, 128, "Hex-encoded passphrase should be 128 bytes (64 raw → 128 hex)")
        case .failure(let e):
            XCTFail("Passphrase generation failed: \(e)")
        }
    }

    func testPassphraseIsHexASCII() {
        guard case .success(let bytes) = KeychainHelper.generatePassphrase() else {
            XCTFail(); return
        }
        let valid = CharacterSet(charactersIn: "0123456789abcdef")
        let str = String(bytes: bytes, encoding: .ascii) ?? ""
        XCTAssertTrue(str.unicodeScalars.allSatisfy { valid.contains($0) })
    }

    func testSecureZeroErasesBuffer() {
        var buf: [UInt8] = [1, 2, 3, 4, 5]
        KeychainHelper.secureZero(&buf)
        XCTAssertTrue(buf.allSatisfy { $0 == 0 })
    }

    func testDeleteNonExistentIsNoop() {
        let id = UUID()
        let result = KeychainHelper.delete(for: id)
        switch result {
        case .success: break  // expected
        case .failure(let e): XCTFail("Unexpected error: \(e)")
        }
    }
}
