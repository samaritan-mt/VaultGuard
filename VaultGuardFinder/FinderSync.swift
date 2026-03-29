import Cocoa
import FinderSync
import os.log

private let log = OSLog(subsystem: "com.vaultguard.finder", category: "FinderSync")

// Convenience: debug-only logging that compiles away in release builds.
@inline(__always)
private func dbg(_ msg: @autoclosure () -> String) {
#if DEBUG
    os_log(.debug, log: log, "%{public}@", msg())
#endif
}

// Write a timestamped line to the shared App Group container so we can read it
// even in sandboxed Release builds where os_log is filtered.
private func fileLog(_ msg: String) {
#if DEBUG
    // Debug-only: writes to extension_debug.log in the App Group container.
    // Excluded from release builds to prevent a plaintext ledger of user paths (audit finding 3.3).
    let line = "\(Date()): \(msg)\n"
    if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.vaultguard.shared") {
        let url = dir.appendingPathComponent("extension_debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: false, encoding: .utf8)
        }
    }
#endif
}

@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {

    // Tag-to-path lookup: NSMenuItem.representedObject does not survive the XPC
    // roundtrip in FinderSync extensions, so we store paths here keyed by tag.
    private var pendingPaths: [Int: String] = [:]
    // Multi-path lookup for "Lock N items" menu items.
    private var pendingMultiPaths: [Int: [String]] = [:]
    private var nextTag = 0

    override init() {
        super.init()

        os_log(.info, log: log, "=== FinderSyncExtension init — PID %d ===", ProcessInfo.processInfo.processIdentifier)
        NSLog("VaultGuardFinder: init called, PID=%d", ProcessInfo.processInfo.processIdentifier)
        fileLog("init PID=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundlePath)")
        dbg("Bundle: \(Bundle.main.bundlePath)")
        dbg("Container: \(FileManager.default.currentDirectoryPath)")

        // Watch the entire home directory tree so right-clicking any folder works.
        // IMPORTANT: Inside a sandboxed extension, FileManager, NSHomeDirectory(), and
        // homeDirectoryForCurrentUser all return the sandbox container path, not the real
        // home directory. NSUserName() returns the short login name and is NOT redirected,
        // so constructing the path directly is the only reliable approach.
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        var watched: Set<URL> = [home]
        dbg("Home dir: \(home.path)")

        // Also watch any custom paths the user added in Settings.
        let suite = AppGroupDefaults.suite
        dbg("AppGroup suite available: \(suite != nil)")
        if let custom = suite?.stringArray(forKey: "watchedPaths"), !custom.isEmpty {
            watched.formUnion(custom.compactMap { URL(fileURLWithPath: $0) })
            dbg("Added \(custom.count) custom watched paths: \(custom.joined(separator: ", "))")
        }

        dbg("Setting directoryURLs to \(watched.count) paths: \(watched.map(\.path).joined(separator: ", "))")
        FIFinderSyncController.default().directoryURLs = watched

        let confirmedURLs = FIFinderSyncController.default().directoryURLs ?? []
        let watchedPaths = watched.map(\.path).joined(separator: ", ")
        let confirmedPaths = confirmedURLs.map(\.path).joined(separator: ", ")
        fileLog("home=\(home.path) watched=[\(watchedPaths)] confirmed=[\(confirmedPaths)]")

        os_log(.info, log: log,
               "FinderSync ready — watching %d paths (confirmed %d), home=%{public}@",
               watched.count, confirmedURLs.count, home.path)

        if confirmedURLs.isEmpty {
            fileLog("ERROR: directoryURLs is EMPTY after assignment")
            os_log(.error, log: log, "directoryURLs is EMPTY after assignment — Finder will not route events to this extension")
        }
    }

    // MARK: - Lifecycle

    deinit {
        os_log(.info, log: log, "FinderSyncExtension deinit — PID %d", ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - Context menu

    override var toolbarItemName: String { "VaultGuard" }
    override var toolbarItemToolTip: String { "Lock or unlock this folder with VaultGuard" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "VaultGuard") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        // Reset path lookup for this menu invocation.
        pendingPaths.removeAll()
        pendingMultiPaths.removeAll()
        nextTag = 0

        fileLog("menu(for:) menuKind=\(menuKind.rawValue)")
        dbg("menu(for:) called — menuKind=\(menuKind.rawValue)")

        // Only add items for right-click on items or the folder background.
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            dbg("menu(for:) skipped — menuKind \(menuKind.rawValue) is not a contextual menu")
            return menu
        }

        let controller = FIFinderSyncController.default()
        let targeted = controller.targetedURL()
        let selected = controller.selectedItemURLs()
        dbg("targetedURL=\(targeted?.path ?? "nil"), selectedItemURLs=\(selected?.map(\.lastPathComponent).joined(separator: ",") ?? "nil")")

        // For a right-click on an item, selectedItemURLs().first is the clicked item.
        // targetedURL() is the *container* being browsed — wrong for item actions.
        let url: URL?
        switch menuKind {
        case .contextualMenuForItems:    url = selected?.first ?? targeted
        case .contextualMenuForContainer: url = targeted ?? selected?.first
        default: url = nil
        }

        guard let url else {
            os_log(.error, log: log, "menu(for:) — both targetedURL and selectedItemURLs are nil, returning empty menu")
            return menu
        }

        // Check if the main app is running.
        let appRunning = IPCClient.isMainAppRunning()
        dbg("isMainAppRunning=\(appRunning)")
        guard appRunning else {
            os_log(.info, log: log, "Main app not running — offering 'Start VaultGuard'")
            let item = NSMenuItem(title: "Start VaultGuard…",
                                  action: #selector(openMainApp), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }

        // For items right-click with multiple items selected, offer a single "Lock N items" action.
        // We only show this when there are 2+ non-vault items; mixed selections (vaults + regular)
        // are allowed — vault items are simply excluded from the bundle.
        if menuKind == .contextualMenuForItems, let allSelected = selected, allSelected.count > 1 {
            let nonVaultURLs = allSelected.filter { !$0.path.hasSuffix(".vaultguard") }
            if nonVaultURLs.count > 1 {
                let tag = nextTag
                nextTag += 1
                let title = "Lock \(nonVaultURLs.count) Items with VaultGuard 🔒"
                let item = NSMenuItem(title: title, action: #selector(lockVaultMulti(_:)), keyEquivalent: "")
                item.target = self
                item.tag = tag
                pendingMultiPaths[tag] = nonVaultURLs.map(\.path)
                menu.addItem(item)
                dbg("menu built: multi-lock \(nonVaultURLs.count) items")
                return menu
            }
        }

        let path = url.path
        let isBundle = path.hasSuffix(".vaultguard")
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

        os_log(.info, log: log,
               "menu — path=%{private}@ isBundle=%d isDirectory=%d menuKind=%d",
               path, isBundle, isDirectory, menuKind.rawValue)

        if isBundle {
            add(to: menu, title: "Restore with VaultGuard 🔓",
                action: #selector(unlockVault(_:)), path: path)
        } else {
            // Works for both folders and individual files.
            // Files are transparently wrapped in a same-named folder before locking.
            add(to: menu, title: "Lock with VaultGuard 🔒",
                action: #selector(lockVault(_:)), path: path)
        }

        dbg("menu built with \(menu.items.count) item(s): \(menu.items.map(\.title).joined(separator: ", "))")
        return menu
    }

    // MARK: - Actions

    @objc private func lockVault(_ sender: NSMenuItem) {
        guard let path = pendingPaths[sender.tag] else {
            os_log(.error, log: log, "lockVault — no path found for tag %d", sender.tag)
            return
        }
        os_log(.info, log: log, "Lock requested: %{private}@", path)
        fileLog("lockVault path=\(path)")
        IPCClient.lockVault(path: path)
    }

    @objc private func unlockVault(_ sender: NSMenuItem) {
        guard let path = pendingPaths[sender.tag] else {
            os_log(.error, log: log, "unlockVault — no path found for tag %d", sender.tag)
            return
        }
        os_log(.info, log: log, "Unlock requested: %{private}@", path)
        fileLog("unlockVault path=\(path)")
        IPCClient.unlockVault(path: path)
    }

    @objc private func lockVaultMulti(_ sender: NSMenuItem) {
        guard let paths = pendingMultiPaths[sender.tag], !paths.isEmpty else {
            os_log(.error, log: log, "lockVaultMulti — no paths found for tag %d", sender.tag)
            return
        }
        os_log(.info, log: log, "Lock %d items requested", paths.count)
        fileLog("lockVaultMulti count=\(paths.count)")
        IPCClient.lockVaults(paths: paths)
    }

    @objc private func openMainApp() {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        os_log(.info, log: log, "Opening main app at: %{public}@", appURL.path)
        NSWorkspace.shared.open(appURL)
    }

    // MARK: - Helper

    private func add(to menu: NSMenu, title: String, action: Selector, path: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = nextTag
        pendingPaths[nextTag] = path
        nextTag += 1
        menu.addItem(item)
    }
}
