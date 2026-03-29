import LocalAuthentication
import os.log

private let log = OSLog(subsystem: "com.vaultguard", category: "BiometricAuth")

/// Pure Touch ID gate — no password fallback, no context reuse.
enum BiometricAuth {

    enum AuthError: Error, LocalizedError {
        case biometryNotAvailable
        case biometryLockout
        case userCancel
        case systemCancel
        case failed(Error)

        var errorDescription: String? {
            switch self {
            case .biometryNotAvailable: return "Touch ID is not available on this device."
            case .biometryLockout:
                return "Touch ID is locked. Please re-authenticate in System Settings."
            case .userCancel: return "Authentication was cancelled."
            case .systemCancel: return "Authentication was cancelled by the system."
            case .failed(let e): return e.localizedDescription
            }
        }
    }

    // MARK: - Availability check

    static func isAvailable() -> Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - Authenticate

    /// Creates a fresh LAContext and evaluates Touch ID — NO password fallback.
    /// Calls `completion` on the main queue.
    static func authenticate(
        reason: String,
        completion: @escaping (Result<LAContext, AuthError>) -> Void
    ) {
        let context = LAContext()
        context.localizedFallbackTitle = ""   // hide "Enter Password"
        context.localizedCancelTitle = "Cancel"

        // Biometrics only — no device password fallback
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) { success, rawError in
            DispatchQueue.main.async {
                if success {
                    os_log(.info, log: log, "Touch ID succeeded")
                    completion(.success(context))
                    return
                }

                guard let nsErr = rawError as? NSError else {
                    completion(.failure(.failed(rawError!)))
                    return
                }

                let mapped: AuthError
                switch LAError.Code(rawValue: nsErr.code) {
                case .biometryLockout:
                    mapped = .biometryLockout
                    os_log(.error, log: log, "Touch ID lockout")
                case .userCancel, .appCancel:
                    mapped = .userCancel
                case .systemCancel:
                    mapped = .systemCancel
                case .biometryNotAvailable, .biometryNotEnrolled:
                    mapped = .biometryNotAvailable
                default:
                    mapped = .failed(rawError!)
                    os_log(.error, log: log, "Touch ID failed: %{public}@", nsErr.localizedDescription)
                }
                completion(.failure(mapped))
            }
        }
    }
}
