import Foundation
import AppKit
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "IPC")

// MARK: - IPCService (main app side — NOT compiled into the Finder extension)

/**
 * Watches the shared App Group container for JSON command files dropped by the
 * Finder extension.  Uses a kqueue DispatchSource on the directory — no cross-process
 * notifications, works unconditionally between sandboxed App Group members.
 */
final class IPCService {
    static let shared = IPCService()
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var progressController: VaultProgressWindowController?

    private init() {}

    // MARK: - Lifecycle

    func startListening() {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: IPCMessage.appGroupSuite) else {
            NSLog("VaultGuard: IPCService — cannot resolve App Group container, IPC disabled")
            return
        }

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("VaultGuard: IPCService — open(%@) failed: %d", dir.path, errno)
            return
        }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.processCommandFiles(in: dir)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        dirSource = source

        NSLog("VaultGuard: IPCService started, watching %@", dir.path)

        processCommandFiles(in: dir)
    }

    func stopListening() {
        dirSource?.cancel()
        dirSource = nil
    }

    // MARK: - Command processing

    private func processCommandFiles(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let commandFiles = entries.filter {
            $0.lastPathComponent.hasPrefix(IPCMessage.commandFilePrefix) &&
            $0.pathExtension == "json"
        }
        guard !commandFiles.isEmpty else { return }

        NSLog("VaultGuard: IPCService — processing %d command file(s)", commandFiles.count)

        for file in commandFiles {
            guard let data = try? Data(contentsOf: file),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = cmd["action"] as? String else {
                if (try? fm.removeItem(at: file)) == nil {
                    os_log(.error, log: log, "IPCService: failed to delete malformed command file")
                }
                continue
            }

            let paths: [String]
            if let multiPaths = cmd["paths"] as? [String], !multiPaths.isEmpty {
                paths = multiPaths
            } else if let singlePath = cmd["path"] as? String {
                paths = [singlePath]
            } else {
                if (try? fm.removeItem(at: file)) == nil {
                    os_log(.error, log: log, "IPCService: failed to delete malformed command file")
                }
                continue
            }

            if (try? fm.removeItem(at: file)) == nil {
                os_log(.error, log: log, "IPCService: failed to delete command file — may replay on restart")
            }

            let knownSource = "com.vaultguard.finder"
            let source = cmd["source"] as? String ?? "unknown"
            let expectedToken = UserDefaults(suiteName: IPCMessage.appGroupSuite)?.string(forKey: "ipc_token") ?? "n/a"
            let receivedToken = cmd["token"] as? String ?? ""
            let fromKnownExtension = (source == knownSource) && (receivedToken == expectedToken && !expectedToken.isEmpty)

            NSLog("VaultGuard: IPCService executing action=%@ paths=%d source=%@", action, paths.count, source)
            os_log(.info, log: log, "IPC command: %{public}@ paths=%d source=%{public}@", action, paths.count, source)

            switch action {
            case "lock":
                if paths.count == 1 {
                    handleLock(path: paths[0], fromKnownExtension: fromKnownExtension)
                } else {
                    handleLockMultiple(paths: paths, fromKnownExtension: fromKnownExtension)
                }
            case "unlock":
                if let path = paths.first { handleUnlock(path: path) }
            default:
                NSLog("VaultGuard: IPCService unknown action: %@", action)
            }
        }
    }

    // MARK: - Handlers

    private func handleLock(path: String, fromKnownExtension: Bool) {
        let resolvedPath: String
        do {
            resolvedPath = try wrapFileIfNeeded(path: path)
        } catch {
            DispatchQueue.main.async { self.showError("Cannot Lock", detail: error.localizedDescription, path: path) }
            return
        }

        let home = "/Users/\(NSUserName())"

        if resolvedPath == home || !resolvedPath.hasPrefix(home + "/") {
            let name = URL(fileURLWithPath: resolvedPath).lastPathComponent
            let detail = resolvedPath == home
                ? "Encrypting your entire Home folder would make your account inaccessible."
                : "VaultGuard only locks folders inside your Home directory (\(home))."
            DispatchQueue.main.async { self.showError("Cannot Lock \"\(name)\"", detail: detail, path: resolvedPath) }
            return
        }

        let name = URL(fileURLWithPath: resolvedPath).lastPathComponent

        let parent = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path
        if parent == home {
            let systemFolders: Set<String> = [
                "Desktop", "Documents", "Downloads", "Movies", "Music",
                "Pictures", "Library", "Public", "Applications"
            ]
            if systemFolders.contains(name) {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Lock \"\(name)\"?"
                    alert.informativeText = "\"\(name)\" is a standard macOS system folder. Encrypting it may break apps that rely on it.\n\nAre you sure?"
                    alert.addButton(withTitle: "Lock Anyway")
                    alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    self.performLock(path: resolvedPath)
                }
                return
            }
        }

        let infoText = fromKnownExtension
            ? "VaultGuard will encrypt this folder. You'll need Touch ID to access it."
            : "A lock request was received outside the Finder extension. Proceed only if you initiated this action."
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = fromKnownExtension ? .informational : .warning
            alert.messageText = "Lock \"\(name)\"?"
            alert.informativeText = infoText
            alert.addButton(withTitle: "Lock")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.performLock(path: resolvedPath)
        }
    }

    /**
     * Bundles multiple paths into a single timestamped folder inside the common parent,
     * then triggers a normal single-folder lock on that bundle folder.
     * 
     * All items must share the same parent directory (Finder multi-select is always within
     * the same folder).  Any individual files are moved as-is; the engines handle them.
     */
    private func handleLockMultiple(paths: [String], fromKnownExtension: Bool) {
        guard !paths.isEmpty else { return }

        let fm = FileManager.default
        let parent = URL(fileURLWithPath: paths[0]).deletingLastPathComponent()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var bundleName = "VaultGuard Bundle \(stamp)"
        var bundleURL = parent.appendingPathComponent(bundleName)
        var counter = 1
        while fm.fileExists(atPath: bundleURL.path) {
            bundleName = "VaultGuard Bundle \(stamp) \(counter)"
            bundleURL = parent.appendingPathComponent(bundleName)
            counter += 1
        }

        do {
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: false)
        } catch {
            DispatchQueue.main.async {
                self.showError("Cannot Lock Items",
                               detail: "Could not create bundle folder: \(error.localizedDescription)",
                               path: parent.path)
            }
            return
        }

        for path in paths {
            let src = URL(fileURLWithPath: path)
            let dst = bundleURL.appendingPathComponent(src.lastPathComponent)
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                if let moved = try? fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
                    for item in moved {
                        try? fm.moveItem(at: item, to: parent.appendingPathComponent(item.lastPathComponent))
                    }
                }
                try? fm.removeItem(at: bundleURL)
                DispatchQueue.main.async {
                    self.showError("Cannot Lock Items",
                                   detail: "Could not bundle \"\(src.lastPathComponent)\": \(error.localizedDescription)",
                                   path: path)
                }
                return
            }
        }

        NSLog("VaultGuard: IPCService bundled %d items into \"%@\"", paths.count, bundleName)
        handleLock(path: bundleURL.path, fromKnownExtension: fromKnownExtension)
    }

    /**
     * If `path` is a regular file, creates a sibling folder named after the file (minus
     * extension) and moves the file into it, returning the folder path.
     * If `path` is already a directory, returns it unchanged.
     * Handles name collisions with a counter suffix.
     */
    private func wrapFileIfNeeded(path: String) throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw NSError(domain: "com.vaultguard", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Item not found at path."])
        }
        guard !isDir.boolValue else { return path }

        let fileURL  = URL(fileURLWithPath: path)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        var folderURL = fileURL.deletingLastPathComponent().appendingPathComponent(baseName)

        var counter = 1
        while fm.fileExists(atPath: folderURL.path) {
            folderURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName) \(counter)")
            counter += 1
        }

        try fm.createDirectory(at: folderURL, withIntermediateDirectories: false)
        try fm.moveItem(at: fileURL,
                        to: folderURL.appendingPathComponent(fileURL.lastPathComponent))
        NSLog("VaultGuard: wrapped file \"%@\" into folder \"%@\"",
              fileURL.lastPathComponent, folderURL.lastPathComponent)
        return folderURL.path
    }

    private func performLock(path: String) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent

        if let spaceError = diskSpaceError(for: url) {
            showError("Not Enough Space", detail: spaceError, path: path)
            return
        }

        guard progressController == nil else {
            NSLog("VaultGuard: IPCService — ignoring duplicate lock request while operation in progress")
            return
        }

        let progress = VaultProgressWindowController(title: "Locking \"\(name)\"…")
        progress.show()
        progressController = progress

        VaultManager.shared.lock(folderPath: path, progress: { fraction, status in
            progress.update(fraction: fraction, status: status)
        }) { result in
            progress.dismiss()
            self.progressController = nil
            switch result {
            case .success(let entry):
                NSLog("VaultGuard: lock succeeded — vault=%@", entry.name)
            case .failure(let e):
                os_log(.error, log: log, "lock failed: %{public}@", e.localizedDescription)
                NSLog("VaultGuard: lock FAILED — %@", e.localizedDescription)
                self.showError("Lock Failed", detail: e.localizedDescription, path: path)
            }
        }
    }

    // MARK: - Disk space pre-flight

    private func diskSpaceError(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let freeBytes = attrs[.systemFreeSize] as? Int else { return nil }

        let engine = VaultManager.shared.engineForFolder(url)
        switch engine {
        case .sparsebundle:
            let sourceBytes = SparsebundleEngine.directorySize(at: url)
            let needed = sourceBytes * 12 / 10
            if freeBytes < needed {
                return String(format: "%.1f GB needed, %.1f GB available. Free up space before locking.",
                              Double(needed) / 1_073_741_824, Double(freeBytes) / 1_073_741_824)
            }
        case .apfsVolume:
            let minBuffer = 500 * 1024 * 1024
            if freeBytes < minBuffer {
                return String(format: "Less than 500 MB free (%.0f MB available). Free up space before locking.",
                              Double(freeBytes) / 1_048_576)
            }
        }
        return nil
    }

    private func handleUnlock(path: String) {
        guard let vault = VaultRegistry.shared.vault(forPath: path) else {
            let msg = "No vault registered for: \(path)"
            NSLog("VaultGuard: restore — %@", msg)
            DispatchQueue.main.async { self.showError("Restore Failed", detail: msg, path: path) }
            return
        }
        VaultManager.shared.restore(vault: vault) { result in
            switch result {
            case .success:
                NSLog("VaultGuard: restore succeeded — vault=%@", vault.name)
            case .failure(let e):
                os_log(.error, log: log, "restore failed: %{public}@", e.localizedDescription)
                NSLog("VaultGuard: restore FAILED — %@", e.localizedDescription)
                DispatchQueue.main.async {
                    self.showError("Restore Failed", detail: e.localizedDescription, path: path)
                }
            }
        }
    }

    // MARK: - Error surface

    private func showError(_ title: String, detail: String, path: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = "\(detail)\n\nPath: \(path)"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
