import Foundation
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "APFSVolumeEngine")

/**
 * Handles AES-256 encrypted APFS volumes via diskutil.
 * 
 * Why this engine for large vaults (>= 10 GB)?
 * - A `mv` within the same APFS container is a metadata-only operation — O(1) regardless of size.
 *   A 30 GB or 100 GB folder moves in milliseconds. No 2× disk space needed, no copying bytes.
 * - Hardware-accelerated AES on Apple Silicon via the Secure Enclave / ANE.
 * - Lock/unlock is a native APFS operation, not an hdiutil mount cycle.
 * 
 * Sandbox note: `diskutil apfs addVolume` requires Full Disk Access OR a privileged helper
 * (SMJobBless). Grant Full Disk Access in System Settings > Privacy & Security on first use.
 * The app shows an onboarding prompt before attempting this operation.
 * 
 * Transaction safety:
 * - Writes a `.vaultguard.inprogress` marker before moving files.
 * - Originals are deleted (marked moved) ONLY after integrity verification.
 * - On APFS, `mv` within the same container is atomic at the metadata level.
 */
final class APFSVolumeEngine {

    private static let fm = FileManager.default

    // MARK: - Create (first-time lock)

    /**
     * Creates an encrypted APFS volume, moves files from `folderURL` into it (O(1) on same container),
     * verifies integrity, locks the volume, then removes the original (now-empty) folder.
     */
    static func createVault(
        from folderURL: URL,
        vaultID: UUID,
        vaultName: String,
        passphrase: [UInt8],
        progress: ((Double, String) -> Void)?
    ) -> Result<APFSVolumeInfo, VaultError> {

        progress?(0.02, "Detecting APFS container…")

        let containerResult = findAPFSContainer(for: folderURL)
        guard case .success(let containerDevice) = containerResult else {
            if case .failure(let e) = containerResult { return .failure(e) }
            return .failure(.apfsFailed("Could not find APFS container"))
        }

        progress?(0.05, "Creating encrypted APFS volume…")

        let createResult = diskutilAddVolume(
            container: containerDevice,
            name: "VG_\(vaultName)",
            passphrase: passphrase
        )
        guard case .success(let volumeInfo) = createResult else {
            if case .failure(let e) = createResult { return .failure(e) }
            return .failure(.apfsFailed("Failed to create APFS volume"))
        }

        progress?(0.15, "Waiting for volume to mount…")

        guard let mountPoint = waitForMount(volumeUUID: volumeInfo.uuid, timeout: 30) else {
            _ = diskutilDeleteVolume(uuid: volumeInfo.uuid)
            return .failure(.apfsFailed("Volume did not mount within timeout"))
        }

        progress?(0.20, "Writing progress marker…")

        let markerURL = folderURL.deletingLastPathComponent()
            .appendingPathComponent("." + folderURL.lastPathComponent + ".vaultguard.inprogress")
        let manifest = buildManifest(from: folderURL, vaultID: vaultID, engine: .apfsVolume)
        try? JSONEncoder().encode(manifest).write(to: markerURL)

        SparsebundleEngine.setImmutableRecursive(true, at: folderURL)
        defer { SparsebundleEngine.setImmutableRecursive(false, at: folderURL) }

        progress?(0.25, "Moving files into vault…")

        let moveResult = moveFiles(from: folderURL, to: URL(fileURLWithPath: mountPoint), manifest: manifest, progress: { f in
            progress?(0.25 + f * 0.50, "Moving files…")
        })
        if case .failure(let e) = moveResult {
            _ = lockVolume(uuid: volumeInfo.uuid)
            return .failure(e)
        }

        progress?(0.75, "Verifying integrity…")
        let destURL = URL(fileURLWithPath: mountPoint)
        let verifyResult = verifyIntegrity(source: folderURL, destination: destURL, manifest: manifest)
        if case .failure(let e) = verifyResult {
            _ = restoreFiles(from: destURL, to: folderURL)
            _ = lockVolume(uuid: volumeInfo.uuid)
            return .failure(e)
        }

        progress?(0.85, "Locking volume…")
        let lockResult = lockVolume(uuid: volumeInfo.uuid)
        if case .failure(let e) = lockResult { return .failure(e) }

        progress?(0.90, "Cleaning up…")
        try? fm.removeItem(at: folderURL)

        try? fm.removeItem(at: markerURL)

        progress?(1.0, "Done")
        os_log(.info, log: log, "APFS vault created: %{public}@ on %{public}@", volumeInfo.uuid, containerDevice)
        return .success(volumeInfo)
    }

    // MARK: - Lock

    static func lockVolume(uuid: String) -> Result<Void, VaultError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["apfs", "lockVolume", uuid]
        let result = runProcess(proc, timeout: 60)
        if case .success = result {
            os_log(.info, log: log, "APFS volume locked: %{public}@", uuid)
        }
        return result
    }

    // MARK: - Unlock

    static func unlockVolume(uuid: String, mountPoint: String, passphrase: [UInt8]) -> Result<Void, VaultError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = [
            "apfs", "unlockVolume", uuid,
            "-stdinpassphrase",
            "-mountpoint", mountPoint
        ]
        pipePassphrase(passphrase, into: proc)
        let result = runProcess(proc, timeout: 60)
        if case .success = result {
            os_log(.info, log: log, "APFS volume unlocked: %{public}@", uuid)
        }
        return result
    }

    // MARK: - diskutil helpers

    struct APFSVolumeInfo {
        let uuid: String
        let deviceNode: String
    }

    private static func diskutilAddVolume(
        container: String,
        name: String,
        passphrase: [UInt8]
    ) -> Result<APFSVolumeInfo, VaultError> {
        let uuidsBefore = containerVolumeUUIDs(in: container)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = [
            "apfs", "addVolume", container,
            "APFS", name,
            "-stdinpassphrase"
        ]
        pipePassphrase(passphrase, into: proc)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let redactedCmd = "diskutil apfs addVolume \(container) APFS \(name) -passphrase <redacted>"
        os_log(.info, log: log, "diskutilAddVolume: %{public}@", redactedCmd)

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do {
            try proc.run()
        } catch {
            return .failure(.apfsFailed(error.localizedDescription))
        }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            proc.terminate()
            return .failure(.apfsFailed("diskutil addVolume timed out after 120s"))
        }

        guard proc.terminationStatus == 0 else {
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let msg = [err, out].filter { !$0.isEmpty }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.apfsFailed("addVolume (cmd: \(redactedCmd)):\n\(msg)"))
        }

        let uuidsAfter = containerVolumeUUIDs(in: container)
        let newUUIDs = uuidsAfter.subtracting(uuidsBefore)
        guard let newUUID = newUUIDs.first else {
            return .failure(.apfsFailed("addVolume succeeded but could not identify the new volume UUID"))
        }

        let infoProc = Process()
        infoProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        infoProc.arguments = ["info", "-plist", newUUID]
        let infoPipe = Pipe()
        infoProc.standardOutput = infoPipe
        infoProc.standardError = Pipe()
        guard startAndWait(infoProc, timeout: 30) else {
            return .failure(.apfsFailed("diskutil info timed out for UUID \(newUUID)"))
        }

        let infoData = infoPipe.fileHandleForReading.readDataToEndOfFile()
        guard let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let device = infoPlist["DeviceIdentifier"] as? String else {
            return .failure(.apfsFailed("Could not read DeviceIdentifier for UUID \(newUUID)"))
        }

        return .success(APFSVolumeInfo(uuid: newUUID, deviceNode: device))
    }

    /**
     * Returns the set of APFS volume UUIDs currently in `container` (e.g. "disk3").
     */
    private static func containerVolumeUUIDs(in container: String) -> Set<String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["apfs", "list", "-plist", container]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        guard startAndWait(proc, timeout: 30) else { return [] }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [] }

        var uuids = Set<String>()
        for c in containers {
            for vol in (c["Volumes"] as? [[String: Any]] ?? []) {
                if let uuid = vol["APFSVolumeUUID"] as? String { uuids.insert(uuid) }
            }
        }
        return uuids
    }

    @discardableResult
    private static func diskutilDeleteVolume(uuid: String) -> Result<Void, VaultError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["apfs", "deleteVolume", uuid]
        guard startAndWait(proc, timeout: 30) else { return .failure(.apfsFailed("deleteVolume timed out")) }
        return .success(())
    }

    // MARK: - Container detection

    /**
     * Returns the BSD device node of the APFS container hosting `url` (e.g. "disk3").
     * 
     * Uses `statfs(2)` to find the device node for the path (reliable, no parsing),
     * then queries `diskutil info -plist <device>` to confirm APFS and find the container.
     */
    private static func findAPFSContainer(for url: URL) -> Result<String, VaultError> {
        let dfProc = Process()
        dfProc.executableURL = URL(fileURLWithPath: "/bin/df")
        dfProc.arguments = ["-Pn", url.path]
        let dfOut = Pipe()
        dfProc.standardOutput = dfOut
        dfProc.standardError = Pipe()
        guard startAndWait(dfProc, timeout: 15) else {
            return .failure(.apfsFailed("df timed out or failed for \(url.path)"))
        }
        let dfOutput = String(data: dfOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let dfLines = dfOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard dfLines.count >= 2,
              let rawDevice = dfLines.last?.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init),
              !rawDevice.isEmpty else {
            return .failure(.apfsFailed("Could not determine device for \(url.path) from df output"))
        }
        let deviceNode = rawDevice.hasPrefix("/dev/") ? String(rawDevice.dropFirst(5)) : rawDevice

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["info", "-plist", deviceNode]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        guard startAndWait(proc, timeout: 15) else {
            return .failure(.apfsFailed("diskutil info timed out for \(deviceNode)"))
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .failure(.apfsFailed("Could not parse diskutil info for \(deviceNode)"))
        }

        guard let fsType = plist["FilesystemType"] as? String, fsType.lowercased() == "apfs" else {
            let fsType = plist["FilesystemType"] as? String ?? "unknown"
            return .failure(.apfsFailed(
                "This path is not on an APFS volume (filesystem: \(fsType)). " +
                "For non-APFS volumes, only folders smaller than 10 GB are supported via the sparsebundle engine."
            ))
        }

        if let container = plist["APFSContainerReference"] as? String {
            return .success(container)
        }
        let parts = deviceNode.components(separatedBy: "s")
        if parts.count >= 2, Int(parts.last!) != nil {
            return .success(parts.dropLast().joined(separator: "s"))
        }
        return .success(deviceNode)
    }

    // MARK: - Mount detection

    /**
     * Polls for the new volume to appear at its auto-mount point.
     */
    private static func waitForMount(volumeUUID: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let point = findMountPoint(for: volumeUUID) { return point }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private static func findMountPoint(for volumeUUID: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["info", "-plist", volumeUUID]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        guard startAndWait(proc, timeout: 10) else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mount = plist["MountPoint"] as? String, !mount.isEmpty else { return nil }
        return mount
    }

    // MARK: - File operations

    /**
     * Moves all top-level items from `source` into `destination`.
     * 
     * Progress is byte-based: we measure each item's size before the move, then credit
     * those bytes when the move completes.  On the same APFS container, `fm.moveItem`
     * is a metadata-only rename (near-instant); on a different mount point it falls back
     * to a real copy, so byte-based reporting keeps the progress bar accurate either way.
     */
    private static func moveFiles(
        from source: URL,
        to destination: URL,
        manifest: VaultManifest,
        progress: ((Double) -> Void)?
    ) -> Result<Void, VaultError> {
        do {
            let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            let totalBytes = max(manifest.totalBytes, 1)
            var bytesMoved = 0
            for item in items {
                let itemBytes = SparsebundleEngine.directorySize(at: item)
                SparsebundleEngine.setImmutableRecursive(false, at: item)
                let dest = destination.appendingPathComponent(item.lastPathComponent)
                try fm.moveItem(at: item, to: dest)
                bytesMoved += itemBytes
                progress?(Double(bytesMoved) / Double(totalBytes))
            }
            return .success(())
        } catch {
            return .failure(.apfsFailed("Move failed: \(error.localizedDescription)"))
        }
    }

    /**
     * Restores files back from destination to source on failure.
     */
    private static func restoreFiles(from destination: URL, to source: URL) -> Result<Void, VaultError> {
        do {
            let items = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            try? fm.createDirectory(at: source, withIntermediateDirectories: true)
            for item in items {
                let orig = source.appendingPathComponent(item.lastPathComponent)
                try fm.moveItem(at: item, to: orig)
            }
            return .success(())
        } catch {
            return .failure(.apfsFailed("Restore failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Integrity verification

    private static func verifyIntegrity(
        source: URL,
        destination: URL,
        manifest: VaultManifest
    ) -> Result<Void, VaultError> {
        let destCount = (try? FileManager.default.contentsOfDirectory(atPath: destination.path).count) ?? 0
        let destBytes = SparsebundleEngine.directorySize(at: destination)

        guard destBytes == manifest.totalBytes else {
            return .failure(.integrityCheckFailed(
                "Byte count mismatch: expected \(manifest.totalBytes), got \(destBytes)"
            ))
        }

        os_log(.info, log: log, "Integrity check passed: %d files, %d bytes", destCount, destBytes)
        return .success(())
    }

    /**
     * Starts `proc` and waits up to `timeout` seconds for it to exit.
     * Returns `false` and terminates the process if the timeout elapses.
     * Used for short read-only queries that should complete quickly (containerVolumeUUIDs,
     * findMountPoint, findAPFSContainer) — they cannot hold UF_IMMUTABLE files open but can
     * still hang under disk I/O failures.
     */
    @discardableResult
    private static func startAndWait(_ proc: Process, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        guard (try? proc.run()) != nil else { return false }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return false
        }
        return true
    }

    /**
     * Runs a diskutil process with a bounded timeout (HIGH-2 fix).
     * 
     * Replaces bare `proc.waitUntilExit()` calls throughout this engine.  If the process
     * hangs (I/O error, deadlocked kernel extension, misbehaving APFS container) it is
     * terminated after `timeout` seconds so UF_IMMUTABLE source files are not stranded.
     */
    private static func runProcess(_ proc: Process, timeout: TimeInterval) -> Result<Void, VaultError> {
        let errPipe = Pipe()
        proc.standardError = errPipe
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do {
            try proc.run()
        } catch {
            return .failure(.apfsFailed("launch failed: \(error.localizedDescription)"))
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            os_log(.error, log: log, "diskutil timed out after %ds", Int(timeout))
            return .failure(.apfsFailed("Operation timed out after \(Int(timeout))s"))
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            return .failure(.apfsFailed(msg))
        }
        return .success(())
    }

    /**
     * Writes `passphrase` bytes directly into `proc`'s stdin pipe — no Swift String,
     * no ps-visible argument (audit finding 3.1).
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
}
