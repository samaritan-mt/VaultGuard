import AppKit

/// A floating, non-closeable progress panel shown during long vault operations.
final class VaultProgressWindowController: NSWindowController {

    let titleLabel  = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Preparing…")
    let progressBar = NSProgressIndicator()

    // MARK: - Init

    convenience init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "VaultGuard"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.center()

        self.init(window: panel)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Preparing…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, progressBar, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    // MARK: - API

    /// Update progress (0–1) and status message. Safe to call from any thread.
    func update(fraction: Double, status: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.progressBar.isIndeterminate {
                self.progressBar.isIndeterminate = false
                self.progressBar.stopAnimation(nil)
            }
            self.progressBar.doubleValue = fraction
            self.statusLabel.stringValue = status
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    /// Whether the panel is currently on screen.
    var isVisible: Bool { window?.isVisible ?? false }

    func dismiss() {
        if Thread.isMainThread {
            window?.close()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.window?.close()
            }
        }
    }
}
