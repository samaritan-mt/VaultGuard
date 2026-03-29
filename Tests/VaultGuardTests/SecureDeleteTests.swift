import XCTest
@testable import VaultGuard

final class SecureDeleteTests: XCTestCase {

    func testDeleteRemovesDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("secret.txt")
        try "sensitive data".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let result = SecureDelete.deleteDirectory(at: tmp)
        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testOverwriteFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        let original = "original secret content"
        try original.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        SecureDelete.overwriteFile(at: tmp)

        let after = try String(contentsOf: tmp, encoding: .isoLatin1)
        XCTAssertNotEqual(after, original, "File content should be overwritten")
    }

    func testDeleteNestedStructure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "data1".write(to: root.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "data2".write(to: sub.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let result = SecureDelete.deleteDirectory(at: root)
        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
