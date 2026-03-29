import AppKit
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "AutoLockDaemon")

/// Monitors system events and triggers auto-lock on sleep, screen lock, screen saver, or idle timeout.
final class AutoLockDaemon {
    static let shared = AutoLockDaemon()

    private var idleTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.vaultguard.autolock", qos: .utility)
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Start / Stop

    func start() {
        registerWorkspaceObservers()
        resetTimer()
    }

    func stop() {
        cancelTimer()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - System event observers

    private func registerWorkspaceObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.shouldLockOnSleep == true else { return }
            os_log(.info, log: log, "Screen sleep — locking all vaults")
            self?.lockAll()
        }

        let lockObserver = wsCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.shouldLockOnSleep == true else { return }
            os_log(.info, log: log, "Session resign — locking all vaults")
            self?.lockAll()
        }

        let screenSaverObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.shouldLockOnScreenSaver == true else { return }
            self?.lockAll()
        }

        // ScreenSaver via DistributedNotificationCenter
        let ssObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.shouldLockOnScreenSaver == true else { return }
            os_log(.info, log: log, "Screen saver — locking all vaults")
            self?.lockAll()
        }

        observers = [sleepObserver, lockObserver, screenSaverObserver, ssObserver]
    }

    // MARK: - Idle timer

    func resetTimer() {
        cancelTimer()

        let intervalMinutes = AppGroupDefaults.suite?.integer(forKey: "autoLockInterval") ?? 15
        guard intervalMinutes > 0 else { return }  // 0 = Never

        let intervalNS = DispatchTimeInterval.seconds(intervalMinutes * 60)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + intervalNS, repeating: .never)
        timer.setEventHandler { [weak self] in
            os_log(.info, log: log, "Idle timeout — locking all vaults")
            self?.lockAll()
            self?.resetTimer()
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    // MARK: - Lock all

    private func lockAll() {
        // HIGH-3 fix: if a first-time create-and-copy operation is in progress, skip this
        // auto-lock cycle.  The serial VaultManager.queue serializes re-lock calls BEHIND
        // the in-progress operation, but the APFS engine's `moveFiles` step clears
        // UF_IMMUTABLE per item just before each `fm.moveItem` — a forced detach mid-move
        // could leave a partially-moved vault.  A deferred cycle fires again on the next
        // idle tick or sleep event.
        guard !VaultManager.shared.isFirstLockInProgress else {
            os_log(.info, log: log, "Skipping auto-lock — first-lock operation in progress")
            return
        }

        let unlocked = VaultRegistry.shared.vaults.filter { $0.state == .unlocked }
        guard !unlocked.isEmpty else { return }

        let group = DispatchGroup()
        for vault in unlocked {
            group.enter()
            VaultManager.shared.lock(vault: vault) { _ in group.leave() }
        }
        group.notify(queue: .main) {
            NotificationCenter.default.post(name: .vaultRegistryDidChange, object: nil)
        }
    }

    // MARK: - Settings helpers

    private var shouldLockOnSleep: Bool {
        AppGroupDefaults.suite?.bool(forKey: "autoLockOnSleep") ?? true
    }

    private var shouldLockOnScreenSaver: Bool {
        AppGroupDefaults.suite?.bool(forKey: "autoLockOnScreenSaver") ?? true
    }
}
