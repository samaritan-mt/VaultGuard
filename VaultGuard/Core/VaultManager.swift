import Foundation
import UserNotifications
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "VaultManager")

// MARK: - VaultError

enum VaultError: Error, LocalizedError {
    case biometricFailed(BiometricAuth.AuthError)
    case passphraseGenerationFailed(Error)
    case keychainError(KeychainHelper.KeychainError)
    case hdiutilFailed(String)
    case apfsFailed(String)
    case integrityCheckFailed(String)
    case secureDeletionFailed(String)
    case folderNotFound
    case sparsebundleNotFound
    case apfsVolumeNotFound
    case alreadyMounted
    case notMounted
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .biometricFailed(let e): return e.localizedDescription
        case .passphraseGenerationFailed(let e): return "Passphrase generation failed: \(e)"
        case .keychainError(let e): return e.localizedDescription
        case .hdiutilFailed(let msg): return "hdiutil error: \(msg)"
        case .apfsFailed(let msg): return "APFS error: \(msg)"
        case .integrityCheckFailed(let msg): return "Integrity check failed: \(msg)"
        case .secureDeletionFailed(let msg): return "Secure deletion error: \(msg)"
        case .folderNotFound: return "The source folder could not be found."
        case .sparsebundleNotFound: return "The .vaultguard bundle could not be found."
        case .apfsVolumeNotFound: return "The encrypted APFS volume could not be found."
        case .alreadyMounted: return "The vault is already unlocked. Please lock it first."
        case .notMounted: return "The vault is not currently mounted. Please unlock it first."
        case .permissionDenied(let msg): return "Permission check failed: \(msg)"
        }
    }
}

// MARK: - VaultManager (Engine Router)

/**
 * Routes lock/unlock operations to the correct engine based on vault size.
 * 
 * Engine selection (configurable, defaults apply):
 *   < 10 GB  → SparsebundleEngine  (portable .vaultguard bundle, hdiutil)
 *  >= 10 GB  → APFSVolumeEngine    (encrypted APFS volume, diskutil, no 2× disk cost)
 * 
 * For a 30+ GB folder the APFS engine is strongly preferred: `mv` within the same
 * APFS container is a metadata-only operation — the entire folder moves in milliseconds.
 */
final class VaultManager {
    static let shared = VaultManager()
    private let queue = DispatchQueue(label: "com.vaultguard.vaultmanager", qos: .userInitiated)
    private let fm = FileManager.default

    /**
     * Set to `true` for the duration of any first-time lock (create+copy) operation.
     * Read only from `queue`; AutoLockDaemon queries it via `isFirstLockInProgress`.
     * HIGH-3 fix: prevents auto-lock from force-detaching a volume that is mid-copy.
     */
    private var firstLockInProgress = false

    /**
     * Returns `true` if a first-time vault creation is currently running.
     * Callers (e.g. AutoLockDaemon) should defer or skip re-lock operations while true.
     */
    var isFirstLockInProgress: Bool {
        var result = false
        queue.sync { result = self.firstLockInProgress }
        return result
    }

    private static let sparsebundleThresholdBytes = 10 * 1024 * 1024 * 1024

    private init() {
        checkForInProgressMarkers()
    }

    // MARK: - Engine selection

    func engineForFolder(_ url: URL) -> VaultEngineType {
        let size = SparsebundleEngine.directorySize(at: url)
        return size >= Self.sparsebundleThresholdBytes ? .apfsVolume : .sparsebundle
    }

    /**
     * Returns a human-readable size estimate string and the selected engine.
     */
    func lockEstimate(for folderPath: String) -> (sizeDescription: String, engine: VaultEngineType, seconds: Int) {
        let url = URL(fileURLWithPath: folderPath)
        let bytes = SparsebundleEngine.directorySize(at: url)
        let engine = engineForFolder(url)

        let gb = Double(bytes) / 1_073_741_824
        let sizeStr = gb < 1 ? String(format: "%.0f MB", Double(bytes) / 1_048_576)
                              : String(format: "%.1f GB", gb)

        let seconds: Int
        switch engine {
        case .apfsVolume: seconds = 3
        case .sparsebundle: seconds = max(5, bytes / (100 * 1024 * 1024))
        }

        return (sizeStr, engine, seconds)
    }

    // MARK: - Lock (first-time or re-lock)

    func lock(
        folderPath: String,
        progress: ((Double, String) -> Void)? = nil,
        completion: @escaping (Result<VaultEntry, VaultError>) -> Void
    ) {
        queue.async {
            let folderURL = URL(fileURLWithPath: folderPath)

            guard self.fm.fileExists(atPath: folderPath) else {
                DispatchQueue.main.async { completion(.failure(.folderNotFound)) }
                return
            }

            if let existing = VaultRegistry.shared.vault(forPath: folderPath) {
                self.reLock(vault: existing) { result in
                    DispatchQueue.main.async {
                        completion(result.map { existing })
                    }
                }
                return
            }

            progress?(0.01, "Checking permissions...")
            if let permissionErrorMsg = self.checkPermissions(for: folderURL) {
                DispatchQueue.main.async { completion(.failure(.permissionDenied(permissionErrorMsg))) }
                return
            }

            let engine = self.engineForFolder(folderURL)
            switch engine {
            case .sparsebundle:
                self.firstLockSparsebundle(folderURL: folderURL, progress: progress, completion: completion)
            case .apfsVolume:
                self.firstLockAPFS(folderURL: folderURL, progress: progress, completion: completion)
            }
        }
    }

    private func checkPermissions(for url: URL) -> String? {
        let currentUID = getuid()
        
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return "Cannot read folder contents. Please ensure you have read/write access."
        }
        
        var itemsToCheck = [url]
        for case let fileURL as URL in enumerator {
            itemsToCheck.append(fileURL)
        }
        
        for itemURL in itemsToCheck {
            guard let attrs = try? fm.attributesOfItem(atPath: itemURL.path) else { continue }
            
            if let isImmutable = attrs[.immutable] as? Bool, isImmutable {
                return "The item '\(itemURL.lastPathComponent)' is locked (immutable). Please unlock it in Finder (Get Info -> uncheck Locked) before encrypting."
            }
            if let owner = attrs[.ownerAccountID] as? NSNumber, owner.intValue != currentUID {
                return "You do not own '\(itemURL.lastPathComponent)'. Please verify your ownership and permissions before encrypting."
            }
        }
        return nil
    }

    /**
     * Re-lock an already-registered vault (unmount / APFS lock).
     */
    func lock(vault: VaultEntry, completion: @escaping (Result<Void, VaultError>) -> Void) {
        queue.async {
            self.reLock(vault: vault, completion: completion)
        }
    }

    // MARK: - Unlock

    // MARK: - Restore (decrypt vault → original folder, deletes vault permanently)

    /**
     * Decrypts a vault back into a regular folder.
     * Mounts the sparsebundle to a temp location, copies files to the original path,
     * unmounts, deletes the .vaultguard bundle, and removes the vault from the registry.
     */
    func restore(vault: VaultEntry, completion: @escaping (Result<Void, VaultError>) -> Void) {
        guard let bundlePath = vault.bundlePath else {
            completion(.failure(.sparsebundleNotFound)); return
        }
        guard fm.fileExists(atPath: bundlePath) else {
            completion(.failure(.sparsebundleNotFound)); return
        }
        guard vault.state == .locked else {
            completion(.failure(.alreadyMounted)); return
        }

        BiometricAuth.authenticate(reason: "Restore \(vault.name)") { [weak self] authResult in
            guard let self = self else { return }
            switch authResult {
            case .failure(let e):
                completion(.failure(.biometricFailed(e)))
            case .success(let context):
                switch KeychainHelper.retrieve(for: vault.id, context: context, reason: "Restore \(vault.name)") {
                case .failure(let e):
                    completion(.failure(.keychainError(e)))
                case .success(var passphrase):
                    self.queue.async {
                        let result = self.doRestore(vault: vault, bundlePath: bundlePath, passphrase: &passphrase)
                        KeychainHelper.secureZero(&passphrase)
                        DispatchQueue.main.async { completion(result) }
                    }
                }
            }
        }
    }

    private func doRestore(vault: VaultEntry, bundlePath: String, passphrase: inout [UInt8]) -> Result<Void, VaultError> {
        let tmpMount = "\(NSHomeDirectory())/Library/Application Support/com.vaultguard/mounts/restore-\(vault.id.uuidString)"
        SparsebundleEngine.createPrivateMountDir(at: tmpMount)

        let attachResult = SparsebundleEngine.hdiutilAttach(bundlePath: bundlePath, mountPoint: tmpMount, passphrase: passphrase)
        if case .failure(let e) = attachResult {
            try? fm.removeItem(atPath: tmpMount)
            return .failure(e)
        }

        let destURL = URL(fileURLWithPath: vault.originalFolderPath)
        let srcURL  = URL(fileURLWithPath: tmpMount)
        do {
            try mergeRestore(from: srcURL, into: destURL)
        } catch {
            _ = SparsebundleEngine.hdiutilDetach(mountPoint: tmpMount)
            try? fm.removeItem(atPath: tmpMount)
            return .failure(.hdiutilFailed("Restore copy failed: \(error.localizedDescription)"))
        }

        _ = SparsebundleEngine.hdiutilDetach(mountPoint: tmpMount)
        try? fm.removeItem(atPath: tmpMount)

        do {
            try fm.removeItem(atPath: bundlePath)
        } catch {
            os_log(.error, log: log, "doRestore: bundle deletion failed: %{public}@", error.localizedDescription)
            return .failure(.hdiutilFailed(
                "Files restored successfully, but the vault bundle could not be deleted. " +
                "You can remove it manually at: \(bundlePath)"
            ))
        }

        KeychainHelper.delete(for: vault.id)
        VaultRegistry.shared.remove(id: vault.id)

        postNotification(title: "Folder Restored", body: "\(vault.name) has been decrypted and restored.")
        os_log(.info, log: log, "Vault restored: %{public}@", vault.id.uuidString)
        return .success(())
    }

    func mergeRestore(from src: URL, into dest: URL) throws {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try? fm.setAttributes([.immutable: false], ofItemAtPath: dest.path)
        
        let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            let destItem = dest.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                try mergeRestore(from: item, into: destItem)
            } else if !fm.fileExists(atPath: destItem.path) {
                try fm.copyItem(at: item, to: destItem)
                try? fm.setAttributes([.immutable: false], ofItemAtPath: destItem.path)
            } else {
                try? fm.setAttributes([.immutable: false], ofItemAtPath: destItem.path)
            }
        }
    }

    // MARK: - Unlock (mount vault in place, keep .vaultguard)

    func unlock(vault: VaultEntry, completion: @escaping (Result<Void, VaultError>) -> Void) {
        guard vault.state == .locked else {
            completion(.failure(.alreadyMounted)); return
        }

        BiometricAuth.authenticate(reason: "Unlock \(vault.name)") { [weak self] authResult in
            guard let self = self else { return }
            switch authResult {
            case .failure(let e):
                completion(.failure(.biometricFailed(e)))
            case .success(let context):
                let keychainResult = KeychainHelper.retrieve(
                    for: vault.id,
                    context: context,
                    reason: "Unlock \(vault.name)"
                )
                switch keychainResult {
                case .failure(let e):
                    completion(.failure(.keychainError(e)))
                case .success(var passphrase):
                    self.queue.async {
                        let result: Result<Void, VaultError>
                        switch vault.engineType {
                        case .sparsebundle:
                            result = SparsebundleEngine.mount(vault: vault, passphrase: passphrase)
                        case .apfsVolume:
                            guard let uuid = vault.apfsVolumeUUID else {
                                KeychainHelper.secureZero(&passphrase)
                                DispatchQueue.main.async { completion(.failure(.apfsVolumeNotFound)) }
                                return
                            }
                            result = APFSVolumeEngine.unlockVolume(
                                uuid: uuid,
                                mountPoint: vault.originalFolderPath,
                                passphrase: passphrase
                            )
                        }
                        KeychainHelper.secureZero(&passphrase)

                        if case .success = result {
                            VaultRegistry.shared.update(id: vault.id, state: .unlocked)
                            self.postNotification(title: "Vault Unlocked", body: "\(vault.name) is now accessible.")
                        }
                        DispatchQueue.main.async { completion(result) }
                    }
                }
            }
        }
    }

    // MARK: - Private: First-time lock (sparsebundle)

    private func firstLockSparsebundle(
        folderURL: URL,
        progress: ((Double, String) -> Void)?,
        completion: @escaping (Result<VaultEntry, VaultError>) -> Void
    ) {
        firstLockInProgress = true
        defer { firstLockInProgress = false }

        let passphraseResult = KeychainHelper.generatePassphrase()
        guard case .success(var passphrase) = passphraseResult else {
            if case .failure(let e) = passphraseResult {
                DispatchQueue.main.async { completion(.failure(.passphraseGenerationFailed(e))) }
            }
            return
        }
        defer { KeychainHelper.secureZero(&passphrase) }

        let name = folderURL.deletingPathExtension().lastPathComponent
        let bundlePath = folderURL.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension("vaultguard").path
        let vaultID = UUID()

        let createResult = SparsebundleEngine.createVault(
            from: folderURL,
            bundlePath: bundlePath,
            vaultID: vaultID,
            passphrase: passphrase,
            progress: progress
        )

        if case .failure(let e) = createResult {
            DispatchQueue.main.async { completion(.failure(e)) }
            return
        }

        let storeResult = KeychainHelper.store(passphrase: passphrase, for: vaultID)
        if case .failure(let e) = storeResult {
            try? fm.removeItem(atPath: bundlePath)
            DispatchQueue.main.async { completion(.failure(.keychainError(e))) }
            return
        }

        let entry = VaultEntry(
            id: vaultID, name: name,
            bundlePath: bundlePath,
            originalFolderPath: folderURL.path
        )
        VaultRegistry.shared.register(entry)
        postNotification(title: "Vault Created", body: "\(name) is now encrypted.")
        os_log(.info, log: log, "Sparsebundle vault registered: %{public}@", vaultID.uuidString)
        DispatchQueue.main.async { completion(.success(entry)) }
    }

    // MARK: - Private: First-time lock (APFS volume)

    private func firstLockAPFS(
        folderURL: URL,
        progress: ((Double, String) -> Void)?,
        completion: @escaping (Result<VaultEntry, VaultError>) -> Void
    ) {
        let passphraseResult = KeychainHelper.generatePassphrase()
        guard case .success(var passphrase) = passphraseResult else {
            if case .failure(let e) = passphraseResult {
                DispatchQueue.main.async { completion(.failure(.passphraseGenerationFailed(e))) }
            }
            return
        }
        defer { KeychainHelper.secureZero(&passphrase) }

        let name = folderURL.deletingPathExtension().lastPathComponent
        let vaultID = UUID()

        firstLockInProgress = true
        defer { firstLockInProgress = false }

        let storeResult = KeychainHelper.store(passphrase: passphrase, for: vaultID)
        if case .failure(let e) = storeResult {
            DispatchQueue.main.async { completion(.failure(.keychainError(e))) }
            return
        }

        let createResult = APFSVolumeEngine.createVault(
            from: folderURL,
            vaultID: vaultID,
            vaultName: name,
            passphrase: passphrase,
            progress: progress
        )

        guard case .success(let volumeInfo) = createResult else {
            KeychainHelper.delete(for: vaultID)
            if case .failure(let e) = createResult {
                DispatchQueue.main.async { completion(.failure(e)) }
            }
            return
        }

        let entry = VaultEntry(
            id: vaultID, name: name,
            apfsContainerDevice: volumeInfo.deviceNode,
            apfsVolumeUUID: volumeInfo.uuid,
            originalFolderPath: folderURL.path
        )
        VaultRegistry.shared.register(entry)
        postNotification(title: "Vault Created", body: "\(name) is now encrypted.")
        os_log(.info, log: log, "APFS vault registered: %{public}@", vaultID.uuidString)
        DispatchQueue.main.async { completion(.success(entry)) }
    }

    // MARK: - Private: Re-lock

    private func reLock(vault: VaultEntry, completion: @escaping (Result<Void, VaultError>) -> Void) {
        let result: Result<Void, VaultError>
        switch vault.engineType {
        case .sparsebundle:
            result = SparsebundleEngine.unmount(vault: vault)
        case .apfsVolume:
            guard let uuid = vault.apfsVolumeUUID else {
                completion(.failure(.apfsVolumeNotFound)); return
            }
            result = APFSVolumeEngine.lockVolume(uuid: uuid)
        }

        if case .success = result {
            VaultRegistry.shared.update(id: vault.id, state: .locked)
            postNotification(title: "Vault Locked", body: "\(vault.name) has been locked.")
        }
        completion(result)
    }

    // MARK: - Crash recovery

    /**
     * On launch, look for any `.vaultguard.inprogress` marker files left by a previous interrupted lock.
     * Posts a notification so the UI can offer the user a Retry / Cancel dialog.
     */
    private func checkForInProgressMarkers() {
        queue.async {
            let parentDirs: [String] = Array(Set(
                VaultRegistry.shared.vaults.map { vault in
                    let path = vault.bundlePath ?? vault.originalFolderPath
                    return URL(fileURLWithPath: path).deletingLastPathComponent().path
                }
            ))
            guard !parentDirs.isEmpty else { return }

            for dir in parentDirs {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for name in contents {
                    guard name.hasSuffix(".vaultguard.inprogress") else { continue }
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    os_log(.error, log: log, "Found in-progress marker: %{public}@", name)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .vaultLockInterrupted,
                            object: nil,
                            userInfo: ["markerURL": url]
                        )
                    }
                }
            }
        }
    }

    // MARK: - Notifications

    private func postNotification(title: String, body: String) {
        let show = AppGroupDefaults.suite?.bool(forKey: "showNotifications") ?? true
        guard show else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - Additional notification names

extension Notification.Name {
    static let vaultLockInterrupted = Notification.Name("com.vaultguard.lockInterrupted")
}
