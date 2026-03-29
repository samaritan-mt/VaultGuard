import XCTest
@testable import VaultGuard

final class EngineSelectionTests: XCTestCase {

    private let manager = VaultManager.shared

    func testSmallFolderSelectsSparsebundle() throws {
        // Create a tiny folder (<< 10 GB)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(manager.engineForFolder(tmp), .sparsebundle)
    }

    func testEngineEstimateSmallFolder() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let estimate = manager.lockEstimate(for: tmp.path)
        XCTAssertEqual(estimate.engine, .sparsebundle)
        XCTAssertGreaterThan(estimate.seconds, 0)
        XCTAssertFalse(estimate.sizeDescription.isEmpty)
    }

    func testVaultEntrySparsebundleEncoding() throws {
        let entry = VaultEntry(
            id: UUID(),
            name: "TestVault",
            bundlePath: "/tmp/test.vaultguard",
            originalFolderPath: "/tmp/test"
        )
        XCTAssertEqual(entry.engineType, .sparsebundle)
        XCTAssertNil(entry.apfsVolumeUUID)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VaultEntry.self, from: data)
        XCTAssertEqual(decoded.engineType, .sparsebundle)
        XCTAssertEqual(decoded.bundlePath, "/tmp/test.vaultguard")
    }

    func testVaultEntryAPFSEncoding() throws {
        let entry = VaultEntry(
            id: UUID(),
            name: "LargeVault",
            apfsContainerDevice: "disk3",
            apfsVolumeUUID: "12345678-1234-1234-1234-123456789ABC",
            originalFolderPath: "/Users/test/BigFolder"
        )
        XCTAssertEqual(entry.engineType, .apfsVolume)
        XCTAssertNil(entry.bundlePath)
        XCTAssertEqual(entry.apfsVolumeUUID, "12345678-1234-1234-1234-123456789ABC")

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VaultEntry.self, from: data)
        XCTAssertEqual(decoded.engineType, .apfsVolume)
        XCTAssertEqual(decoded.apfsContainerDevice, "disk3")
    }
}
