import Foundation

// MARK: - VaultEngineType

enum VaultEngineType: String, Codable {
    case sparsebundle   // hdiutil — good for < 10 GB, portable bundle
    case apfsVolume     // diskutil apfs — best for >= 10 GB, no 2× disk penalty
}

// MARK: - VaultEntry

/// Codable model stored in the shared App Group UserDefaults.
/// Does NOT store passphrases — those live exclusively in Keychain.
struct VaultEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// Human-readable name derived from the original folder name.
    var name: String
    /// Engine used to create this vault.
    var engineType: VaultEngineType
    /// Absolute path to the .vaultguard sparsebundle (sparsebundle engine only).
    var bundlePath: String?
    /// BSD device identifier of the APFS container the vault volume lives on (apfsVolume engine only).
    var apfsContainerDevice: String?
    /// UUID of the APFS volume (apfsVolume engine only).
    var apfsVolumeUUID: String?
    /// Original folder path — restored as the mount point on unlock.
    var originalFolderPath: String
    /// Current mount state. Persisted so the status bar reflects the last-known state across relaunches.
    var state: VaultState

    // Sparsebundle constructor
    init(
        id: UUID = UUID(),
        name: String,
        bundlePath: String,
        originalFolderPath: String,
        state: VaultState = .locked
    ) {
        self.id = id
        self.name = name
        self.engineType = .sparsebundle
        self.bundlePath = bundlePath
        self.originalFolderPath = originalFolderPath
        self.state = state
    }

    // APFS volume constructor
    init(
        id: UUID = UUID(),
        name: String,
        apfsContainerDevice: String,
        apfsVolumeUUID: String,
        originalFolderPath: String,
        state: VaultState = .locked
    ) {
        self.id = id
        self.name = name
        self.engineType = .apfsVolume
        self.apfsContainerDevice = apfsContainerDevice
        self.apfsVolumeUUID = apfsVolumeUUID
        self.originalFolderPath = originalFolderPath
        self.state = state
    }
}

enum VaultState: String, Codable {
    case locked
    case unlocked
}

// MARK: - Notification

extension Notification.Name {
    static let vaultRegistryDidChange = Notification.Name("com.vaultguard.registryDidChange")
}

// MARK: - VaultRegistry

/// Thread-safe vault list stored in the App Group shared UserDefaults.
final class VaultRegistry {
    static let shared = VaultRegistry()

    private let queue = DispatchQueue(label: "com.vaultguard.registry", attributes: .concurrent)
    private var _vaults: [VaultEntry] = []

    var vaults: [VaultEntry] {
        queue.sync { _vaults }
    }

    private init() {}

    // MARK: - Persistence

    func load() {
        guard let data = AppGroupDefaults.suite?.data(forKey: "vaultRegistry"),
              let decoded = try? JSONDecoder().decode([VaultEntry].self, from: data) else { return }
        queue.async(flags: .barrier) { self._vaults = decoded }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(_vaults) else { return }
        AppGroupDefaults.suite?.set(data, forKey: "vaultRegistry")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vaultRegistryDidChange, object: nil)
        }
    }

    // MARK: - CRUD

    func register(_ vault: VaultEntry) {
        queue.async(flags: .barrier) {
            guard !self._vaults.contains(where: { $0.id == vault.id }) else { return }
            self._vaults.append(vault)
            self.save()
        }
    }

    func remove(id: UUID) {
        queue.async(flags: .barrier) {
            self._vaults.removeAll { $0.id == id }
            self.save()
        }
    }

    func update(id: UUID, state: VaultState) {
        queue.async(flags: .barrier) {
            guard let idx = self._vaults.firstIndex(where: { $0.id == id }) else { return }
            self._vaults[idx].state = state
            self.save()
        }
    }

    func vault(for id: UUID) -> VaultEntry? {
        queue.sync { _vaults.first { $0.id == id } }
    }

    /// Find a vault that owns the given path (by bundle path or original folder path).
    func vault(forPath path: String) -> VaultEntry? {
        queue.sync {
            _vaults.first {
                $0.bundlePath == path ||
                $0.originalFolderPath == path ||
                path.hasPrefix($0.bundlePath ?? "____")
            }
        }
    }
}

// MARK: - AppGroupDefaults

enum AppGroupDefaults {
    static let groupID = "group.com.vaultguard.shared"
    static var suite: UserDefaults? { UserDefaults(suiteName: groupID) }
}
