// Arc-style space switching for Google Chrome on macOS:
// horizontal two-finger swipe over Chrome's vertical tab sidebar, interactive profile dots,
// unified window alignment, Quick Switcher, Move Tab, Sleep Profile, and menu bar companion.
// Logs to ~/Library/Logs/ProfileSlide/poc.log

import Cocoa
import ApplicationServices

let chromeBundleID = "com.google.Chrome"
let localStateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")

// MARK: Logging

let logDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/ProfileSlide")
let logURL = logDir.appendingPathComponent("poc.log")
let logBackupURL = logDir.appendingPathComponent("poc.log.1")
let maxLogBytes: UInt64 = 512 * 1024
let stamp = ISO8601DateFormatter()
private var logWritesSinceRotateCheck = 0

func log(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    logWritesSinceRotateCheck += 1
    if logWritesSinceRotateCheck >= 50 {
        logWritesSinceRotateCheck = 0
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? UInt64,
           size > maxLogBytes {
            try? FileManager.default.removeItem(at: logBackupURL)
            try? FileManager.default.moveItem(at: logURL, to: logBackupURL)
        }
    }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: AX helpers

let systemWide = AXUIElementCreateSystemWide()

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func element(_ e: AXUIElement, _ a: String) -> AXUIElement? {
    guard let v = attr(e, a), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func role(_ e: AXUIElement) -> String? { str(e, kAXRoleAttribute) }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func isFullscreen(_ window: AXUIElement) -> Bool {
    (attr(window, "AXFullScreen") as? Bool) == true
}

func setWindowFrame(_ window: AXUIElement, to rect: CGRect) {
    var pos = rect.origin, size = rect.size
    if let pv = AXValueCreate(.cgPoint, &pos) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv)
    }
    if let sv = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
    }
}

/// Converts NSScreen frames (bottom-left origin) to AX top-left coordinates.
func axScreenRects() -> [CGRect] {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.map { s in
        CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }
}

func chromeApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).first
}

func chromeAX(_ chrome: NSRunningApplication) -> AXUIElement {
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.25)
    return app
}

/// The vertical tab strip: an AXTabGroup taller than half the window.
func isTabStrip(_ e: AXUIElement, windowFrame wf: CGRect) -> Bool {
    guard role(e) == "AXTabGroup", let f = frame(e) else { return false }
    return isSidebarFrame(f, in: wf)
}

func isSidebarFrame(_ f: CGRect, in wf: CGRect) -> Bool {
    f.height > wf.height * 0.5 && f.width > 0 && f.width < wf.width * 0.6
}

func findTabStrip(in window: AXUIElement) -> AXUIElement? {
    guard let wf = frame(window) else { return nil }
    var level = [window]
    for _ in 0..<8 {
        var next: [AXUIElement] = []
        for e in level {
            for c in children(e) {
                if isTabStrip(c, windowFrame: wf) { return c }
                if role(c) != "AXWebArea" { next.append(c) }
            }
        }
        level = next
    }
    return nil
}

// MARK: Config

let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ProfileSlide/config.json")
var cachedConfig: [ConfigEntry] = []
var cachedConfigMTime: Date?
var cachedPrefs = AppPreferences()

func preferences() -> AppPreferences { _ = configEntries(); return cachedPrefs }
func shortcutsEnabled() -> Bool { preferences().controlNumberShortcuts }
func arrowShortcutsEnabled() -> Bool { preferences().arrowShortcuts }
func quickSwitcherEnabled() -> Bool { preferences().quickSwitcherEnabled }
func globalQuickSwitcherEnabled() -> Bool { preferences().globalQuickSwitcherEnabled }

func configEntries() -> [ConfigEntry] {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    if mtime == cachedConfigMTime { return cachedConfig }
    cachedOrderedProfiles = nil
    cachedConfigMTime = mtime
    guard let data = try? Data(contentsOf: configURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = json["profiles"] as? [[String: Any]] else {
        cachedConfig = []; cachedPrefs = AppPreferences(); log("config missing or invalid"); return cachedConfig
    }
    cachedPrefs = AppPreferences(json: json)
    cachedConfig = list.compactMap(ConfigEntry.init(json:))
    log("config loaded: \(cachedConfig.count) profiles")
    return cachedConfig
}

func writeDefaultConfig(_ profiles: [Profile]) {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let list = profiles.map { ["dir": $0.dir, "emoji": ""] }
    var payload = AppPreferences().jsonFields
    payload["profiles"] = list
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: configURL, options: .atomic)
        log("wrote default config to \(configURL.path)")
    }
}

// MARK: Profiles

var cachedOrderedProfiles: [Profile]?
var cachedProfiles: [Profile] = []
var cachedProfilesMTime: Date?

func argbColor(_ v: Int?) -> NSColor? {
    guard let v else { return nil }
    let u = UInt32(truncatingIfNeeded: v)
    return NSColor(srgbRed: CGFloat((u >> 16) & 0xff) / 255, green: CGFloat((u >> 8) & 0xff) / 255,
                   blue: CGFloat(u & 0xff) / 255, alpha: 1)
}

private var cachedThemeColors: [String: (mtime: Date?, color: NSColor?)] = [:]

/// The color Chrome themes the profile's windows with, from its Preferences file (cached by mtime).
func themeColor(_ dir: String) -> NSColor? {
    let url = localStateURL.deletingLastPathComponent().appendingPathComponent(dir).appendingPathComponent("Preferences")
    let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    if let cached = cachedThemeColors[dir], cached.mtime == mtime {
        return cached.color
    }
    var resolved: NSColor?
    if let data = try? Data(contentsOf: url),
       let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let browserTheme = (prefs["browser"] as? [String: Any])?["theme"] as? [String: Any]
        if (browserTheme?["is_grayscale2"] as? Bool) != true {
            if let c = ((prefs["autogenerated"] as? [String: Any])?["theme"] as? [String: Any])?["color"] as? Int {
                resolved = argbColor(c)
            } else if let c = browserTheme?["user_color2"] as? Int ?? browserTheme?["user_color"] as? Int {
                resolved = argbColor(c)
            }
        }
    }
    cachedThemeColors[dir] = (mtime, resolved)
    return resolved
}

/// All Chrome profiles in Chrome's own order, re-read when Local State changes.
func loadProfiles() -> [Profile] {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: localStateURL.path))?[.modificationDate] as? Date
    if let mtime, mtime == cachedProfilesMTime { return cachedProfiles }
    guard let data = try? Data(contentsOf: localStateURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profile = json["profile"] as? [String: Any],
          let info = profile["info_cache"] as? [String: [String: Any]] else { return cachedProfiles }
    var order = (profile["profiles_order"] as? [String]) ?? []
    order += info.keys.sorted().filter { !order.contains($0) }
    cachedProfiles = order.compactMap { dir in
        guard let i = info[dir], (i["is_ephemeral"] as? Bool) != true else { return nil }
        let accountName = ["gaia_given_name", "gaia_name", "oidc_identity_name"]
            .compactMap { i[$0] as? String }.first { !$0.isEmpty }
        let enterpriseLabel = i["enterprise_label"] as? String
        return Profile(dir: dir, name: (i["name"] as? String) ?? dir,
                       email: ((i["user_name"] as? String) ?? "").lowercased(), color: themeColor(dir),
                       accountName: accountName, usesDefaultName: i["is_using_default_name"] as? Bool ?? false,
                       enterpriseLabel: enterpriseLabel?.isEmpty == false ? enterpriseLabel : nil)
    }
    cachedOrderedProfiles = nil
    cachedProfilesMTime = mtime
    log("profiles: " + cachedProfiles.map { "\($0.name) (\($0.dir))" }.joined(separator: ", "))
    return cachedProfiles
}

func standardWindows(_ app: AXUIElement) -> [AXUIElement] {
    ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter {
        str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
    }
}

func profileWindows(_ app: AXUIElement, for dir: String, excluding existing: [AXUIElement] = []) -> [AXUIElement] {
    let profiles = loadProfiles()
    return standardWindows(app).filter { window in
        !existing.contains { CFEqual($0, window) } &&
            profileDir(forWindowTitle: str(window, kAXTitleAttribute) ?? "", profiles) == dir
    }
}

/// Profiles in config order first, then Chrome's order.
func orderedProfiles(includeHidden: Bool = false) -> [Profile] {
    let profiles = loadProfiles()
    let entries = configEntries()
    let ordered = cachedOrderedProfiles ?? configure(profiles, with: entries)
    cachedOrderedProfiles = ordered
    return includeHidden ? ordered : ordered.filter { !$0.settings.hidden }
}

struct WindowProfiles {
    var openDirs = Set<String>()
    var focusedDir: String?

    init() {}

    init(app: AXUIElement, focused: AXUIElement?, profiles: [Profile]) {
        for window in standardWindows(app) {
            guard let title = str(window, kAXTitleAttribute),
                  let dir = profileDir(forWindowTitle: title, profiles) else { continue }
            openDirs.insert(dir)
            if let focused, CFEqual(focused, window) { focusedDir = dir }
        }
    }
}

func switchProfile(direction: Int) {
    guard let chrome = chromeApp(), chrome.isActive else { return }
    let focused = element(chromeAX(chrome), kAXFocusedWindowAttribute)
        .flatMap { str($0, kAXTitleAttribute) }
        .flatMap { profileDir(forWindowTitle: $0, loadProfiles()) }
    let profiles = orderedProfiles()
    let pending = OpenPrompt.shared.profile?.dir ?? pendingOpen.activeDir
    guard let index = adjacentProfileIndex(in: profiles, direction: direction,
                                          pending: pending, focused: focused) else { return }
    selectProfile(at: index, in: profiles)
}

/// Manages an in-flight profile window launch with event-driven AX wakeups and a lightweight fallback poll.
final class PendingOpenController {
    private var tracker = PendingOpenTracker()
    private var target: Profile?
    private var app: AXUIElement?
    private var before: [AXUIElement] = []
    private var referenceFrame: CGRect?
    private var showArrivalHUD = true
    private var timer: Timer?

    var activeDir: String? { tracker.activeDir() }

    func shouldSuppressDuplicateOpen(for dir: String, hasExistingWindow: Bool) -> Bool {
        tracker.shouldSuppressDuplicateOpen(for: dir, hasExistingWindow: hasExistingWindow)
    }

    func cancelFocusIfDifferent(than dir: String) {
        tracker.cancelFocusIfDifferent(than: dir)
    }

    func clear(ifDir dir: String? = nil) {
        if dir == nil || tracker.current?.dir == dir {
            timer?.invalidate()
            timer = nil
            tracker.clear()
            target = nil
            app = nil
            before = []
            referenceFrame = nil
            showArrivalHUD = true
        }
    }

    func watch(target: Profile, in app: AXUIElement, excluding before: [AXUIElement],
               referenceFrame: CGRect?, shouldFocus: Bool = true, showArrivalHUD: Bool = true) {
        clear()
        self.target = target
        self.app = app
        self.before = before
        self.referenceFrame = referenceFrame
        self.showArrivalHUD = showArrivalHUD
        tracker.begin(dir: target.dir, timeout: 8.0, shouldFocus: shouldFocus)
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    func checkNow() {
        guard let entry = tracker.current, let app, let target else { return }
        if Date() >= entry.deadline {
            log("timed out waiting for window of \(target.name) (\(target.dir))")
            clear()
            return
        }
        let matches = profileWindows(app, for: entry.dir, excluding: before)
        guard let w = matches.first ?? profileWindows(app, for: entry.dir).first else { return }

        let elapsedMs = Int(Date().timeIntervalSince(entry.startedAt) * 1000)
        let shouldFocus = entry.shouldFocus
        let ref = referenceFrame
        let showHUD = showArrivalHUD
        clear()

        if let ref, preferences().syncWindowFrame, !isFullscreen(w) {
            setWindowFrame(w, to: ref)
        }
        if shouldFocus {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            chromeApp()?.activate()
            if showHUD {
                let visibleProfiles = orderedProfiles()
                var openDirs = WindowProfiles(app: app, focused: w, profiles: orderedProfiles(includeHidden: true)).openDirs
                openDirs.insert(target.dir)
                SwitchHUD.shared.show(profile: target, profiles: visibleProfiles, openDirs: openDirs, over: ref ?? frame(w))
                overlay?.flash(name: target.name)
            }
            MenuBarController.shared.updateButton(focusedProfile: target)
        }
        overlay?.refresh()
        log("opened -> \(target.name) in \(elapsedMs)ms")
    }
}

let pendingOpen = PendingOpenController()

/// Opens a profile directly inside the running Chrome process by invoking its Profiles menu item
/// via Accessibility, avoiding any subprocess spawn or LaunchServices delay.
func openViaChromeProfilesMenu(_ target: Profile, in app: AXUIElement, allProfiles: [Profile]) -> Bool {
    guard let expectedTitle = uniqueProfileMenuTitle(for: target, in: allProfiles),
          let menuBar = element(app, kAXMenuBarAttribute) else { return false }
    let topItems = children(menuBar)
    let knownTitles = Set(allProfiles.map { $0.windowName(in: allProfiles) })

    func submenu(of barItem: AXUIElement) -> AXUIElement? {
        children(barItem).first { role($0) == kAXMenuRole } ?? children(barItem).first
    }

    // Fast path: English Chrome titles the menu "Profiles" (historically "People").
    var candidateMenus: [AXUIElement] = []
    for item in topItems {
        let title = str(item, kAXTitleAttribute) ?? ""
        if title == "Profiles" || title == "People", let menu = submenu(of: item) {
            candidateMenus.append(menu)
        }
    }
    // Locale-independent fallback: find the menu containing known profile titles.
    if candidateMenus.isEmpty {
        let minMatches = min(2, knownTitles.count)
        for item in topItems.dropFirst(2) {
            guard let menu = submenu(of: item) else { continue }
            let count = children(menu).reduce(0) { acc, sub in
                guard let t = str(sub, kAXTitleAttribute), knownTitles.contains(t) else { return acc }
                return acc + 1
            }
            if count >= minMatches {
                candidateMenus.append(menu)
                break
            }
        }
    }

    for menu in candidateMenus {
        let matching = children(menu).filter { item in
            str(item, kAXTitleAttribute) == expectedTitle &&
                (attr(item, kAXEnabledAttribute) as? Bool) != false
        }
        guard matching.count == 1, let item = matching.first else { continue }
        // If already checked (e.g. 0-window edge case where Chrome thinks this profile is active),
        // fall back to launching via executable so Chrome always creates a window.
        let mark = str(item, kAXMenuItemMarkCharAttribute) ?? ""
        guard mark.isEmpty else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
    return false
}

/// Launches a Chrome profile (and optional URLs). When Chrome is already running, invokes Chrome's
/// executable directly so it hands off over Chrome's SingletonSocket without LaunchServices `-n`
/// overhead, Dock bounce, or focus flicker.
@discardableResult
func launchChromeProfile(dir: String, urls: [String] = [], chrome: NSRunningApplication? = chromeApp(),
                         onFailure: (() -> Void)? = nil) -> Bool {
    let p = Process()
    if let chrome, let execURL = chrome.executableURL {
        p.executableURL = execURL
        p.arguments = ["--profile-directory=\(dir)"] + urls
    } else {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", chromeBundleID, "--args", "--profile-directory=\(dir)"] + urls
    }
    p.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    p.standardError = errPipe
    p.terminationHandler = { proc in
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? errPipe.fileHandleForReading.close()
        if proc.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("chrome launch exited \(proc.terminationStatus) for \(dir): \(errText)")
            if let onFailure {
                DispatchQueue.main.async(execute: onFailure)
            }
        }
    }
    do {
        try p.run()
        return true
    } catch {
        log("could not launch Chrome for \(dir): \(error)")
        onFailure?()
        return false
    }
}

func activateProfile(_ target: Profile, ifClosed: ClosedProfileAction = .open, allowLaunchChrome: Bool = false) {
    guard let chrome = chromeApp() else {
        if allowLaunchChrome { openProfileWindow(target) }
        return
    }
    let app = chromeAX(chrome)
    let sourceWindow = element(app, kAXFocusedWindowAttribute)
    let sourceFrame = sourceWindow.flatMap(frame)

    // Windows come front-to-back, so the first match is the most recently used.
    let matches = profileWindows(app, for: target.dir)
    if pendingOpen.shouldSuppressDuplicateOpen(for: target.dir, hasExistingWindow: !matches.isEmpty) {
        log("already opening \(target.name); ignoring duplicate open")
        let visibleProfiles = orderedProfiles()
        var openDirs = openProfileDirs()
        openDirs.insert(target.dir)
        SwitchHUD.shared.show(profile: target, profiles: visibleProfiles, openDirs: openDirs,
                              subtitle: "Opening…", over: sourceFrame)
        return
    }
    let prompt = OpenPrompt.shared
    if matches.isEmpty, case .ask(let shortcut) = ifClosed {
        performSwitchHaptic()
        prompt.show(target, shortcut: shortcut, over: sourceFrame)
        return
    }
    if prompt.isVisible { prompt.dismiss() }
    pendingOpen.cancelFocusIfDifferent(than: target.dir)
    snapshotSessionsIfNeeded() // save the tabs of the profile being left
    SetupGuide.shared.willSwitch(to: target.dir, in: app)
    let visible = matches.first { (attr($0, kAXMinimizedAttribute) as? Bool) != true }
    guard let w = visible ?? matches.first else { openProfileWindow(target); return }
    pendingOpen.clear(ifDir: target.dir)

    let wasMinimized = (attr(w, kAXMinimizedAttribute) as? Bool) == true
    if wasMinimized {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    // Unified Window Mode: match incoming window frame on the same display for an Arc-like single-browser feel.
    let prefs = preferences()
    var hudFrame = frame(w) ?? sourceFrame
    if prefs.syncWindowFrame,
       let srcWin = sourceWindow,
       !CFEqual(srcWin, w),
       let srcFrame = sourceFrame,
       let dstFrame = frame(w),
       shouldSyncWindowFrame(source: srcFrame, target: dstFrame, screens: axScreenRects(),
                             sourceFullscreen: isFullscreen(srcWin), targetFullscreen: isFullscreen(w),
                             targetMinimized: wasMinimized) {
        setWindowFrame(w, to: srcFrame)
        hudFrame = srcFrame
    }

    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    chrome.activate()
    performSwitchHaptic()
    log("switched -> \(target.name)")

    let visibleProfiles = orderedProfiles()
    var openDirs = WindowProfiles(app: app, focused: w, profiles: orderedProfiles(includeHidden: true)).openDirs
    openDirs.insert(target.dir)
    SwitchHUD.shared.show(profile: target, profiles: visibleProfiles, openDirs: openDirs, over: hudFrame)
    overlay?.flash(name: target.name)
    MenuBarController.shared.updateButton(focusedProfile: target)
}

func alignNewWindow(in app: AXUIElement, for target: Profile, excluding before: [AXUIElement],
                    to ref: CGRect?, showArrivalHUD: Bool = true) {
    pendingOpen.watch(target: target, in: app, excluding: before, referenceFrame: ref,
                      shouldFocus: true, showArrivalHUD: showArrivalHUD)
}

/// Opens a window for a profile with none, then aligns and focuses it.
func openProfileWindow(_ target: Profile) {
    let chrome = chromeApp()
    let app = chrome.map(chromeAX)
    let sourceWindow = app.flatMap { element($0, kAXFocusedWindowAttribute) }
    let sourceFrame = sourceWindow.flatMap(frame)
    let sourceFullscreen = sourceWindow.map(isFullscreen) ?? false
    let alignTarget = (preferences().syncWindowFrame && !sourceFullscreen) ? sourceFrame : nil
    let allProfiles = orderedProfiles(includeHidden: true)
    let before = app.map(standardWindows) ?? []
    let urls = launchURLs(for: target)

    if let app {
        pendingOpen.watch(target: target, in: app, excluding: before, referenceFrame: alignTarget, shouldFocus: true)
    }

    var openedViaMenu = false
    if let app, urls.isEmpty {
        openedViaMenu = openViaChromeProfilesMenu(target, in: app, allProfiles: allProfiles)
    }
    if !openedViaMenu {
        if !urls.isEmpty { log("  with \(urls.count) tab(s) (\(target.settings.opens.rawValue))") }
        let ok = launchChromeProfile(dir: target.dir, urls: urls, chrome: chrome) {
            pendingOpen.clear(ifDir: target.dir)
        }
        guard ok else { return }
    }

    performSwitchHaptic()
    log("opening window for \(target.name) (\(target.dir)) via \(openedViaMenu ? "Profiles menu" : (chrome != nil ? "Chrome executable" : "open"))")

    let visibleProfiles = allProfiles.filter { !$0.settings.hidden }
    var openDirs = Set(before.compactMap { w in
        str(w, kAXTitleAttribute).flatMap { profileDir(forWindowTitle: $0, allProfiles) }
    })
    openDirs.insert(target.dir)
    SwitchHUD.shared.show(profile: target, profiles: visibleProfiles, openDirs: openDirs,
                          subtitle: urls.isEmpty ? "Opening…" : "Opening \(urls.count) tab\(urls.count == 1 ? "" : "s")…",
                          over: sourceFrame)
    overlay?.flash(name: target.name)
    MenuBarController.shared.updateButton(focusedProfile: target)
}

// MARK: Sidebar hit test

func isOverSidebar(_ p: CGPoint, chromePid: pid_t) -> Bool {
    // Fast-path bounds check against cached AX geometry avoids AX IPC on 95%+ of page scrolls.
    if let winFrame = overlay?.lastWindowFrame, !winFrame.contains(p) {
        return false
    }
    if let sidebar = overlay?.lastSidebarFrame, !sidebar.insetBy(dx: -4, dy: -4).contains(p) {
        return false
    }

    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success,
          let start = hit else { return false }
    var pid: pid_t = 0
    AXUIElementGetPid(start, &pid)
    guard pid == chromePid else { return false }

    var chain: [AXUIElement] = []
    var cur: AXUIElement? = start
    while let e = cur, chain.count < 40 {
        chain.append(e)
        if role(e) == kAXWindowRole { break }
        cur = element(e, kAXParentAttribute)
    }
    guard let win = chain.last, role(win) == kAXWindowRole, let wf = frame(win) else { return false }
    let roles = chain.compactMap(role)
    if roles.contains("AXWebArea") || roles.contains("AXTextField") { return false }
    let yes = chain.contains { isTabStrip($0, windowFrame: wf) }
    log("hit-test \(Int(p.x)),\(Int(p.y)) -> \(yes ? "sidebar" : "not sidebar")")
    return yes
}

// MARK: Overlay (profile dots)

var emojiImages: [String: NSImage] = [:]
private let emojiCIContext = CIContext(options: [.useSoftwareRenderer: false])

/// Renders an emoji at crisp 2x Retina resolution, optionally desaturated (for closed profiles).
func emojiImage(_ e: String, size: CGFloat, gray: Bool) -> NSImage {
    let key = "\(e)|\(size)|\(gray)"
    if let img = emojiImages[key] { return img }
    let s = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: size)])
    let rawSize = s.size()
    let sz = NSSize(width: ceil(rawSize.width) + 2, height: ceil(rawSize.height) + 2)
    let scale: CGFloat = 2
    let pxW = max(1, Int(ceil(sz.width * scale)))
    let pxH = max(1, Int(ceil(sz.height * scale)))

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        let fallback = NSImage(size: sz, flipped: false) { r in s.draw(in: r); return true }
        emojiImages[key] = fallback
        return fallback
    }
    rep.size = sz
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        s.draw(at: NSPoint(x: (sz.width - rawSize.width) / 2, y: (sz.height - rawSize.height) / 2))
    }
    NSGraphicsContext.restoreGraphicsState()

    var img = NSImage(size: sz)
    img.addRepresentation(rep)

    if gray, let ci = CIImage(bitmapImageRep: rep),
       let f = CIFilter(name: "CIColorControls") {
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(0, forKey: kCIInputSaturationKey)
        if let out = f.outputImage, let cg = emojiCIContext.createCGImage(out, from: ci.extent) {
            img = NSImage(cgImage: cg, size: sz)
        }
    }
    emojiImages[key] = img
    return img
}

private final class DotsCanvasView: NSView {
    var onDraw: ((NSRect) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { onDraw?(dirtyRect) }
}

final class DotsView: NSView {
    private struct Dot: Equatable {
        let color: NSColor?
        let emoji: String
        let isOpen: Bool
        let active: Bool
    }
    private var profiles: [Profile] = []
    private var dots: [Dot] = []
    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { canvas.needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private let pillBackdrop = NSVisualEffectView()
    private let canvas = DotsCanvasView()
    var swipeProgress: Double = 0 {
        didSet {
            if abs(swipeProgress - oldValue) > 0.01 {
                updateBackdropFrame()
                canvas.needsDisplay = true
            }
        }
    }
    var label: String? { didSet { if label != oldValue { canvas.needsDisplay = true } } }

    let dot: CGFloat = 7, activeDot: CGFloat = 9, maxSpacing: CGFloat = 24
    let pillBottom: CGFloat = 2
    let pillHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pillBackdrop.material = .popover
        pillBackdrop.blendingMode = .behindWindow
        pillBackdrop.state = .active
        pillBackdrop.wantsLayer = true
        pillBackdrop.layer?.cornerRadius = pillHeight / 2
        pillBackdrop.layer?.masksToBounds = true
        pillBackdrop.layer?.borderWidth = 0.5
        pillBackdrop.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        addSubview(pillBackdrop)

        canvas.autoresizingMask = [.width, .height]
        canvas.frame = bounds
        canvas.onDraw = { [weak self] rect in self?.drawDots(rect) }
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        updateBackdropFrame()
    }

    func update(_ profiles: [Profile], windows: WindowProfiles) {
        self.profiles = profiles // click targets track configuration even when the dots look identical
        let next = profiles.map {
            Dot(color: $0.color, emoji: $0.settings.emoji,
                isOpen: windows.openDirs.contains($0.dir), active: windows.focusedDir == $0.dir)
        }
        if let h = hoveredIndex, !profiles.indices.contains(h) { hoveredIndex = nil }
        updateBackdropFrame()
        if dots != next { dots = next; canvas.needsDisplay = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private var effectiveSpacing: CGFloat {
        guard !profiles.isEmpty else { return maxSpacing }
        return min(maxSpacing, max(16, (bounds.width - 20) / CGFloat(profiles.count)))
    }

    private func pillRect() -> CGRect {
        let sp = effectiveSpacing
        let contentWidth = CGFloat(profiles.count) * sp
        let width = min(bounds.width - 4, contentWidth + 14)
        let swipeOffset = CGFloat(swipeProgress) * 8
        let x = max(2, min(bounds.width - width - 2, (bounds.width - width) / 2 + swipeOffset))
        return CGRect(x: x, y: pillBottom, width: max(0, width), height: pillHeight)
    }

    private func updateBackdropFrame() {
        pillBackdrop.isHidden = profiles.isEmpty
        if !profiles.isEmpty {
            pillBackdrop.frame = pillRect()
            pillBackdrop.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor
        }
    }

    private func dotCenters() -> [CGPoint] {
        let sp = effectiveSpacing
        let total = CGFloat(profiles.count) * sp
        let pr = pillRect()
        let x0 = pr.midX - total / 2 + sp / 2
        let cy = pillBottom + pillHeight / 2
        return profiles.indices.map { CGPoint(x: x0 + CGFloat($0) * sp, y: cy) }
    }

    private func dotIndex(at point: CGPoint) -> Int? {
        let half = effectiveSpacing / 2
        return dotCenters().firstIndex(where: {
            abs($0.x - point.x) < half && point.y >= pillBottom && point.y <= pillBottom + pillHeight
        })
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredIndex = dotIndex(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    private var displayedLabel: String? {
        if let h = hoveredIndex, profiles.indices.contains(h), dots.indices.contains(h) {
            let p = profiles[h]
            let isOpen = dots[h].isOpen || dots[h].active
            if NSEvent.modifierFlags.contains(.option), !dots[h].active {
                return "Move tab → \(p.name)"
            }
            var parts = [p.name]
            if preferences().controlNumberShortcuts && h < 9 {
                parts.append("⌃\(h + 1)")
            }
            if !isOpen { parts.append("closed") }
            return parts.joined(separator: " · ")
        }
        return label
    }

    private func drawDots(_ dirtyRect: NSRect) {
        let centers = dotCenters()
        for (i, c) in centers.enumerated() where i < dots.count {
            let active = dots[i].active, isOpen = dots[i].isOpen
            let hovered = hoveredIndex == i
            let tintColor = dots[i].color ?? NSColor.controlAccentColor

            if active {
                let halo = CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)
                let bg = NSBezierPath(ovalIn: halo)
                tintColor.withAlphaComponent(0.18).setFill()
                bg.fill()
                tintColor.withAlphaComponent(0.32).setStroke()
                bg.lineWidth = 0.75
                bg.stroke()
            } else if hovered {
                let halo = CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)
                let bg = NSBezierPath(ovalIn: halo)
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
                bg.fill()
            }

            if !dots[i].emoji.isEmpty {
                let size: CGFloat = active ? 14.5 : (hovered ? 13.5 : 12.5)
                let img = emojiImage(dots[i].emoji, size: size, gray: !isOpen && !active && !hovered)
                let sz = img.size
                let alpha: CGFloat = active ? 1 : (hovered ? 0.95 : (isOpen ? 0.68 : 0.45))
                img.draw(in: CGRect(x: round(c.x - sz.width / 2), y: round(c.y - sz.height / 2),
                                    width: sz.width, height: sz.height),
                         from: .zero, operation: .sourceOver, fraction: alpha)
                continue
            }
            let d = active ? activeDot : (hovered ? dot + 1.5 : dot)
            let color = dots[i].color ?? NSColor.labelColor
            let path = NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            if isOpen || active {
                (active ? color : color.withAlphaComponent(hovered ? 0.85 : 0.45)).setFill(); path.fill()
            } else {
                (hovered ? color.withAlphaComponent(0.85) : NSColor.systemGray.withAlphaComponent(0.6)).setStroke()
                path.lineWidth = hovered ? 1.4 : 1
                path.stroke()
            }
        }
        if let text = displayedLabel, !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.9),
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            let padX: CGFloat = 8, padY: CGFloat = 2.5
            let pillW = min(bounds.width - 4, sz.width + padX * 2)
            let pillH = sz.height + padY * 2
            let tipRect = CGRect(x: (bounds.width - pillW) / 2, y: pillBottom + pillHeight + 4, width: pillW, height: pillH)
            let bg = NSBezierPath(roundedRect: tipRect, xRadius: pillH / 2, yRadius: pillH / 2)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            bg.fill()
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            bg.lineWidth = 0.5
            bg.stroke()
            let textRect = CGRect(x: tipRect.minX + padX, y: tipRect.minY + padY,
                                  width: tipRect.width - padX * 2, height: sz.height)
            s.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let i = dotIndex(at: p), profiles.indices.contains(i), dots.indices.contains(i) {
            let target = profiles[i]
            let dotState = dots[i]
            let switchItem = menu.addItem(
                withTitle: dotState.isOpen ? "Switch to \(target.name)" : "Open \(target.name)",
                action: #selector(contextSwitchProfile(_:)), keyEquivalent: "")
            switchItem.target = self; switchItem.representedObject = target.dir

            if !dotState.active {
                let moveItem = menu.addItem(
                    withTitle: "Move Current Tab to \(target.name)",
                    action: #selector(contextMoveTab(_:)), keyEquivalent: "")
                moveItem.target = self; moveItem.representedObject = target.dir
            }
            if dotState.isOpen {
                let sleepItem = menu.addItem(
                    withTitle: "Sleep \(target.name) (Save & Close)",
                    action: #selector(contextSleepProfile(_:)), keyEquivalent: "")
                sleepItem.target = self; sleepItem.representedObject = target.dir
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Quick Switcher…", action: #selector(openQuickSwitcher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appDisplayName)", action: #selector(quit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func contextSwitchProfile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let p = profiles.first(where: { $0.dir == dir }) else { return }
        activateProfile(p)
    }

    @objc func contextMoveTab(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let p = profiles.first(where: { $0.dir == dir }) else { return }
        moveCurrentTab(to: p)
    }

    @objc func contextSleepProfile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let p = profiles.first(where: { $0.dir == dir }) else { return }
        sleepProfile(p)
    }

    @objc func openQuickSwitcher() { QuickSwitcher.shared.show(global: false) }
    @objc func openSettings() { showSettings() }
    @objc func quit() { quitCompletely() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = dotIndex(at: p), profiles.indices.contains(i) else { return }
        if event.modifierFlags.contains(.option), dots.indices.contains(i), !dots[i].active {
            moveCurrentTab(to: profiles[i])
        } else {
            activateProfile(profiles[i])
        }
    }
}

private func overlayAXCallback(_ observer: AXObserver, _ element: AXUIElement,
                               _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let overlay = Unmanaged<Overlay>.fromOpaque(refcon).takeUnretainedValue()
    overlay.scheduleRefresh()
}

final class Overlay {
    static let minimumDotsWidth: CGFloat = 84
    let panel: NSPanel
    let view = DotsView()
    var timer: Timer?
    var window: AXUIElement?
    var tabStrip: AXUIElement?
    private var bottomButton: AXUIElement?
    private(set) var lastSidebarFrame: CGRect?
    private(set) var lastWindowFrame: CGRect?
    private var axObserver: AXObserver?
    private var observedPid: pid_t = 0
    private var observedWindow: AXUIElement?
    private var refreshScheduled = false
    private var nextLookup: TimeInterval = 0
    private var retryDelay: TimeInterval = 0.25
    private(set) var sidebarMissing = false {
        didSet { if sidebarMissing != oldValue { settingsModel?.sidebarMissing = sidebarMissing } }
    }
    var labelUntil = Date.distantPast

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = view

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.chromeActivityChanged()
        }
        chromeActivityChanged()
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            pendingOpen.checkNow()
            self.refresh()
        }
    }

    private func installObserver(for pid: pid_t) {
        if observedPid == pid && axObserver != nil { return }
        teardownObserver()
        var obs: AXObserver?
        guard AXObserverCreate(pid, overlayAXCallback, &obs) == .success, let obs else { return }
        let appElem = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appNotes: [String] = [
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]
        for note in appNotes {
            AXObserverAddNotification(obs, appElem, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        axObserver = obs
        observedPid = pid
    }

    private func observeWindow(_ w: AXUIElement) {
        guard let obs = axObserver else { return }
        if let prev = observedWindow, CFEqual(prev, w) { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let winNotes: [String] = [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification,
            kAXUIElementDestroyedNotification,
        ]
        if let prev = observedWindow {
            for note in winNotes { AXObserverRemoveNotification(obs, prev, note as CFString) }
        }
        for note in winNotes {
            AXObserverAddNotification(obs, w, note as CFString, refcon)
        }
        observedWindow = w
    }

    private func teardownObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        axObserver = nil
        observedPid = 0
        observedWindow = nil
    }

    func chromeActivityChanged() {
        if let chrome = chromeApp(), chrome.isActive {
            installObserver(for: chrome.processIdentifier)
            if timer == nil {
                // Lightweight fallback heartbeat for sidebar drag-resizes Chrome doesn't emit window AX events for.
                timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.refresh() }
            }
            refresh()
        } else {
            gesture = ScrollGesture()
            view.swipeProgress = 0
            window = nil
            lastSidebarFrame = nil
            lastWindowFrame = nil
            teardownObserver()
            timer?.invalidate(); timer = nil
            panel.orderOut(nil)
            if OpenPrompt.shared.isVisible { OpenPrompt.shared.dismiss() }
            MenuBarController.shared.updateButton()
        }
    }

    func flash(name: String) {
        labelUntil = Date().addingTimeInterval(1.2)
        view.label = name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.refresh() }
    }

    func setSwipeProgress(_ progress: Double) {
        view.swipeProgress = progress
    }

    /// Finds Chrome's bottom-pinned New Tab (`+`) button inside the vertical tab strip so
    /// the profile dots dock cleanly above it instead of overlapping it.
    private func findBottomButton(in strip: AXUIElement, sidebarFrame f: CGRect) -> AXUIElement? {
        var level = [strip]
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for e in level {
                for c in children(e) {
                    let r = role(c)
                    if r == "AXButton", let bf = frame(c),
                       bf.maxY > f.maxY - 64 && bf.minY > f.maxY - 96 && bf.height > 12 && bf.height < 60 {
                        return c
                    }
                    if r != "AXScrollArea" && r != "AXWebArea" { next.append(c) }
                }
            }
            level = next
        }
        return nil
    }

    private func bottomAnchorMaxY(in strip: AXUIElement, sidebarFrame f: CGRect) -> CGFloat {
        if let b = bottomButton, let bf = frame(b),
           bf.maxY > f.maxY - 64 && bf.minY > f.maxY - 96 && bf.height > 12 && bf.height < 60 {
            return bf.minY - 8
        }
        bottomButton = findBottomButton(in: strip, sidebarFrame: f)
        if let b = bottomButton, let bf = frame(b) {
            return bf.minY - 8
        }
        return f.maxY - 10
    }

    func sidebarFrame(in w: AXUIElement) -> CGRect? {
        if window == nil || !CFEqual(window, w) {
            window = w
            tabStrip = nil
            bottomButton = nil
            nextLookup = 0
            retryDelay = 0.25
        }
        if let t = tabStrip, let f = frame(t), let wf = frame(w), isSidebarFrame(f, in: wf) {
            return f
        }
        tabStrip = nil
        bottomButton = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextLookup else { return nil }
        if let t = findTabStrip(in: w), let f = frame(t) {
            tabStrip = t
            bottomButton = findBottomButton(in: t, sidebarFrame: f)
            retryDelay = 0.25
            nextLookup = 0
            return f
        }
        nextLookup = now + retryDelay
        retryDelay = min(4, retryDelay * 2)
        return nil
    }

    func refresh() {
        guard let chrome = chromeApp(), chrome.isActive else { panel.orderOut(nil); return }
        installObserver(for: chrome.processIdentifier)
        let app = chromeAX(chrome)
        guard let w = element(app, kAXFocusedWindowAttribute) else {
            window = nil
            lastSidebarFrame = nil
            lastWindowFrame = nil
            sidebarMissing = false
            panel.orderOut(nil)
            return
        }
        observeWindow(w)
        lastWindowFrame = frame(w)
        let sidebar = sidebarFrame(in: w)
        lastSidebarFrame = sidebar
        sidebarMissing = sidebar == nil
        guard let f = sidebar, f.width > Self.minimumDotsWidth else { panel.orderOut(nil); return }

        let all = orderedProfiles(includeHidden: true)
        let visible = all.filter { !$0.settings.hidden }
        guard visible.count > 1 else { panel.orderOut(nil); return }
        let wp = WindowProfiles(app: app, focused: w, profiles: all)
        view.update(visible, windows: wp)
        if let focusedDir = wp.focusedDir, let fp = all.first(where: { $0.dir == focusedDir }) {
            MenuBarController.shared.updateButton(focusedProfile: fp)
        }
        if Date() > labelUntil { view.label = SetupGuide.shared.dotsHint }

        // AX uses top-left origin on the primary screen; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let anchorMaxY = tabStrip.map { bottomAnchorMaxY(in: $0, sidebarFrame: f) } ?? (f.maxY - 10)
        let width = min(f.width - 12, 260), height: CGFloat = 56
        let rect = CGRect(x: f.midX - width / 2, y: primaryHeight - anchorMaxY, width: width, height: height)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

// MARK: Gesture tracking

var gesture = ScrollGesture()
var tap: CFMachPort?

func handleScroll(_ event: CGEvent) -> CGEvent? {
    guard let chrome = chromeApp(), chrome.isActive else {
        gesture = ScrollGesture()
        overlay?.setSwipeProgress(0)
        return event
    }
    let prefs = preferences()
    let action = gesture.handle(phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                                momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                                dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                                dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                                threshold: prefs.swipeSensitivity.threshold,
                                reversed: prefs.reverseSwipe,
                                overSidebar: isOverSidebar(event.location, chromePid: chrome.processIdentifier))
    overlay?.setSwipeProgress(gesture.progress)
    switch action {
    case .pass: return event
    case .suppress: return nil
    case .switchProfile(let direction):
        overlay?.setSwipeProgress(0)
        enqueueProfileSelection { switchProfile(direction: direction) }
        return nil
    }
}

func installTap() {
    let events: [CGEventType] = [.scrollWheel, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gesture = ScrollGesture()
            overlay?.setSwipeProgress(0)
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            log("tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return Unmanaged.passUnretained(event)
        }
        let result: CGEvent?
        switch type {
        case .keyDown: result = handleKey(event)
        case .scrollWheel: result = handleScroll(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: result = handleMouseDown(event)
        default: result = event
        }
        guard let out = result else { return nil }
        return Unmanaged.passUnretained(out)
    }, userInfo: nil)
    guard let tap else { log("ERROR: could not create event tap"); return }
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("event tap installed; swipe sidebar, press ⌃1–⌃9, ⌃←/⌃→, or ⌃Space / ⌥⌃Space")
}

// MARK: Main

// Settings from before the rename to ProfileSlide.
let legacySupportDir = appSupportDir.deletingLastPathComponent().appendingPathComponent("ChromeProfileSwipe")
if !FileManager.default.fileExists(atPath: appSupportDir.path) {
    try? FileManager.default.moveItem(at: legacySupportDir, to: appSupportDir)
}
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
AXUIElementSetMessagingTimeout(systemWide, 0.15)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
log("started pid \(ProcessInfo.processInfo.processIdentifier)")

var overlay: Overlay!

func quitCompletely() { NSApp.terminate(nil) }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isSnapshot else { return }
        let guide = SetupGuide.shared
        if AXIsProcessTrusted() {
            start()
        } else {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                start()
                guide.permissionGranted()
            }
        }
        if guide.isFirstPresentation { guide.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let guide = SetupGuide.shared
        if guide.window != nil || guide.isFirstPresentation { guide.show() } else { showSettings() }
        return true
    }

    @objc func hideToBackground() {
        settingsWindow?.close()
        SetupGuide.shared.window?.close()
    }
}

func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About \(appDisplayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide to Background", action: #selector(AppDelegate.hideToBackground), keyEquivalent: "q").target = appDelegate
    let quit = NSMenuItem(title: "Quit \(appDisplayName) Completely", action: #selector(AppDelegate.quitFromMenu), keyEquivalent: "q")
    quit.keyEquivalentModifierMask = [.command, .option]
    quit.target = appDelegate
    appMenu.addItem(quit)
    appItem.submenu = appMenu

    let editItem = NSMenuItem(); main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    let emoji = edit.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
    emoji.keyEquivalentModifierMask = [.command, .control]
    editItem.submenu = edit

    let windowItem = NSMenuItem(); main.addItem(windowItem)
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = window
    NSApp.mainMenu = main
}

extension AppDelegate {
    @objc func quitFromMenu() { quitCompletely() }
}
let appDelegate = AppDelegate()
app.delegate = appDelegate
installMainMenu()

func start() {
    settingsModel?.accessibilityAllowed = true
    writeDefaultConfig(loadProfiles())
    overlay = Overlay()
    installTap()
    startSessionSnapshots()
    MenuBarController.shared.syncVisibility()
}

let args = CommandLine.arguments
let snapshotIndex = args.firstIndex(where: { $0.hasPrefix("--snapshot-") })
let isSnapshot = snapshotIndex != nil
if let i = snapshotIndex, i + 1 < args.count {
    snapshot(String(args[i].dropFirst("--snapshot-".count)), to: args[i + 1])
}
app.run()
