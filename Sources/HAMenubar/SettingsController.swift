import AppKit
import ServiceManagement

/// Plain AppKit settings: SwiftUI property wrappers need macro plugins that ship only with Xcode.
@MainActor
final class SettingsController: NSViewController {
    private let dashboardsView = NSTextView.scrollableTextView()
    private var dashboardsText: NSTextView { dashboardsView.documentView as! NSTextView }
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let fallbackField = NSTextField()
    private let sizePopup = NSPopUpButton()
    private let zoomPopup = NSPopUpButton()
    private let hotKeyPopup = NSPopUpButton()
    private let loginToggle = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let probeSpinner = NSProgressIndicator()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Text whose connection check failed; saving it again skips the check.
    private var failedProbeText: String?
    private let onSave: () -> Void
    private let fieldWidth: CGFloat = 340

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let text = dashboardsText
        text.isRichText = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = NSSize(width: 2, height: 4)
        text.setAccessibilityLabel("Dashboards, one URL per line")
        dashboardsView.borderType = .bezelBorder
        dashboardsView.heightAnchor.constraint(equalToConstant: 72).isActive = true
        for v in [dashboardsView, fallbackField] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        }
        errorLabel.preferredMaxLayoutWidth = fieldWidth

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true

        fallbackField.placeholderString = "https://example.ui.nabu.casa"
        fallbackField.contentType = .URL
        fallbackField.setAccessibilityLabel("Remote URL")

        sizePopup.addItems(withTitles: SizePreset.allCases.map(\.title))
        zoomPopup.addItems(withTitles: zoomLevels.map { "\(Int(($0 * 100).rounded()))%" })
        hotKeyPopup.addItems(withTitles: HotKeyOption.allCases.map(\.title))

        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)

        probeSpinner.style = .spinning
        probeSpinner.controlSize = .small
        probeSpinner.isDisplayedWhenStopped = false

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let grid = NSGridView(views: [
            [label("Dashboards:"), dashboardsView],
            [NSGridCell.emptyContentView, hint("One per line. Name is optional:\nKitchen | \(exampleURL)")],
            [NSGridCell.emptyContentView, errorLabel],
            [label("Remote URL:"), fallbackField],
            [NSGridCell.emptyContentView, hint("Optional. Tried when the dashboard can't be reached, e.g. away from home.")],
            [label("Size:"), sizePopup],
            [label("Zoom:"), zoomPopup],
            [label("Shortcut:"), hotKeyPopup],
            [NSGridCell.emptyContentView, loginToggle],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).yPlacement = .top
        for row in [1, 2, 4] { grid.row(at: row).topPadding = -4 }

        let buttons = NSStackView(views: [probeSpinner, cancel, saveButton])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A plain root view with required edges makes the window size itself to the content.
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        view = root
    }

    /// Fills the fields from the stored settings; called every time the window opens.
    func reloadFields() {
        _ = view
        dashboardsText.string = Config.dashboardsText
        fallbackField.stringValue = Config.fallbackText
        sizePopup.selectItem(at: SizePreset.allCases.firstIndex(of: Config.sizePreset) ?? 0)
        zoomPopup.selectItem(at: zoomLevels.firstIndex(of: Config.zoom) ?? 2)
        hotKeyPopup.selectItem(at: HotKeyOption.allCases.firstIndex(of: Config.hotKey) ?? 0)
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        errorLabel.isHidden = true
        failedProbeText = nil
        saveButton.title = "Save"
        view.window?.makeFirstResponder(dashboardsText)
    }

    @objc private func cancel() { view.window?.close() }

    @objc private func save() {
        let text = dashboardsText.string
        let (dashboards, badLine) = parseDashboards(text)
        if let badLine { return showError("Not a valid http(s) URL: \(badLine)") }
        guard let first = dashboards.first else { return showError("Add at least one dashboard URL, e.g. \(exampleURL)") }
        let fallback = fallbackField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty, parseURL(fallback) == nil { return showError("Remote URL is not a valid http(s) URL.") }

        if failedProbeText == text || text == Config.dashboardsText {
            commit(text: text, fallback: fallback)
            return
        }
        errorLabel.isHidden = true
        saveButton.isEnabled = false
        probeSpinner.startAnimation(nil)
        Task {
            let ok = await Self.isReachable(first.url)
            probeSpinner.stopAnimation(nil)
            saveButton.isEnabled = true
            if ok {
                commit(text: text, fallback: fallback)
            } else {
                failedProbeText = text
                saveButton.title = "Save Anyway"
                showError("Couldn't connect to \(first.url.host ?? "the server"). "
                    + "Check the address and that you're on the same network.")
            }
        }
    }

    private func commit(text: String, fallback: String) {
        Config.dashboardsText = text
        Config.fallbackText = fallback
        Config.sizePreset = SizePreset.allCases[max(sizePopup.indexOfSelectedItem, 0)]
        Config.zoom = zoomLevels[max(zoomPopup.indexOfSelectedItem, 0)]
        Config.hotKey = HotKeyOption.allCases[max(hotKeyPopup.indexOfSelectedItem, 0)]
        errorLabel.isHidden = true
        onSave()
    }

    @objc private func toggleLogin() {
        do {
            if loginToggle.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorLabel.isHidden = true
        } catch {
            showError(error.localizedDescription)
        }
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
        NSAccessibility.post(element: errorLabel, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = fieldWidth
        return field
    }

    /// Any HTTP response counts as reachable. Certificates are not checked here: the probe sends
    /// nothing, and the web view asks before trusting a self-signed certificate.
    private static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral, delegate: AcceptAnyTrust(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return (try? await session.data(for: request))?.1 is HTTPURLResponse
    }
}

private final class AcceptAnyTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let trust = challenge.protectionSpace.serverTrust { return (.useCredential, URLCredential(trust: trust)) }
        return (.performDefaultHandling, nil)
    }
}
