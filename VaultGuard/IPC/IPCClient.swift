import Foundation
import AppKit

// MARK: - Shared IPC constants (compiled into both the app and the Finder extension)

enum IPCMessage {
    static let appGroupSuite = "group.com.vaultguard.shared"
    /// Command files dropped in the App Group container by the extension.
    /// Filename pattern: ipc_<uuid>.json  — picked up by IPCService's directory watcher.
    static let commandFilePrefix = "ipc_"
}

// MARK: - IPCClient

/// Used by the Finder Sync Extension to send commands to the main app.
/// Compiled into BOTH targets.
///
/// Transport: atomic JSON file drop into the shared App Group container.
/// The main app watches that directory with a kqueue DispatchSource — no
/// cross-process notifications needed, works 100% between sandboxed processes.
///
/// Payload format: JSON object with keys:
///   "action"  : String   — "lock" | "unlock"
///   "path"    : String?  — single-item path (lock/unlock one item)
///   "paths"   : [String]? — multi-item paths (lock multiple items as one bundle)
///   "source"  : String   — sender bundle ID (defence-in-depth, audit finding 2.1)
public enum IPCClient {

    public static func lockVault(path: String) {
        write(action: "lock", paths: [path])
    }

    /// Lock multiple items as a single bundled vault.
    public static func lockVaults(paths: [String]) {
        write(action: "lock", paths: paths)
    }

    public static func unlockVault(path: String) {
        write(action: "unlock", paths: [path])
    }

    /// Returns true if the VaultGuard main app is currently running.
    public static func isMainAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.vaultguard")
            .filter { !$0.isTerminated }
            .isEmpty
    }

    // MARK: - Private

    private static func write(action: String, paths: [String]) {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: IPCMessage.appGroupSuite) else {
            NSLog("VaultGuardFinder: IPCClient — cannot resolve App Group container")
            return
        }
        // Include the sender's bundle ID so the main app can distinguish extension-initiated
        // commands from unknown senders (audit finding 2.1 — defence in depth).
        // Payload uses [String: Any] to support both single-path ("path") and
        // multi-path ("paths") without breaking backward compatibility.
        let token = UserDefaults(suiteName: IPCMessage.appGroupSuite)?.string(forKey: "ipc_token") ?? ""
        let payload: [String: Any] = [
            "action": action,
            "paths": paths,
            "source": Bundle.main.bundleIdentifier ?? "unknown",
            "token": token
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let file = dir.appendingPathComponent("\(IPCMessage.commandFilePrefix)\(UUID().uuidString).json")
        do {
            // .atomic ensures the file is either fully written or not visible at all.
            try data.write(to: file, options: .atomic)
            NSLog("VaultGuardFinder: IPCClient wrote command file action=%@ paths=%d", action, paths.count)
        } catch {
            NSLog("VaultGuardFinder: IPCClient failed to write command file: %@", error.localizedDescription)
        }
    }
}
