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

enum SwipeSensitivity: String, CaseIterable, Identifiable {
    case light, balanced, firm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .firm: return "Firm"
        }
    }
    var threshold: Double {
        switch self {
        case .light: return 26
        case .balanced: return 40
        case .firm: return 58
        }
    }
}

struct AppPreferences: Equatable {
    var controlNumberShortcuts = true
    var arrowShortcuts = true
    var quickSwitcherEnabled = true
    var globalQuickSwitcherEnabled = true
    var syncWindowFrame = true
    var showSwitchHUD = true
    var hapticFeedback = true
    var reverseSwipe = false
    var swipeSensitivity: SwipeSensitivity = .balanced
    var confirmClosedProfiles = true
    var showMenuBarItem = true

    init() {}

    init(json: [String: Any]) {
        controlNumberShortcuts = (json["controlNumberShortcuts"] as? Bool) ?? true
        arrowShortcuts = (json["arrowShortcuts"] as? Bool) ?? true
        quickSwitcherEnabled = (json["quickSwitcherEnabled"] as? Bool) ?? true
        globalQuickSwitcherEnabled = (json["globalQuickSwitcherEnabled"] as? Bool) ?? true
        syncWindowFrame = (json["syncWindowFrame"] as? Bool) ?? true
        showSwitchHUD = (json["showSwitchHUD"] as? Bool) ?? true
        hapticFeedback = (json["hapticFeedback"] as? Bool) ?? true
        reverseSwipe = (json["reverseSwipe"] as? Bool) ?? false
        swipeSensitivity = SwipeSensitivity(rawValue: json["swipeSensitivity"] as? String ?? "") ?? .balanced
        confirmClosedProfiles = (json["confirmClosedProfiles"] as? Bool) ?? true
        showMenuBarItem = (json["showMenuBarItem"] as? Bool) ?? true
    }

    var jsonFields: [String: Any] {
        [
            "controlNumberShortcuts": controlNumberShortcuts,
            "arrowShortcuts": arrowShortcuts,
            "quickSwitcherEnabled": quickSwitcherEnabled,
            "globalQuickSwitcherEnabled": globalQuickSwitcherEnabled,
            "syncWindowFrame": syncWindowFrame,
            "showSwitchHUD": showSwitchHUD,
            "hapticFeedback": hapticFeedback,
            "reverseSwipe": reverseSwipe,
            "swipeSensitivity": swipeSensitivity.rawValue,
            "confirmClosedProfiles": confirmClosedProfiles,
            "showMenuBarItem": showMenuBarItem,
        ]
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

    init(selecting dir: String, at index: Int, pending: String?, shortcutsEnabled: Bool, confirmClosed: Bool = true) {
        if !confirmClosed || dir == pending {
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

// MARK: Quick Switcher Fuzzy Filter

/// Scores how well `query` matches `text` (higher is better, nil = no match).
func fuzzyScore(query: String, text: String) -> Int? {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return 1 }
    let t = text.lowercased()
    if t == q { return 1000 }
    if t.hasPrefix(q) { return 800 - (t.count - q.count) }
    if let range = t.range(of: q) {
        let idx = t.distance(from: t.startIndex, to: range.lowerBound)
        let boundary = idx == 0 || !t[t.index(before: range.lowerBound)].isLetter
        return (boundary ? 600 : 400) - idx
    }
    // Subsequence match
    var ti = t.startIndex
    var score = 200
    var consecutive = 0
    for ch in q {
        var found = false
        while ti < t.endIndex {
            if t[ti] == ch {
                found = true
                score += 10 + consecutive * 8
                consecutive += 1
                ti = t.index(after: ti)
                break
            }
            consecutive = 0
            score -= 1
            ti = t.index(after: ti)
        }
        if !found { return nil }
    }
    return max(1, score)
}

func filterProfiles(_ profiles: [Profile], query: String) -> [Profile] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return profiles }
    return profiles.enumerated().compactMap { index, p -> (Int, Int, Profile)? in
        let candidates = [p.name, p.email, p.settings.emoji, p.accountName ?? ""]
        guard let best = candidates.compactMap({ fuzzyScore(query: q, text: $0) }).max() else { return nil }
        return (best, index, p)
    }
    .sorted { lhs, rhs in lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 < rhs.1 }
    .map(\.2)
}

// MARK: Unified Window Frame Sync

/// Returns true when `target` should adopt `source`'s frame for seamless single-window switching.
/// Avoids yanking windows across displays or resizing fullscreen windows.
func shouldSyncWindowFrame(source: CGRect, target: CGRect, screens: [CGRect],
                           sourceFullscreen: Bool, targetFullscreen: Bool,
                           targetMinimized: Bool = false) -> Bool {
    guard !sourceFullscreen && !targetFullscreen else { return false }
    guard source.width >= 200 && source.height >= 200 else { return false }
    let sameFrame = abs(source.minX - target.minX) <= 1 && abs(source.minY - target.minY) <= 1 &&
                    abs(source.width - target.width) <= 1 && abs(source.height - target.height) <= 1
    if sameFrame { return false }
    if targetMinimized { return true }
    guard !screens.isEmpty else { return true }
    let sc = CGPoint(x: source.midX, y: source.midY)
    let tc = CGPoint(x: target.midX, y: target.midY)
    let sourceScreen = screens.firstIndex { $0.contains(sc) }
    let targetScreen = screens.firstIndex { $0.contains(tc) }
    return sourceScreen == targetScreen
}

// MARK: Tab Window Matching

struct AXWindowDescriptor {
    let dir: String?
    let frame: CGRect
    let title: String
}

struct ScriptWindowDescriptor {
    let frame: CGRect
    let activeTitle: String
    let urls: [String]
}

/// Matches AppleScript Chrome windows to AX profile directories even when multiple
/// profiles share identical window frames (as in Unified Window Mode).
func matchTabWindows(axWindows: [AXWindowDescriptor], scriptWindows: [ScriptWindowDescriptor]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    var usedAXIndices = Set<Int>()

    for sw in scriptWindows {
        let sameFrameIndices = axWindows.indices.filter { idx in
            guard !usedAXIndices.contains(idx) else { return false }
            let f = axWindows[idx].frame
            return abs(f.minX - sw.frame.minX) < 3 && abs(f.minY - sw.frame.minY) < 3 &&
                   abs(f.width - sw.frame.width) < 3 && abs(f.height - sw.frame.height) < 3
        }
        guard !sameFrameIndices.isEmpty else { continue }

        let matchedIndex: Int?
        if sameFrameIndices.count == 1 {
            matchedIndex = sameFrameIndices[0]
        } else {
            let titlePrefix = sw.activeTitle + " - Google Chrome"
            let exactTitle = sameFrameIndices.filter { axWindows[$0].title.hasPrefix(titlePrefix) }
            if exactTitle.count == 1 {
                matchedIndex = exactTitle[0]
            } else if !exactTitle.isEmpty {
                // Multiple same-frame windows with identical active tab title: both AX and
                // AppleScript list windows front-to-back, so take the frontmost unmatched match.
                matchedIndex = exactTitle[0]
            } else {
                // Fallback to frontmost unmatched window sharing the exact same frame.
                matchedIndex = sameFrameIndices[0]
            }
        }

        guard let idx = matchedIndex else { continue }
        usedAXIndices.insert(idx)
        guard let dir = axWindows[idx].dir else { continue }
        let urls = sw.urls.filter { !$0.isEmpty && !$0.hasPrefix("chrome://newtab") }
        if !urls.isEmpty {
            result[dir, default: []].append(contentsOf: urls)
        }
    }
    return result
}
