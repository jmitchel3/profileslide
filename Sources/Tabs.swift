// What a profile opens with when the app opens it (no window yet):
//   newTab      Chrome's normal behaviour
//   lastSession the tabs it had the last time it was open (snapshotted while open)
//   pages       a fixed list of URLs
// Tab URLs are read through Chrome's AppleScript interface (Automation permission).

import Cocoa
import SQLite3

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

let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ChromeProfileSwipe")
let sessionsURL = appSupportDir.appendingPathComponent("sessions.json")

// MARK: Session snapshots

struct SavedSession { let urls: [String]; let savedAt: Date }

enum SessionStore {
    static func load() -> [String: SavedSession] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return json.compactMapValues { d in
            guard let urls = d["urls"] as? [String], let t = d["savedAt"] as? Double else { return nil }
            return SavedSession(urls: urls, savedAt: Date(timeIntervalSince1970: t))
        }
    }

    /// Replaces the snapshots of the given profiles; others are kept.
    static func update(_ tabs: [String: [String]]) {
        var all = load()
        for (dir, urls) in tabs where !urls.isEmpty { all[dir] = SavedSession(urls: urls, savedAt: Date()) }
        let json = all.mapValues { ["urls": $0.urls, "savedAt": $0.savedAt.timeIntervalSince1970] as [String: Any] }
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sessionsURL)
        }
    }
}

// MARK: Reading tabs from Chrome

let tabQueue = DispatchQueue(label: "chrome-tabs")

/// Tab URLs of every open profile, keyed by profile directory. Calls back on the main queue;
/// `error` is set when Chrome can't be asked (usually missing Automation permission).
func readChromeTabs(_ done: @escaping (_ tabs: [String: [String]], _ error: String?) -> Void) {
    guard let chrome = chromeApp() else { done([:], nil); return }
    // AX windows give the profile (title suffix) and frame; AppleScript windows give tab URLs.
    // They're matched by frame and active-tab title.
    let profiles = loadProfiles()
    let axWindows: [(dir: String, frame: CGRect, title: String)] = standardWindows(chromeAX(chrome)).compactMap { w in
        let title = str(w, kAXTitleAttribute) ?? ""
        guard let dir = profileDir(forWindowTitle: title, profiles), let f = frame(w) else { return nil }
        return (dir, f, title)
    }
    let script = """
    tell application id "com.google.Chrome"
        set out to ""
        repeat with w in windows
            if mode of w is "normal" then
                set b to bounds of w
                set out to out & "W" & tab & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & tab & (title of active tab of w) & linefeed
                repeat with t in tabs of w
                    set out to out & "T" & tab & (URL of t) & linefeed
                end repeat
            end if
        end repeat
        return out
    end tell
    """
    tabQueue.async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { DispatchQueue.main.async { done([:], "\(error)") }; return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            log("reading Chrome tabs failed: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.async { done([:], errText) }
            return
        }
        var result: [String: [String]] = [:]
        var current: String?
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.first == "W", parts.count >= 2 {
                let n = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let activeTitle = parts.count > 2 ? parts[2] : ""
                current = nil
                guard n.count == 4 else { continue }
                let f = CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
                let sameFrame = axWindows.filter { abs($0.frame.minX - f.minX) < 3 && abs($0.frame.minY - f.minY) < 3 &&
                                                   abs($0.frame.width - f.width) < 3 && abs($0.frame.height - f.height) < 3 }
                current = (sameFrame.count == 1 ? sameFrame.first
                           : sameFrame.first { $0.title.hasPrefix(activeTitle) })?.dir
            } else if parts.first == "T", parts.count >= 2, let dir = current {
                let url = parts[1]
                if !url.isEmpty, !url.hasPrefix("chrome://newtab") { result[dir, default: []].append(url) }
            }
        }
        DispatchQueue.main.async { done(result, nil) }
    }
}

/// Saves the open profiles' tabs, for profiles set to reopen their last session.
func snapshotSessionsIfNeeded() {
    let dirs = Set(orderedProfiles(includeHidden: true).filter { openMode(for: $0) == .lastSession }.map(\.dir))
    guard !dirs.isEmpty else { return }
    readChromeTabs { tabs, _ in
        let wanted = tabs.filter { dirs.contains($0.key) }
        if !wanted.isEmpty { SessionStore.update(wanted) }
    }
}

var sessionTimer: Timer?

/// While Chrome is frontmost, snapshot every 30 s (only does work if a profile uses Last Session).
func startSessionSnapshots() {
    let nc = NSWorkspace.shared.notificationCenter
    func sync() {
        if chromeApp()?.isActive == true {
            if sessionTimer == nil {
                sessionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in snapshotSessionsIfNeeded() }
            }
        } else if sessionTimer != nil {
            sessionTimer?.invalidate(); sessionTimer = nil
            snapshotSessionsIfNeeded() // leaving Chrome: save once more
        }
    }
    nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in sync() }
    sync()
}

// MARK: Top sites

struct Site: Hashable { let url: String; let title: String }

/// The profile's most visited sites: Chrome's Top Sites list, then History by visit count.
func topSites(_ dir: String, limit: Int = 16) -> [Site] {
    let base = localStateURL.deletingLastPathComponent().appendingPathComponent(dir)
    var out: [Site] = []
    func query(_ file: String, _ sql: String) {
        var db: OpaquePointer?
        let uri = "file:\(base.appendingPathComponent(file).path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u = sqlite3_column_text(stmt, 0) else { continue }
            let url = String(cString: u)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? url
            guard url.hasPrefix("http"), !out.contains(where: { $0.url == url }) else { continue }
            out.append(Site(url: url, title: title.isEmpty ? url : title))
        }
    }
    query("Top Sites", "SELECT url, title FROM top_sites ORDER BY url_rank")
    query("History", "SELECT url, title FROM urls WHERE hidden = 0 ORDER BY visit_count DESC LIMIT 40")
    return Array(out.prefix(limit))
}

// MARK: Launch URLs

/// URLs to pass Chrome when opening a profile that has no window.
func launchURLs(for p: Profile) -> [String] {
    switch openMode(for: p) {
    case .newTab: return []
    case .pages: return pages(for: p)
    case .lastSession: return SessionStore.load()[p.dir]?.urls ?? []
    }
}

func displayHost(_ url: String) -> String {
    guard let u = URL(string: url), let host = u.host else { return url }
    let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return u.path.count > 1 ? h + u.path : h
}

/// Directories of profiles that currently have a window (hidden profiles included).
func openProfileDirs() -> Set<String> {
    guard let chrome = chromeApp() else { return [] }
    let profiles = loadProfiles()
    return Set(standardWindows(chromeAX(chrome)).compactMap { profileDir(forWindowTitle: str($0, kAXTitleAttribute) ?? "", profiles) })
}
