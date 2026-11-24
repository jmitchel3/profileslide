// What a profile opens with when the app opens it (no window yet):
//   newTab      Chrome's normal behaviour
//   lastSession the tabs it had the last time it was open (snapshotted while open)
//   pages       a fixed list of URLs
// Also supports Move Current Tab to Profile and Sleep Profile (Save & Close).
// Tab URLs are read through Chrome's AppleScript interface (Automation permission).

import Cocoa
import SQLite3

let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ProfileSlide")
let sessionsURL = appSupportDir.appendingPathComponent("sessions.json")

// MARK: Session snapshots

struct SavedSession {
    let urls: [String]
    let savedAt: Date
    var sleeping: Bool = false
}

enum SessionStore {
    static func load() -> [String: SavedSession] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return json.compactMapValues { d in
            guard let urls = d["urls"] as? [String], let t = d["savedAt"] as? Double else { return nil }
            let sleeping = d["sleeping"] as? Bool ?? false
            return SavedSession(urls: urls, savedAt: Date(timeIntervalSince1970: t), sleeping: sleeping)
        }
    }

    private static func persist(_ all: [String: SavedSession]) {
        let json = all.mapValues {
            [
                "urls": $0.urls,
                "savedAt": $0.savedAt.timeIntervalSince1970,
                "sleeping": $0.sleeping,
            ] as [String: Any]
        }
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    /// Replaces the snapshots of the given profiles; others are kept.
    static func update(_ tabs: [String: [String]], sleeping: Bool = false) {
        var all = load()
        for (dir, urls) in tabs where !urls.isEmpty {
            all[dir] = SavedSession(urls: urls, savedAt: Date(), sleeping: sleeping)
        }
        persist(all)
    }

    /// Clears the one-time sleeping restore flag after waking a sleeping profile.
    static func clearSleeping(for dir: String) {
        var all = load()
        guard var existing = all[dir], existing.sleeping else { return }
        existing.sleeping = false
        all[dir] = existing
        persist(all)
    }
}

// MARK: Reading tabs from Chrome

let tabQueue = DispatchQueue(label: "chrome-tabs")

/// Tab URLs of every open profile, keyed by profile directory. Calls back on the main queue;
/// `error` is set when Chrome can't be asked (usually missing Automation permission).
func readChromeTabs(_ done: @escaping (_ tabs: [String: [String]], _ error: String?) -> Void) {
    guard let chrome = chromeApp() else { done([:], nil); return }
    // AX windows give the profile (title suffix) and frame; AppleScript windows give tab URLs.
    // Matched via `matchTabWindows` (frame + active-tab title + z-order fallback).
    let profiles = loadProfiles()
    let axWindows: [AXWindowDescriptor] = standardWindows(chromeAX(chrome)).compactMap { w in
        let title = str(w, kAXTitleAttribute) ?? ""
        guard let f = frame(w) else { return nil }
        return AXWindowDescriptor(dir: profileDir(forWindowTitle: title, profiles), frame: f, title: title)
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
        var scriptWindows: [ScriptWindowDescriptor] = []
        var currentFrame: CGRect?
        var currentTitle = ""
        var currentURLs: [String] = []
        func flush() {
            if let f = currentFrame {
                scriptWindows.append(ScriptWindowDescriptor(frame: f, activeTitle: currentTitle, urls: currentURLs))
            }
            currentFrame = nil; currentTitle = ""; currentURLs = []
        }
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.first == "W", parts.count >= 2 {
                flush()
                let n = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard n.count == 4 else { continue }
                currentFrame = CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
                currentTitle = parts.count > 2 ? parts[2] : ""
            } else if parts.first == "T", parts.count >= 2, currentFrame != nil {
                currentURLs.append(parts[1])
            }
        }
        flush()
        let result = matchTabWindows(axWindows: axWindows, scriptWindows: scriptWindows)
        DispatchQueue.main.async { done(result, nil) }
    }
}

/// Saves the open profiles' tabs, for profiles set to reopen their last session.
func snapshotSessionsIfNeeded() {
    let dirs = Set(orderedProfiles(includeHidden: true).filter { $0.settings.opens == .lastSession }.map(\.dir))
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

// MARK: Move Current Tab & Sleep Profile

/// Moves the frontmost Chrome window's active tab to `target` profile and closes the source tab.
func moveCurrentTab(to target: Profile) {
    guard let chrome = chromeApp() else { return }
    let app = chromeAX(chrome)
    let sourceWindowFrame = element(app, kAXFocusedWindowAttribute).flatMap(frame)

    let script = """
    tell application id "com.google.Chrome"
        if (count of windows) is 0 then return ""
        set w to front window
        if mode of w is not "normal" then return ""
        set wid to id of w
        set t to active tab of w
        set u to URL of t
        return (wid as text) & tab & u
    end tell
    """
    tabQueue.async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { log("move tab read failed: \(error)"); return }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            log("move tab failed: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.async {
                SwitchHUD.shared.show(profile: target, profiles: orderedProfiles(), openDirs: openProfileDirs(),
                                      subtitle: "Allow Chrome Automation in Privacy Settings", over: sourceWindowFrame)
            }
            return
        }
        let parts = output.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2, let wid = Int(parts[0]) else { return }
        let url = parts[1]
        guard !url.isEmpty, !url.hasPrefix("chrome://newtab") else {
            DispatchQueue.main.async {
                SwitchHUD.shared.show(profile: target, profiles: orderedProfiles(), openDirs: openProfileDirs(),
                                      subtitle: "No movable tab active", over: sourceWindowFrame)
            }
            return
        }

        // Open the URL in the target profile (Chrome opens a new tab in its existing window, or a new window if closed).
        DispatchQueue.main.async {
            let existingWindows = profileWindows(app, for: target.dir)
            let beforeAll = standardWindows(app)
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-nb", chromeBundleID, "--args", "--profile-directory=\(target.dir)", url]
            do {
                try opener.run()
            } catch {
                log("move tab open failed: \(error)")
                return
            }

            // Close the exact source tab in the source window by window ID and matching active URL.
            let closeScript = """
            tell application id "com.google.Chrome"
                repeat with w in windows
                    if (id of w) is \(wid) then
                        if (URL of active tab of w) is "\(url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))" then
                            close active tab of w
                        end if
                        exit repeat
                    end if
                end repeat
            end tell
            """
            tabQueue.asyncAfter(deadline: .now() + 0.12) {
                let closer = Process()
                closer.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                closer.arguments = ["-e", closeScript]
                try? closer.run()
                closer.waitUntilExit()
            }

            performSwitchHaptic()
            log("moved tab \(displayHost(url)) -> \(target.name)")
            if existingWindows.isEmpty, let ref = sourceWindowFrame {
                alignNewWindow(in: app, for: target.dir, excluding: beforeAll, to: ref)
            }
            let visible = orderedProfiles()
            var openDirs = openProfileDirs()
            openDirs.insert(target.dir)
            SwitchHUD.shared.show(profile: target, profiles: visible, openDirs: openDirs,
                                  subtitle: "Moved \(displayHost(url))", over: sourceWindowFrame)
            overlay?.flash(name: "Moved to \(target.name)")
        }
    }
}

/// Saves `target`'s open tabs (for one-time wake restore) and closes its Chrome window(s) to free memory.
func sleepProfile(_ target: Profile) {
    guard let chrome = chromeApp() else { return }
    let app = chromeAX(chrome)
    let sourceWindowFrame = element(app, kAXFocusedWindowAttribute).flatMap(frame)

    let closeTargetWindows = {
        let windows = profileWindows(app, for: target.dir)
        guard !windows.isEmpty else { return }
        for w in windows {
            if let closeBtn = element(w, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(closeBtn, kAXPressAction as CFString)
            }
        }
        performSwitchHaptic()
        log("slept profile \(target.name) (\(windows.count) window(s))")
        var openDirs = openProfileDirs()
        openDirs.remove(target.dir)
        SwitchHUD.shared.show(profile: target, profiles: orderedProfiles(), openDirs: openDirs,
                              subtitle: "Saved tabs & closed window", over: sourceWindowFrame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            overlay?.refresh()
            MenuBarController.shared.updateButton()
        }
    }

    readChromeTabs { tabs, _ in
        if let urls = tabs[target.dir], !urls.isEmpty {
            SessionStore.update([target.dir: urls], sleeping: true)
        }
        closeTargetWindows()
    }
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
/// If the profile was explicitly put to sleep, wakes it with its saved tabs once.
func launchURLs(for p: Profile) -> [String] {
    let sessions = SessionStore.load()
    if let saved = sessions[p.dir], saved.sleeping, !saved.urls.isEmpty {
        SessionStore.clearSleeping(for: p.dir)
        return saved.urls
    }
    switch p.settings.opens {
    case .newTab: return []
    case .pages: return p.settings.pages
    case .lastSession: return sessions[p.dir]?.urls ?? []
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
    return WindowProfiles(app: chromeAX(chrome), focused: nil, profiles: profiles).openDirs
}
