import Foundation
import Security
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "SecureDelete")

/**
 * Best-effort secure deletion with honest SSD limitations.
 *
 * On SSD (all modern Macs), TRIM and wear-levelling mean the SSD controller
 * decides when/where to physically erase blocks. Overwrite passes may write to
 * different physical blocks. This is a known limitation documented to the user.
 * The APFS Volume engine avoids this entirely by moving data.
 */
enum SecureDelete {

    enum DeleteError: Error, LocalizedError {
        case enumerationFailed(Error)
        case removalFailed(Error)

        var errorDescription: String? {
            switch self {
            case .enumerationFailed(let e): return "Could not enumerate folder: \(e.localizedDescription)"
            case .removalFailed(let e): return "Could not remove item: \(e.localizedDescription)"
            }
        }
    }

    private static let fm = FileManager.default

    /**
     * Overwrites all regular files in a target URL with random bytes, then removes the directory tree.
     * Note: APFS snapshots on this volume may retain the original plaintext data.
     *
     * @param url The directory URL to securely delete.
     * @returns A Result indicating success or failure of the deletion process.
     */
    @discardableResult
    static func deleteDirectory(at url: URL) -> Result<Void, DeleteError> {
        do {
            var fileURLs: [URL] = []
            collectFiles(from: url, into: &fileURLs)

            for fileURL in fileURLs {
                overwriteFile(at: fileURL)
            }

            try fm.removeItem(at: url)

            os_log(.info, log: log, "Secure delete completed for: %{private}@", url.lastPathComponent)
            return .success(())

        } catch {
            os_log(.error, log: log, "Secure delete failed: %{public}@", error.localizedDescription)
            return .failure(.removalFailed(error))
        }
    }

    /**
     * Single-pass random overwrite using NIST SP 800-88 guidance for SSDs.
     * Does not guarantee physical erasure on SSD but raises the forensic bar.
     * Falls back to zero-fill if hardware RNG fails.
     *
     * @param url The file URL to overwrite with random bytes.
     */
    static func overwriteFile(at url: URL) {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 0 else { return }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            os_log(.error, log: log, "overwriteFile: could not open handle for writing")
            return
        }
        defer { try? handle.close() }

        let chunkSize = min(size, 1024 * 1024)
        var randomBuf = [UInt8](repeating: 0, count: chunkSize)

        let rngStatus = SecRandomCopyBytes(kSecRandomDefault, randomBuf.count, &randomBuf)
        if rngStatus != errSecSuccess {
            os_log(.error, log: log, "overwriteFile: SecRandomCopyBytes failed (%d) — using zero fill", rngStatus)
        }

        var written = 0
        while written < size {
            let toWrite = min(chunkSize, size - written)
            do {
                try handle.write(contentsOf: Data(randomBuf[0..<toWrite]))
            } catch {
                os_log(.error, log: log, "overwriteFile: write failed at offset %d: %{public}@",
                       written, error.localizedDescription)
                break
            }
            written += toWrite
        }
        try? handle.synchronize()

        memset_s(&randomBuf, randomBuf.count, 0, randomBuf.count)
    }

    /**
     * Recursively traverses a directory and collects all regular files.
     *
     * @param dir The starting directory URL.
     * @param result An inout array of URLs to append discovered files into.
     */
    private static func collectFiles(from dir: URL, into result: inout [URL]) {
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else { return }

        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                collectFiles(from: url, into: &result)
            } else if values?.isRegularFile == true {
                result.append(url)
            }
        }
    }
}
