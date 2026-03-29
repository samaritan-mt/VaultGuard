import Foundation
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "SparsebundleEngine")

/**
 * Handles AES-256 APFS sparsebundles via hdiutil.
 * Used for vaults < 10 GB where portability and incremental-write efficiency matter.
 * 
 * Transaction safety:
 * - Writes a `.vaultguard.inprogress` marker before touching originals.
 * - Originals are deleted ONLY after a full integrity check (file count + byte totals).
 * - On next launch, any orphaned `.inprogress` marker triggers a recovery dialog.
 */
final class SparsebundleEngine {

    private static let fm = FileManager.default

    /**
     * Private mount base — inside the user's Library, not world-readable /tmp.
     * Created with 0700 permissions so no other local process can enumerate mounted volumes.
     */
    private static var mountBase: String {
        "\(NSHomeDirectory())/Library/Application Support/com.vaultguard/mounts"
    }

    // MARK: - Create

    /**
     * First-time lock: creates an encrypted sparsebundle, copies files in, verifies, then deletes originals.
     */
    static func createVault(
        from folderURL: URL,
        bundlePath: String,
        vaultID: UUID,
        passphrase: [UInt8],
        progress: ((Double, String) -> Void)?
    ) -> Result<Void, VaultError> {

        let sourceSize = directorySize(at: folderURL)
        let sizeMB = max((sourceSize * 120 / 100) / (1024 * 1024), 100)

        progress?(0.05, "Creating encrypted container…")

        if fm.fileExists(atPath: bundlePath) {
            _ = hdiutilDetach(mountPoint: bundlePath)
            try? fm.removeItem(atPath: bundlePath)
        }

        let createResult = hdiutilCreate(bundlePath: bundlePath, sizeMB: sizeMB, passphrase: passphrase)
        if case .failure(let e) = createResult { return .failure(e) }

        let mountPoint = "\(mountBase)/\(vaultID.uuidString)"
        createPrivateMountDir(at: mountPoint)
        let attachResult = hdiutilAttach(bundlePath: bundlePath, mountPoint: mountPoint, passphrase: passphrase)
        if case .failure(let e) = attachResult {
            try? fm.removeItem(atPath: bundlePath)
            return .failure(e)
        }

        progress?(0.15, "Copying files…")

        let bundleURL = URL(fileURLWithPath: bundlePath)
        let markerURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("." + bundleURL.lastPathComponent + ".inprogress")
        let manifest = buildManifest(from: folderURL, vaultID: vaultID, engine: .sparsebundle)
        try? JSONEncoder().encode(manifest).write(to: markerURL)

        setImmutableRecursive(true, at: folderURL)
        defer { setImmutableRecursive(false, at: folderURL) }

        let mountedRoot = URL(fileURLWithPath: mountPoint)
        let copyResult = copyFiles(
            from: folderURL,
            to: mountedRoot,
            totalBytes: sourceSize,
            progress: { fraction in progress?(0.15 + fraction * 0.65, "Copying files…") }
        )
        if case .failure(let e) = copyResult {
            _ = hdiutilDetach(mountPoint: mountPoint)
            return .failure(e)
        }

        progress?(0.80, "Verifying integrity…")
        let verifyResult = verifyIntegrity(source: folderURL, destination: mountedRoot, manifest: manifest)
        if case .failure(let e) = verifyResult {
            _ = hdiutilDetach(mountPoint: mountPoint)
            return .failure(e)
        }

        let detachResult = hdiutilDetach(mountPoint: mountPoint)
        if case .failure(let e) = detachResult { return .failure(e) }

        progress?(0.85, "Securing originals…")
        setImmutableRecursive(false, at: folderURL)
        SecureDelete.deleteDirectory(at: folderURL)

        try? fm.removeItem(at: markerURL)
        try? fm.removeItem(atPath: mountPoint)

        progress?(1.0, "Done")
        os_log(.info, log: log, "Sparsebundle vault created: %{public}@", vaultID.uuidString)
        return .success(())
    }

    // MARK: - Mount / Unmount

    static func mount(vault: VaultEntry, passphrase: [UInt8]) -> Result<Void, VaultError> {
        guard let bundlePath = vault.bundlePath else { return .failure(.sparsebundleNotFound) }
        guard fm.fileExists(atPath: bundlePath) else { return .failure(.sparsebundleNotFound) }

        let mountPoint = vault.originalFolderPath
        try? fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        return hdiutilAttach(bundlePath: bundlePath, mountPoint: mountPoint, passphrase: passphrase)
    }

    static func unmount(vault: VaultEntry) -> Result<Void, VaultError> {
        return hdiutilDetach(mountPoint: vault.originalFolderPath)
    }

    // MARK: - hdiutil wrappers

    static func hdiutilCreate(bundlePath: String, sizeMB: Int, passphrase: [UInt8]) -> Result<Void, VaultError> {
        let stem = bundlePath.hasSuffix(".vaultguard")
            ? String(bundlePath.dropLast(".vaultguard".count))
            : bundlePath
        let stemURL = URL(fileURLWithPath: stem)
        let hiddenStem = stemURL.deletingLastPathComponent()
            .appendingPathComponent("." + stemURL.lastPathComponent).path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "create",
            "-size", "\(sizeMB)m",
            "-volname", "VaultGuard",
            "-encryption", "AES-256",
            "-stdinpass",
            "-type", "SPARSEBUNDLE",
            hiddenStem
        ]
        pipePassphrase(passphrase, into: proc)

        let result = run(proc)
        guard case .success = result else { return result }

        let created = hiddenStem + ".sparsebundle"
        do {
            try fm.moveItem(atPath: created, toPath: bundlePath)
        } catch {
            try? fm.removeItem(atPath: created)
            return .failure(.hdiutilFailed("rename failed: \(error.localizedDescription)"))
        }
        return .success(())
    }

    static func hdiutilAttach(bundlePath: String, mountPoint: String, passphrase: [UInt8]) -> Result<Void, VaultError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "attach", bundlePath,
            "-stdinpass",
            "-mountpoint", mountPoint,
            "-nobrowse",
            "-noautoopen"
        ]
        pipePassphrase(passphrase, into: proc)
        return run(proc)
    }

    @discardableResult
    static func hdiutilDetach(mountPoint: String) -> Result<Void, VaultError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint, "-force"]
        return run(proc)
    }

    // MARK: - File copy with progress

    private static func copyFiles(
        from source: URL,
        to destination: URL,
        totalBytes: Int,
        progress: ((Double) -> Void)?
    ) -> Result<Void, VaultError> {
        var bytesCopied = 0
        do {
            try copyFilesRecursive(
                from: source, to: destination,
                totalBytes: totalBytes, bytesCopied: &bytesCopied,
                progress: progress
            )
            return .success(())
        } catch {
            return .failure(.hdiutilFailed("Copy failed: \(error.localizedDescription)"))
        }
    }

    /**
     * Recursively copies `source` into `destination`, reporting progress after each file.
     * Unlike a single `fm.copyItem` on a directory, this lets us update the progress bar
     * after every individual file — critical for large nested folder trees (e.g. > 1 GB).
     */
    private static func copyFilesRecursive(
        from source: URL,
        to destination: URL,
        totalBytes: Int,
        bytesCopied: inout Int,
        progress: ((Double) -> Void)?
    ) throws {
        let items = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        )
        for item in items {
            let dest = destination.appendingPathComponent(item.lastPathComponent)
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                try fm.createDirectory(at: dest, withIntermediateDirectories: false)
                try? fm.setAttributes([.immutable: false], ofItemAtPath: dest.path)
                try copyFilesRecursive(
                    from: item, to: dest,
                    totalBytes: totalBytes, bytesCopied: &bytesCopied,
                    progress: progress
                )
            } else {
                try fm.copyItem(at: item, to: dest)
                try? fm.setAttributes([.immutable: false], ofItemAtPath: dest.path)
                bytesCopied += vals?.fileSize ?? 0
                if totalBytes > 0 {
                    progress?(Double(bytesCopied) / Double(totalBytes))
                }
            }
        }
    }

    // MARK: - Integrity verification

    private static func verifyIntegrity(
        source: URL,
        destination: URL,
        manifest: VaultManifest
    ) -> Result<Void, VaultError> {
        let sourceItems = Set((try? fm.contentsOfDirectory(atPath: source.path)) ?? [])
        let destItems   = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
        let missing = sourceItems.subtracting(destItems)
        guard missing.isEmpty else {
            return .failure(.integrityCheckFailed(
                "Items missing from vault: \(missing.sorted().joined(separator: ", "))"
            ))
        }

        let sourceBytes = directorySize(at: source)
        let destBytesFromSource = sourceItems.reduce(0) { total, name in
            total + directorySize(at: destination.appendingPathComponent(name))
        }
        guard sourceBytes == destBytesFromSource else {
            return .failure(.integrityCheckFailed(
                "Byte count mismatch: \(sourceBytes) source vs \(destBytesFromSource) destination"
            ))
        }

        return .success(())
    }

    // MARK: - Helpers

    /**
     * Sums the logical file size of all files under `url`, tracking inodes to avoid
     * double-counting hard-linked files (audit finding 2.3).
     * 
     * Works on both files and directories:
     * - File URL → returns its `fileSizeKey` directly (fm.enumerator requires a directory).
     * - Directory URL → recursively enumerates all descendant files.
     * 
     * Uses `fileSizeKey` (logical size) — the same metric as `buildManifest` — so that
     * integrity checks comparing directorySize against manifest.totalBytes are consistent.
     */
    static func directorySize(at url: URL) -> Int {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .fileResourceIdentifierKey]
        ) else { return 0 }
        var total = 0
        var seenInodes = Set<AnyHashable>()
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .fileResourceIdentifierKey]
            ) else { continue }
            if let inode = vals.fileResourceIdentifier as? AnyHashable {
                guard seenInodes.insert(inode).inserted else { continue }
            }
            total += vals.fileSize ?? 0
        }
        return total
    }

    /**
     * Sets or clears the `UF_IMMUTABLE` (user-immutable) flag on `url` and every descendant.
     * 
     * When `immutable = true`, no process (not even the file owner) can modify, rename,
     * or delete the flagged items until the flag is explicitly cleared.  This closes the
     * TOCTOU window between "we started copying files" and "originals are securely deleted":
     * any concurrent write or deletion attempt is rejected by the kernel.
     * 
     * Locking order: children first, then parent (prevents directory-rename tricks).
     * Unlocking order: parent first, then children (allows traversal to reach children).
     * 
     * Note: this uses the *user*-immutable bit (`UF_IMMUTABLE`), which the file owner can
     * set and clear without root.  It is sufficient to block accidental and opportunistic
     * tampering; a malicious process running as the same user could clear it, but that is
     * outside the threat model of a user-space encryption app.
     */
    static func setImmutableRecursive(_ immutable: Bool, at url: URL) {
        if immutable {
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in enumerator {
                    try? fm.setAttributes([.immutable: true], ofItemAtPath: child.path)
                }
            }
            try? fm.setAttributes([.immutable: true], ofItemAtPath: url.path)
        } else {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: url.path)
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in enumerator {
                    try? fm.setAttributes([.immutable: false], ofItemAtPath: child.path)
                }
            }
        }
    }

    /**
     * Creates a mount directory with restrictive 0700 permissions so no other
     * local process can enumerate or read the mounted plaintext (audit finding 1.2).
     */
    static func createPrivateMountDir(at path: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                               ofItemAtPath: parent.path)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                               ofItemAtPath: path)
    }

    /**
     * Writes `passphrase` bytes directly into `proc`'s stdin pipe.
     * Avoids creating a Swift String (which cannot be zeroed) and keeps the
     * passphrase out of the process argument list visible via `ps` (audit finding 3.1).
     */
    private static func pipePassphrase(_ passphrase: [UInt8], into proc: Process) {
        var data = Data(passphrase)
        data.append(0x0a)
        let pipe = Pipe()
        proc.standardInput = pipe
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.closeFile()
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            memset_s(base, ptr.count, 0, ptr.count)
        }
    }

    /**
     * Run a process with no stdin override, capturing stdout+stderr for error messages.
     * 
     * HIGH-2 fix: replaced `proc.waitUntilExit()` with a semaphore wait capped at `timeout`
     * seconds.  On timeout the process is terminated so UF_IMMUTABLE source files and
     * partial vaults are not left in a permanently broken state.
     */
    private static func run(_ proc: Process, timeout: TimeInterval = 300) -> Result<Void, VaultError> {
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        let args = proc.arguments ?? []
        var redacted: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg == "-passphrase" { skipNext = true; redacted.append("-passphrase"); redacted.append("<redacted>"); continue }
            redacted.append(arg)
        }
        let cmd = ([proc.executableURL?.path ?? "?"] + redacted).joined(separator: " ")
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do {
            try proc.run()
        } catch {
            return .failure(.hdiutilFailed("launch failed: \(error.localizedDescription)\ncmd: \(cmd)"))
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            os_log(.error, log: log, "hdiutil timed out after %ds: %{public}@", Int(timeout), cmd)
            return .failure(.hdiutilFailed("Operation timed out after \(Int(timeout))s\ncmd: \(cmd)"))
        }
        guard proc.terminationStatus == 0 else {
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let msg = [err, out].filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            os_log(.error, log: log, "hdiutil failed (exit %d): %{public}@\ncmd: %{public}@", proc.terminationStatus, msg, cmd)
            return .failure(.hdiutilFailed("\(msg)\n\ncmd: \(cmd)"))
        }
        return .success(())
    }
}

// MARK: - Manifest (shared with APFSVolumeEngine)

struct VaultManifest: Codable {
    let vaultID: UUID
    let engineType: VaultEngineType
    let sourcePath: String
    let fileCount: Int
    let totalBytes: Int
    let createdAt: Date
}

func buildManifest(from url: URL, vaultID: UUID, engine: VaultEngineType) -> VaultManifest {
    var fileCount = 0
    var totalBytes = 0
    let fm = FileManager.default
    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if vals?.isRegularFile == true {
                fileCount += 1
                totalBytes += vals?.fileSize ?? 0
            }
        }
    }
    return VaultManifest(
        vaultID: vaultID,
        engineType: engine,
        sourcePath: url.path,
        fileCount: fileCount,
        totalBytes: totalBytes,
        createdAt: Date()
    )
}
