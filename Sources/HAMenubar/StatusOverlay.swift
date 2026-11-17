import AppKit

/// Covers the web view while the first load runs or when Home Assistant can't be reached.
@MainActor
final class StatusOverlay: NSView {
    var onRetry: (() -> Void)?
    var onSettings: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .regular

        icon.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 300

        let retry = NSButton(title: "Try Again", target: self, action: #selector(retryClicked))
        retry.keyEquivalent = "\r"
        let settings = NSButton(title: "Settings…", target: self, action: #selector(settingsClicked))
        buttons.setViews([settings, retry], in: .center)
        buttons.spacing = 8

        let stack = NSStackView(views: [spinner, icon, title, detail, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func showLoading() {
        isHidden = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        for v in [icon, title, detail, buttons] as [NSView] { v.isHidden = true }
    }

    func showError(title text: String, detail info: String) {
        isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        for v in [icon, title, detail, buttons] as [NSView] { v.isHidden = false }
        title.stringValue = text
        detail.stringValue = info
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(text). \(info)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    @objc private func retryClicked() { onRetry?() }
    @objc private func settingsClicked() { onSettings?() }
}
