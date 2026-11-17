import AppKit
import CryptoKit
import Network
import ServiceManagement
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!
    private let overlay = StatusOverlay()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var settingsWindow: NSWindow?
    private var settingsController: SettingsController?

    /// The dashboard the web view was last pointed at (primary URL, not fallback).
    private var loadedDashboard: Dashboard?
    private var usingFallback = false
    private var hasContent = false
    private var lastLoadFailed = false
    private var reloadWhenOnline = false
    private var askingTrust = false
    private let pathMonitor = NWPathMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.appearance = NSAppearance(named: .darkAqua)

        let container = NSView()
        for v in [webView!, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        // Without explicit size, auto layout shrinks the popover to the overlay's fitting size.
        widthConstraint = container.widthAnchor.constraint(equalToConstant: 390)
        heightConstraint = container.heightAnchor.constraint(equalToConstant: 760)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        overlay.isHidden = true
        overlay.onRetry = { [weak self] in self?.loadDashboard() }
        overlay.onSettings = { [weak self] in self?.showSettings() }

        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.animates = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setStatus(offline: false)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: .main)

        HotKey.shared.action = { [weak self] in self?.togglePopover() }
        applySettings()

        if Config.current == nil {
            showSettings()
        } else {
            loadDashboard()
        }
    }

    private func applySettings() {
        HotKey.shared.set(Config.hotKey)
        webView.pageZoom = Config.zoom
        popover.behavior = Config.pinned ? .applicationDefined : .transient
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

    private func setStatus(offline: Bool) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: offline ? "house.slash" : "house",
                            accessibilityDescription: offline ? "Home Assistant, offline" : "Home Assistant")
        image?.isTemplate = true
        button.image = image
        let host = Config.current?.url.host
        button.toolTip = offline ? "Home Assistant — offline" : host.map { "Home Assistant — \($0)" } ?? "Home Assistant"
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let current = Config.current else { showSettings(); return }
        if loadedDashboard != current || lastLoadFailed { loadDashboard() }
        guard let button = statusItem.button else { return }

        let preset = Config.sizePreset.size
        let screenHeight = button.window?.screen?.visibleFrame.height ?? preset.height + 40
        widthConstraint.constant = preset.width
        heightConstraint.constant = min(preset.height, screenHeight - 40)

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(webView)
    }

    private func showMenu() {
        let menu = NSMenu()
        let dashboards = Config.dashboards
        let hasURL = !dashboards.isEmpty

        if dashboards.count > 1 {
            let selected = min(max(Config.selectedIndex, 0), dashboards.count - 1)
            for (i, d) in dashboards.enumerated() {
                let item = menu.addItem(withTitle: d.name, action: #selector(selectDashboard(_:)),
                                        keyEquivalent: i < 9 ? "\(i + 1)" : "")
                item.target = self
                item.tag = i
                item.state = i == selected ? .on : .off
            }
            menu.addItem(.separator())
        }
        let reload = menu.addItem(withTitle: "Reload", action: hasURL ? #selector(reload) : nil, keyEquivalent: "r")
        reload.target = self
        let open = menu.addItem(withTitle: "Open in Browser", action: hasURL ? #selector(openInBrowser) : nil,
                                keyEquivalent: "o")
        open.target = self
        let pin = menu.addItem(withTitle: "Keep Open", action: #selector(togglePinned), keyEquivalent: "")
        pin.target = self
        pin.state = Config.pinned ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "About HA Menubar", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit HA Menubar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Attaching the menu for one click gives the native highlight and placement.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Never shown (LSUIElement), but Cocoa routes Cmd+C/V/X/A/Z through main menu key equivalents.
    private func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        return main
    }

    // MARK: Loading

    /// Loads the selected dashboard from its primary URL.
    private func loadDashboard() {
        guard let current = Config.current else { return }
        loadedDashboard = current
        usingFallback = false
        load(current.url)
    }

    private func load(_ url: URL) {
        lastLoadFailed = false
        if !hasContent { overlay.showLoading() }
        webView.load(URLRequest(url: url))
    }

    /// Reloads in place when possible so the current view (pop-up, scroll) is kept.
    private func refresh() {
        if loadedDashboard != Config.current || usingFallback || lastLoadFailed || webView.url == nil {
            loadDashboard()
        } else {
            webView.reload()
        }
    }

    @objc private func didWake() {
        guard Config.current != nil else { return }
        // Wi-Fi is usually not back yet; wait for the path monitor, with a delayed check as backup.
        reloadWhenOnline = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.reloadWhenOnline, self.pathMonitor.currentPath.status == .satisfied else { return }
            self.reloadWhenOnline = false
            self.refresh()
        }
    }

    private func networkChanged(online: Bool) {
        guard online, Config.current != nil, reloadWhenOnline || lastLoadFailed else { return }
        reloadWhenOnline = false
        refresh()
    }

    private func loadFailed(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return } // frame load interrupted

        if !usingFallback, let failed = loadedDashboard?.url, let fallback = Config.fallback(for: failed) {
            usingFallback = true
            load(fallback)
            return
        }
        lastLoadFailed = true
        hasContent = false
        setStatus(offline: true)
        let host = (usingFallback ? Config.fallbackText : loadedDashboard?.url.absoluteString)
            .flatMap { URL(string: $0)?.host } ?? "the server"
        overlay.showError(title: "Can't reach Home Assistant",
                          detail: "\(host): \(nsError.localizedDescription)")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasContent = true
        lastLoadFailed = false
        overlay.hide()
        setStatus(offline: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasContent = false
        loadDashboard()
    }

    /// Self-signed certificates: ask once per host and pin the SHA-256 fingerprint.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }

        let host = challenge.protectionSpace.host
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02X", $0) }.joined(separator: ":")
        if Config.trustedCertificates[host] == fingerprint { return (.useCredential, URLCredential(trust: trust)) }

        // Only ask while the user is looking, and one question at a time.
        guard popover.isShown || settingsWindow?.isVisible == true, !askingTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        askingTrust = true
        defer { askingTrust = false }
        let alert = NSAlert()
        alert.messageText = "Trust the certificate for \(host)?"
        alert.informativeText = "It isn't signed by a trusted authority, which is normal for a self-hosted "
            + "Home Assistant. Only trust it if this is your server.\n\nSHA-256:\n\(fingerprint)"
        alert.addButton(withTitle: "Trust")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        Config.trustedCertificates[host] = fingerprint
        return (.useCredential, URLCredential(trust: trust))
    }

    // MARK: WKUIDelegate

    /// Links with target=_blank open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: Actions

    @objc private func reload() { refresh() }

    @objc private func openInBrowser() {
        if let url = webView.url ?? Config.current?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func selectDashboard(_ sender: NSMenuItem) {
        Config.selectedIndex = sender.tag
        hasContent = false
        loadDashboard()
        if !popover.isShown { togglePopover() }
    }

    @objc private func togglePinned() {
        Config.pinned.toggle()
        applySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Your Home Assistant dashboard in the menu bar.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    @objc private func openSettings() { showSettings() }

    private func showSettings() {
        if popover.isShown { popover.performClose(nil) }
        if settingsWindow == nil {
            let controller = SettingsController { [weak self] in
                guard let self else { return }
                self.settingsWindow?.close()
                self.applySettings()
                self.setStatus(offline: false)
                if self.loadedDashboard != Config.current { self.hasContent = false }
                self.loadDashboard()
                self.togglePopover()
            }
            let window = NSWindow(contentViewController: controller)
            window.title = "HA Menubar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Restore only the saved position; the size always comes from the layout.
            let restored = window.setFrameUsingName("Settings")
            window.setContentSize(controller.view.fittingSize)
            if !restored { window.center() }
            window.setFrameAutosaveName("Settings")
            settingsWindow = window
            settingsController = controller
        }
        settingsController?.reloadFields()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
