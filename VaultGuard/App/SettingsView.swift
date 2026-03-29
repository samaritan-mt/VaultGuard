import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("autoLockInterval", store: AppGroupDefaults.suite)
    private var autoLockInterval: Int = 15

    @AppStorage("autoLockOnSleep", store: AppGroupDefaults.suite)
    private var autoLockOnSleep: Bool = true

    @AppStorage("autoLockOnScreenSaver", store: AppGroupDefaults.suite)
    private var autoLockOnScreenSaver: Bool = true

    @AppStorage("showNotifications", store: AppGroupDefaults.suite)
    private var showNotifications: Bool = true

    @State private var launchAtLogin: Bool = false
    @State private var vaults: [VaultEntry] = []

    private let intervals = [5, 15, 30, 60, 0]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            vaultsTab
                .tabItem { Label("Vaults", systemImage: "lock.rectangle.stack.fill") }

            securityTab
                .tabItem { Label("Security", systemImage: "shield.fill") }
        }
        .frame(width: 420, height: 320)
        .onAppear {
            vaults = VaultRegistry.shared.vaults
            if #available(macOS 13.0, *) {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section("Auto-Lock") {
                Picker("Lock after idle:", selection: $autoLockInterval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(labelForInterval(i)).tag(i)
                    }
                }
                .onChange(of: autoLockInterval) {
                    AutoLockDaemon.shared.resetTimer()
                }

                Toggle("Lock on sleep / screen lock", isOn: $autoLockOnSleep)
                Toggle("Lock on screen saver", isOn: $autoLockOnScreenSaver)
            }

            Section("Notifications") {
                Toggle("Show notification on lock/unlock", isOn: $showNotifications)
            }

            Section("Login") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if #available(macOS 13.0, *) {
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                // Silently revert if SMAppService fails
                                launchAtLogin = !enabled
                            }
                        }
                    }
            }
        }
        .padding()
    }

    private var vaultsTab: some View {
        VStack(alignment: .leading) {
            if vaults.isEmpty {
                Text("No vaults registered yet.\nRight-click any folder in Finder to lock it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                List(vaults) { vault in
                    HStack {
                        Image(systemName: vault.state == .unlocked ? "lock.open.fill" : "lock.fill")
                            .foregroundStyle(vault.state == .unlocked ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vault.name).fontWeight(.medium)
                            Text(vault.bundlePath ?? vault.originalFolderPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(vault.state == .unlocked ? "Lock" : "Unlock") {
                            toggle(vault: vault)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultRegistryDidChange)) { _ in
            vaults = VaultRegistry.shared.vaults
        }
    }

    private var securityTab: some View {
        Form {
            Section("Encryption") {
                LabeledContent("Algorithm:", value: "AES-256 (APFS sparsebundle)")
                LabeledContent("Key storage:", value: "Keychain + Secure Enclave (biometryCurrentSet)")
                LabeledContent("Auth:", value: "Touch ID — no password fallback")
                LabeledContent("Network:", value: "None — fully offline")
            }

            Section("Full Disk Access") {
                Text("Grant Full Disk Access so VaultGuard can lock and unlock folders anywhere without per-folder permission prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Privacy & Security Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }

            Section("SSD Notice") {
                Text("On SSDs, secure deletion uses best-effort overwrite. Forensic recovery may still be possible on wear-levelled storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func labelForInterval(_ i: Int) -> String {
        switch i {
        case 0: return "Never"
        case 5: return "5 minutes"
        case 15: return "15 minutes"
        case 30: return "30 minutes"
        case 60: return "1 hour"
        default: return "\(i) minutes"
        }
    }

    private func toggle(vault: VaultEntry) {
        if vault.state == .unlocked {
            VaultManager.shared.lock(vault: vault) { _ in }
        } else {
            VaultManager.shared.unlock(vault: vault) { _ in }
        }
    }
}
