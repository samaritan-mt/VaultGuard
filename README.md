# VaultGuard

VaultGuard is a native macOS application and Finder extension designed to securely lock and encrypt folders and files directly from the macOS Finder context menu.

## Features

- **Finder Integration**: Right-click any folder or file to instantly lock it using VaultGuard.
- **Dual-Engine Encryption**:
  - Automatically utilizes **encrypted APFS volumes** for folders larger than 10GB for instantaneous, metadata-only locking without duplicating disk usage.
  - Utilizes **encrypted Sparsebundles** for smaller folders to ensure portability.
- **Biometric Authentication**: Requires Touch ID or Apple Watch authentication to unlock and restore folders. The encryption key is securely stored in the iOS/macOS Keychain backed by the Secure Enclave.
- **Fully Offline**: 100% offline operation with zero network dependencies.
- **Status Bar App**: Easily manage, verify, and permanently decrypt all your registered vaults directly from the macOS menu bar.
- **Auto-Lock Daemon**: Automatically re-locks your opened vaults after an idle period or when your Mac is put to sleep.
- **Integrity Validation**: Runs structural and physical size integrity checks on the APFS volumes and Sparsebundles before securely deleting the original unencrypted contents, strictly preventing data loss.

## Installation

1. Build the app using Xcode or the provided `Makefile`.
2. Move `VaultGuard.app` into your `/Applications` directory.
3. Launch VaultGuard. Providing **Full Disk Access** inside macOS System Settings is recommended for seamless operation outside standard directories.
4. Open **System Settings > Extensions > Finder Extensions** and enable the VaultGuard Finder extension.
5. In Finder, right-click any folder inside your Home directory and select **Lock with VaultGuard 🔒**.
