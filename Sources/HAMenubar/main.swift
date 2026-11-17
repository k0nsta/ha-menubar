import AppKit
import ServiceManagement
import WebKit

let dashboardURLKey = "dashboardURL"
let exampleURL = "https://homeassistant.local:8123/lovelace/0"

/// The stored dashboard URL, or nil if it is missing or not an http(s) URL.
/// A bare server URL opens Home Assistant's default dashboard.
func dashboardURL() -> URL? {
    let raw = (UserDefaults.standard.string(forKey: dashboardURLKey) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          url.host != nil else { return nil }
    return url
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var settingsWindow: NSWindow?
    private var loadedURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 760), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .black

        let vc = NSViewController()
        vc.view = webView
        vc.preferredContentSize = NSSize(width: 390, height: 760)
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home Assistant")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        if dashboardURL() == nil {
            showSettings()
        } else {
            loadDashboard()
        }
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard dashboardURL() != nil else { showSettings(); return }
        if loadedURL != dashboardURL() { loadDashboard() }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: Actions

    private func loadDashboard() {
        guard let url = dashboardURL() else { return }
        loadedURL = url
        webView.load(URLRequest(url: url))
    }

    @objc private func reload() {
        if loadedURL == nil || loadedURL != dashboardURL() { loadDashboard() } else { webView.reload() }
    }

    @objc private func openInBrowser() {
        if let url = webView.url ?? dashboardURL() { NSWorkspace.shared.open(url) }
    }

    @objc private func openSettings() { showSettings() }

    @objc private func didWake() {
        if dashboardURL() != nil { loadDashboard() }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsController { [weak self] in
                self?.settingsWindow?.close()
                self?.loadDashboard()
                self?.togglePopover()
            }
            let window = NSWindow(contentViewController: controller)
            window.title = "HA Menubar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: WKUIDelegate

    /// Links with target=_blank open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

/// Plain AppKit settings window: SwiftUI property wrappers need macro plugins that ship only with Xcode.
@MainActor
final class SettingsController: NSViewController {
    private let urlField = NSTextField()
    private let loginToggle = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        urlField.placeholderString = exampleURL
        urlField.stringValue = UserDefaults.standard.string(forKey: dashboardURLKey) ?? ""
        urlField.target = self
        urlField.action = #selector(save)

        let hint = NSTextField(wrappingLabelWithString:
            "Paste the dashboard URL from your browser, or just the server URL for the default dashboard. Log in once in the popover; the session is kept.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), saveButton])
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Dashboard URL"), urlField, hint, loginToggle, errorLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [urlField, hint, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        view = stack
    }

    @objc private func save() {
        let value = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = UserDefaults.standard.string(forKey: dashboardURLKey)
        UserDefaults.standard.set(value, forKey: dashboardURLKey)
        guard dashboardURL() != nil else {
            UserDefaults.standard.set(previous, forKey: dashboardURLKey)
            showError("Enter a URL like \(exampleURL)")
            return
        }
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
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
