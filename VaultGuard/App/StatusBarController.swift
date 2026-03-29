import AppKit
import SwiftUI
import Combine

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    // Own the settings window — SwiftUI's Settings scene is unreliable for LSUIElement apps.
    private var settingsWindowController: NSWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "VaultGuard")
            button.image?.isTemplate = true
        }

        buildMenu()
        subscribeToRegistryChanges()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let vaults = VaultRegistry.shared.vaults
        if vaults.isEmpty {
            let empty = NSMenuItem(title: "No vaults registered", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for vault in vaults {
                menu.addItem(vaultMenuItem(for: vault))
            }
        }

        menu.addItem(.separator())

        let lockAll = NSMenuItem(title: "Lock All", action: #selector(lockAll), keyEquivalent: "l")
        lockAll.keyEquivalentModifierMask = [.command, .shift]
        lockAll.target = self
        menu.addItem(lockAll)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit VaultGuard", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu

        // Update icon based on any unlocked vault
        updateStatusIcon()
    }

    private func vaultMenuItem(for vault: VaultEntry) -> NSMenuItem {
        let icon = vault.state == .unlocked ? "🔓" : "🔒"
        let title = "\(icon)  \(vault.name)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

        let sub = NSMenu()
        sub.autoenablesItems = false

        let toggleTitle = vault.state == .unlocked ? "Lock" : "Unlock"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleVault(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.representedObject = vault.id.uuidString
        sub.addItem(toggleItem)

        sub.addItem(.separator())

        let restoreItem = NSMenuItem(title: "Restore (permanently decrypt)…", action: #selector(restoreVault(_:)), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.representedObject = vault.id.uuidString
        restoreItem.isEnabled = vault.state == .locked
        sub.addItem(restoreItem)

        item.submenu = sub
        return item
    }

    private func updateStatusIcon() {
        let hasUnlocked = VaultRegistry.shared.vaults.contains { $0.state == .unlocked }
        if hasUnlocked {
            // At least one vault is unlocked — switch to the open-lock SF Symbol
            let img = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "VaultGuard — vault unlocked")
            img?.isTemplate = true
            statusItem.button?.image = img
        } else {
            // All vaults locked — show the system lock SF Symbol
            let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "VaultGuard")
            img?.isTemplate = true
            statusItem.button?.image = img
        }
    }

    // MARK: - Actions

    @objc private func toggleVault(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let uuid = UUID(uuidString: uuidString),
              let vault = VaultRegistry.shared.vault(for: uuid) else { return }

        if vault.state == .unlocked {
            VaultManager.shared.lock(vault: vault) { result in
                DispatchQueue.main.async { self.buildMenu() }
            }
        } else {
            VaultManager.shared.unlock(vault: vault) { result in
                DispatchQueue.main.async { self.buildMenu() }
            }
        }
    }

    @objc private func restoreVault(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let uuid = UUID(uuidString: uuidString),
              let vault = VaultRegistry.shared.vault(for: uuid) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore \"\(vault.name)\"?"
        alert.informativeText = "The vault will be permanently decrypted back to its original folder. The encrypted bundle will be deleted. This cannot be undone."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let progress = VaultProgressWindowController(title: "Restoring \"\(vault.name)\"…")
        progress.show()

        VaultManager.shared.restore(vault: vault) { result in
            progress.dismiss()
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.buildMenu()
                case .failure(let e):
                    let err = NSAlert()
                    err.alertStyle = .critical
                    err.messageText = "Restore Failed"
                    err.informativeText = e.localizedDescription
                    err.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    err.runModal()
                }
            }
        }
    }

    @objc private func lockAll() {
        let unlocked = VaultRegistry.shared.vaults.filter { $0.state == .unlocked }
        let group = DispatchGroup()
        for vault in unlocked {
            group.enter()
            VaultManager.shared.lock(vault: vault) { _ in group.leave() }
        }
        group.notify(queue: .main) { self.buildMenu() }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "VaultGuard Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 440, height: 340))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Reactive rebuild

    private func subscribeToRegistryChanges() {
        NotificationCenter.default.publisher(for: .vaultRegistryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)
    }
}