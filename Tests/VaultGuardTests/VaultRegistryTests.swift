import XCTest
@testable import VaultGuard

final class VaultRegistryTests: XCTestCase {
    private var registry: VaultRegistry!

    override func setUp() {
        super.setUp()
        registry = VaultRegistry.shared
    }

    func testRegisterAndRetrieve() {
        let entry = VaultEntry(name: "TestVault", bundlePath: "/tmp/test.vaultguard", originalFolderPath: "/tmp/test")
        registry.register(entry)
        XCTAssertNotNil(registry.vault(for: entry.id))
        registry.remove(id: entry.id)
    }

    func testUpdateState() {
        let entry = VaultEntry(name: "StateVault", bundlePath: "/tmp/state.vaultguard", originalFolderPath: "/tmp/state")
        registry.register(entry)
        registry.update(id: entry.id, state: .unlocked)
        XCTAssertEqual(registry.vault(for: entry.id)?.state, .unlocked)
        registry.remove(id: entry.id)
    }

    func testRemove() {
        let entry = VaultEntry(name: "RemoveVault", bundlePath: "/tmp/remove.vaultguard", originalFolderPath: "/tmp/remove")
        registry.register(entry)
        registry.remove(id: entry.id)
        XCTAssertNil(registry.vault(for: entry.id))
    }

    func testNoDuplicateRegistration() {
        let entry = VaultEntry(name: "DupeVault", bundlePath: "/tmp/dupe.vaultguard", originalFolderPath: "/tmp/dupe")
        registry.register(entry)
        let countBefore = registry.vaults.filter { $0.id == entry.id }.count
        registry.register(entry)
        let countAfter = registry.vaults.filter { $0.id == entry.id }.count
        XCTAssertEqual(countBefore, countAfter)
        registry.remove(id: entry.id)
    }
}
