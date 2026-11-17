import Carbon.HIToolbox
import Foundation

let exampleURL = "http://homeassistant.local:8123/lovelace/0"

struct Dashboard: Equatable {
    let name: String
    let url: URL
}

/// Returns the URL if it is an absolute http(s) URL with a host.
func parseURL(_ raw: String) -> URL? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          url.host != nil else { return nil }
    return url
}

/// Parses one dashboard per line, either `URL` or `Name | URL`.
/// Returns the first line that is not a valid URL, if any.
func parseDashboards(_ text: String) -> (dashboards: [Dashboard], badLine: String?) {
    var result: [Dashboard] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        var name = ""
        var urlText = line
        if let bar = line.firstIndex(of: "|") {
            name = line[..<bar].trimmingCharacters(in: .whitespaces)
            urlText = String(line[line.index(after: bar)...])
        }
        guard let url = parseURL(urlText) else { return ([], line) }
        if name.isEmpty {
            let last = url.lastPathComponent
            name = (last.isEmpty || last == "/") ? (url.host ?? "Home Assistant") : last
        }
        result.append(Dashboard(name: name, url: url))
    }
    return (result, nil)
}

enum SizePreset: String, CaseIterable {
    case phone, tablet, wide

    var title: String {
        switch self {
        case .phone: "Phone (390 × 760)"
        case .tablet: "Tablet (600 × 820)"
        case .wide: "Wide (820 × 700)"
        }
    }

    var size: NSSize {
        switch self {
        case .phone: NSSize(width: 390, height: 760)
        case .tablet: NSSize(width: 600, height: 820)
        case .wide: NSSize(width: 820, height: 700)
        }
    }
}

let zoomLevels: [Double] = [0.75, 0.9, 1.0, 1.1, 1.25]

enum HotKeyOption: String, CaseIterable {
    case none, ctrlOptH, ctrlOptCmdH, ctrlOptSpace

    var title: String {
        switch self {
        case .none: "None"
        case .ctrlOptH: "⌃⌥H"
        case .ctrlOptCmdH: "⌃⌥⌘H"
        case .ctrlOptSpace: "⌃⌥Space"
        }
    }

    /// Carbon key code and modifiers, or nil for `.none`.
    var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .none: nil
        case .ctrlOptH: (UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey))
        case .ctrlOptCmdH: (UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey | cmdKey))
        case .ctrlOptSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        }
    }
}

/// All settings live in UserDefaults; nothing is hardcoded.
enum Config {
    private static var defaults: UserDefaults { .standard }

    /// Raw settings text; falls back to the single-URL key used by v0.1.
    static var dashboardsText: String {
        get { defaults.string(forKey: "dashboards") ?? defaults.string(forKey: "dashboardURL") ?? "" }
        set { defaults.set(newValue, forKey: "dashboards") }
    }

    static var dashboards: [Dashboard] { parseDashboards(dashboardsText).dashboards }

    static var selectedIndex: Int {
        get { defaults.integer(forKey: "selectedDashboard") }
        set { defaults.set(newValue, forKey: "selectedDashboard") }
    }

    static var current: Dashboard? {
        let all = dashboards
        guard !all.isEmpty else { return nil }
        return all[min(max(selectedIndex, 0), all.count - 1)]
    }

    static var fallbackText: String {
        get { defaults.string(forKey: "fallbackURL") ?? "" }
        set { defaults.set(newValue, forKey: "fallbackURL") }
    }

    /// The same path and query as `url`, on the remote fallback server.
    static func fallback(for url: URL) -> URL? {
        guard let base = parseURL(fallbackText),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseParts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              baseParts.host != url.host || baseParts.port != url.port else { return nil }
        parts.scheme = baseParts.scheme
        parts.host = baseParts.host
        parts.port = baseParts.port
        return parts.url
    }

    static var sizePreset: SizePreset {
        get { SizePreset(rawValue: defaults.string(forKey: "sizePreset") ?? "") ?? .phone }
        set { defaults.set(newValue.rawValue, forKey: "sizePreset") }
    }

    static var zoom: Double {
        get { let z = defaults.double(forKey: "zoom"); return zoomLevels.contains(z) ? z : 1.0 }
        set { defaults.set(newValue, forKey: "zoom") }
    }

    static var hotKey: HotKeyOption {
        get { HotKeyOption(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: "hotKey") }
    }

    static var pinned: Bool {
        get { defaults.bool(forKey: "pinned") }
        set { defaults.set(newValue, forKey: "pinned") }
    }

    /// SHA-256 fingerprints of self-signed certificates the user chose to trust, by host.
    static var trustedCertificates: [String: String] {
        get { defaults.dictionary(forKey: "trustedCertificates") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "trustedCertificates") }
    }
}
