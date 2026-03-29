import XCTest
@testable import VaultGuard

/// Integration tests that exercise the full lock/unlock cycle.
///
/// **Why these are skipped in normal test runs:**
/// The test host is VaultGuard.app which runs inside the App Sandbox.
/// Sandboxed processes cannot spawn `hdiutil` or `diskutil` as child processes —
/// the kernel returns "Device not configured" when the sandbox blocks the IPC channel
/// to DiskArbitration. These tests must be run manually outside the sandbox, e.g.:
///   1. Build the app (⌘B), run it from Finder (not from Xcode's Run button)
///   2. Use the Finder right-click menu to perform a real lock/unlock cycle
///   3. See docs/TESTING.md § 5 for the step-by-step manual test procedure
///
/// Set the environment variable VAULTGUARD_INTEGRATION_TESTS=1 to opt-in when
/// running against a non-sandboxed build (e.g. a release build with sandbox disabled
/// for local dev, or a privileged test runner).
final class VaultManagerIntegrationTests: XCTestCase {

    private var testFolderURL: URL!
    private let fm = FileManager.default

    /// Returns true if hdiutil is actually usable in the current process context.
    /// The sandbox blocks child process spawning — detect this before wasting time.
    private static var hdiutilAvailable: Bool = {
        // Check sandbox container env var — present when sandboxed
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return false
        }
        // Also probe with a quick no-op hdiutil call
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard let _ = try? proc.run() else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }()

    override func setUpWithError() throws {
        testFolderURL = fm.temporaryDirectory.appendingPathComponent("VGTest_\(UUID().uuidString)")
        try fm.createDirectory(at: testFolderURL, withIntermediateDirectories: true)
        try "TOP SECRET CONTENT".write(
            to: testFolderURL.appendingPathComponent("secret.txt"),
            atomically: true, encoding: .utf8
        )
    }

    /// Call at the top of any test that invokes hdiutil or requires Touch ID.
    private func requireHdiutilAndBiometrics() throws {
        guard Self.hdiutilAvailable else {
            throw XCTSkip("""
                Skipping: hdiutil is not available in this sandbox context.
                Run these tests manually — see docs/TESTING.md § 5 for instructions.
                """)
        }
        guard BiometricAuth.isAvailable() else {
            throw XCTSkip("Skipping: Touch ID not available on this machine.")
        }
    }

    override func tearDownWithError() throws {
        guard let url = testFolderURL else { return }
        let bundlePath = url.deletingPathExtension().appendingPathExtension("vaultguard").path
        try? fm.removeItem(atPath: bundlePath)
        try? fm.removeItem(at: url)
    }

    /// Full first-time lock: sparsebundle created, originals deleted.
    func testLockCreatesSparsebundle() throws {
        try requireHdiutilAndBiometrics()
        let exp = expectation(description: "lock completes")
        VaultManager.shared.lock(folderPath: testFolderURL.path) { result in
            switch result {
            case .success(let entry):
                let bundlePath = entry.bundlePath ?? ""
                XCTAssertFalse(bundlePath.isEmpty, "Sparsebundle path should not be empty")
                XCTAssertTrue(self.fm.fileExists(atPath: bundlePath),
                              "Sparsebundle should exist after locking")
                XCTAssertFalse(self.fm.fileExists(atPath: self.testFolderURL.path),
                               "Original folder should be gone after secure deletion")
            case .failure(let e):
                XCTFail("Lock failed: \(e)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
    }

    // MARK: - mergeRestore (no hdiutil required — pure file system)

    /// Source files not present in dest are copied.
    func testMergeRestoreCopiesMissingFiles() throws {
        let src  = fm.temporaryDirectory.appendingPathComponent("merge_src_\(UUID().uuidString)")
        let dest = fm.temporaryDirectory.appendingPathComponent("merge_dst_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dest) }

        try fm.createDirectory(at: src,  withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try "vault content".write(to: src.appendingPathComponent("new.txt"),
                                  atomically: true, encoding: .utf8)

        try VaultManager.shared.mergeRestore(from: src, into: dest)

        let restored = try String(contentsOf: dest.appendingPathComponent("new.txt"), encoding: .utf8)
        XCTAssertEqual(restored, "vault content")
    }

    /// Files that already exist in dest are NOT overwritten.
    func testMergeRestoreSkipsExistingFiles() throws {
        let src  = fm.temporaryDirectory.appendingPathComponent("merge_src_\(UUID().uuidString)")
        let dest = fm.temporaryDirectory.appendingPathComponent("merge_dst_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dest) }

        try fm.createDirectory(at: src,  withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try "vault version".write(to: src.appendingPathComponent("photo.jpg"),
                                  atomically: true, encoding: .utf8)
        try "existing version".write(to: dest.appendingPathComponent("photo.jpg"),
                                     atomically: true, encoding: .utf8)

        try VaultManager.shared.mergeRestore(from: src, into: dest)

        let content = try String(contentsOf: dest.appendingPathComponent("photo.jpg"), encoding: .utf8)
        XCTAssertEqual(content, "existing version",
                       "Existing file must not be overwritten by the vault copy")
    }

    /// Sub-directories are merged recursively rather than replaced.
    func testMergeRestoreMergesSubdirectories() throws {
        let src  = fm.temporaryDirectory.appendingPathComponent("merge_src_\(UUID().uuidString)")
        let dest = fm.temporaryDirectory.appendingPathComponent("merge_dst_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dest) }

        let srcSub  = src.appendingPathComponent("2023")
        let destSub = dest.appendingPathComponent("2023")
        try fm.createDirectory(at: srcSub,  withIntermediateDirectories: true)
        try fm.createDirectory(at: destSub, withIntermediateDirectories: true)

        try "vault only".write(to: srcSub.appendingPathComponent("vault.jpg"),
                               atomically: true, encoding: .utf8)
        try "disk only".write(to: destSub.appendingPathComponent("disk.jpg"),
                              atomically: true, encoding: .utf8)

        try VaultManager.shared.mergeRestore(from: src, into: dest)

        XCTAssertTrue(fm.fileExists(atPath: destSub.appendingPathComponent("vault.jpg").path),
                      "vault-only file must be restored into the sub-directory")
        XCTAssertTrue(fm.fileExists(atPath: destSub.appendingPathComponent("disk.jpg").path),
                      "pre-existing file in sub-directory must be preserved")
    }

    /// A dest that does not yet exist is created automatically.
    func testMergeRestoreCreatesDestIfAbsent() throws {
        let src  = fm.temporaryDirectory.appendingPathComponent("merge_src_\(UUID().uuidString)")
        let dest = fm.temporaryDirectory.appendingPathComponent("merge_dst_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dest) }

        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "data".write(to: src.appendingPathComponent("file.txt"),
                         atomically: true, encoding: .utf8)

        XCTAssertFalse(fm.fileExists(atPath: dest.path))
        try VaultManager.shared.mergeRestore(from: src, into: dest)
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("file.txt").path))
    }

    // MARK: - hdiutil-dependent tests

    /// Mounting with a wrong passphrase must fail.
    func testSparsebundleNotMountableWithoutPassphrase() throws {
        try requireHdiutilAndBiometrics()
        let bundlePath = testFolderURL.deletingPathExtension()
            .appendingPathExtension("vaultguard").path
        guard fm.fileExists(atPath: bundlePath) else {
            throw XCTSkip("No sparsebundle found — run testLockCreatesSparsebundle first.")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", bundlePath, "-stdinpass", "-nomount"]
        let pipe = Pipe()
        proc.standardInput = pipe
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        pipe.fileHandleForWriting.write("WRONGPASSPHRASE\n".data(using: .utf8)!)
        pipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()

        XCTAssertNotEqual(proc.terminationStatus, 0,
                          "hdiutil should refuse to mount with wrong passphrase")
    }
}
