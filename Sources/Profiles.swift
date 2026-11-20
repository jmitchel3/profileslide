import Cocoa

enum OpenMode: String, CaseIterable, Identifiable {
    case newTab, lastSession, pages
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .lastSession: return "Last Session"
        case .pages: return "These Pages"
        }
    }
}

struct ConfigEntry {
    var dir: String?
    var match: String?
    var emoji = ""
    var hidden = false
    var opens: OpenMode = .newTab
    var pages: [String] = []
}

extension ConfigEntry {
    init?(json: [String: Any]) {
        dir = json["dir"] as? String
        match = (json["match"] as? String)?.lowercased()
        guard dir != nil || match?.isEmpty == false else { return nil }
        emoji = json["emoji"] as? String ?? ""
        hidden = json["hidden"] as? Bool ?? false
        opens = OpenMode(rawValue: json["opens"] as? String ?? "") ?? .newTab
        pages = json["pages"] as? [String] ?? []
    }

    var json: [String: Any] {
        var result: [String: Any] = ["emoji": emoji, "hidden": hidden, "opens": opens.rawValue, "pages": pages]
        if let dir { result["dir"] = dir } else { result["match"] = match }
        return result
    }

    func profile(in profiles: [Profile]) -> Profile? {
        if let dir { return profiles.first { $0.dir == dir } }
        guard let match, !match.isEmpty else { return nil }
        let matches = profiles.filter { $0.email == match || $0.name.lowercased() == match }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct Profile {
    let dir: String
    let name: String
    let email: String
    let color: NSColor?
    let accountName: String?
    var usesDefaultName = false
    var enterpriseLabel: String?
    var settings = ConfigEntry()

    private var localWindowName: String { enterpriseLabel ?? name }

    /// Mirrors Chromium's ProfileAttributesEntry::ShouldShowProfileLocalName.
    func windowName(in profiles: [Profile]) -> String {
        guard let accountName else { return localWindowName }
        if localWindowName.caseInsensitiveCompare(accountName) == .orderedSame { return accountName }
        if usesDefaultName && enterpriseLabel == nil {
            let needsLocalName = profiles.contains { other in
                other.dir != dir && other.accountName == accountName &&
                    (other.usesDefaultName || other.localWindowName.caseInsensitiveCompare(accountName) == .orderedSame)
            }
            if !needsLocalName { return accountName }
        }
        return "\(accountName) (\(localWindowName))"
    }
}

/// A pending prompt is the swipe position until it is confirmed or dismissed.
func adjacentProfileIndex(in visible: [Profile], direction: Int, pending: String?, focused: String?) -> Int? {
    guard visible.count > 1 else { return nil }
    let start = visible.firstIndex { $0.dir == pending } ?? visible.firstIndex { $0.dir == focused }
    guard let start else {
        // A known hidden profile can enter the visible list. An unidentified window
        // might already belong to the first or last profile.
        guard focused != nil else { return nil }
        return direction > 0 ? 0 : visible.count - 1
    }
    return (start + direction + visible.count) % visible.count
}

enum ClosedProfileAction: Equatable {
    case open, ask(shortcut: Int?)

    init(selecting dir: String, at index: Int, pending: String?, shortcutsEnabled: Bool) {
        if dir == pending {
            self = .open
        } else {
            self = .ask(shortcut: shortcutsEnabled && index < 9 ? index + 1 : nil)
        }
    }
}

/// Apply each entry to one directory. A legacy email or name must identify a unique profile.
func configure(_ profiles: [Profile], with entries: [ConfigEntry]) -> [Profile] {
    let explicitDirs = Set(entries.compactMap(\.dir))
    var configured = Set<String>()
    var ordered: [Profile] = []
    for entry in entries {
        guard var p = entry.profile(in: profiles),
              entry.dir != nil || !explicitDirs.contains(p.dir),
              configured.insert(p.dir).inserted else { continue }
        p.settings = entry
        ordered.append(p)
    }
    return ordered + profiles.filter { !configured.contains($0.dir) }
}

/// Chrome can display the local name, account name, or "Account (Local name)".
/// Always check against the full catalog, including profiles hidden from the dots.
func profileDir(forWindowTitle title: String, _ profiles: [Profile]) -> String? {
    guard let r = title.range(of: " - Google Chrome - ", options: .backwards) else { return nil }
    let suffix = title[r.upperBound...]
    guard !suffix.isEmpty else { return nil }
    let displayed = profiles.filter { $0.windowName(in: profiles) == suffix }
    if !displayed.isEmpty { return displayed.count == 1 ? displayed[0].dir : nil }

    // Older titles can contain just the local or account name.
    let matches = profiles.filter { p in
        if suffix == p.name { return true }
        if let account = p.accountName {
            return suffix == account || suffix == "\(account) (\(p.name))"
        }
        return suffix.hasSuffix(" (\(p.name))")
    }
    return matches.count == 1 ? matches[0].dir : nil
}
