import AppKit
import SwiftUI

@main
struct VaultGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // No scenes declared — this is a menu-bar-only app (LSUIElement=YES).
    // The settings window is managed directly by StatusBarController as an NSWindow.
    var body: some Scene {
        _EmptyScene()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Boot core services
        UserDefaults(suiteName: "group.com.vaultguard.shared")?.set(UUID().uuidString, forKey: "ipc_token")
        VaultRegistry.shared.load()
        IPCService.shared.startListening()
        AutoLockDaemon.shared.start()

        statusBarController = StatusBarController()

        // Warn if Full Disk Access hasn't been granted — without it the sandbox
        // blocks access to arbitrary user folders and lock/unlock will silently fail.
        checkFullDiskAccess()
    }

    private func checkFullDiskAccess() {
        // Attempt to read a path that's only accessible with FDA.
        // If readable, FDA is granted; if not, show a one-time alert.
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard !FileManager.default.isReadableFile(atPath: probe) else { return }

        let shown = UserDefaults.standard.bool(forKey: "fdaAlertShown")
        guard !shown else { return }
        UserDefaults.standard.set(true, forKey: "fdaAlertShown")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Full Disk Access Required"
            alert.informativeText = "VaultGuard needs Full Disk Access to lock and unlock folders anywhere on your Mac.\n\nClick Open Settings, then add VaultGuard to the Full Disk Access list."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Lock all open vaults before quitting
        let registry = VaultRegistry.shared
        for vault in registry.vaults where vault.state == .unlocked {
            VaultManager.shared.lock(vault: vault) { _ in }
        }
        IPCService.shared.stopListening()
        AutoLockDaemon.shared.stop()
    }
}