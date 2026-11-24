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
    AXUIElementCreateApplication(chrome.processIdentifier)
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

/// The color Chrome themes the profile's windows with, from its Preferences file.
func themeColor(_ dir: String) -> NSColor? {
    let url = localStateURL.deletingLastPathComponent().appendingPathComponent(dir).appendingPathComponent("Preferences")
    guard let data = try? Data(contentsOf: url),
          let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let browserTheme = (prefs["browser"] as? [String: Any])?["theme"] as? [String: Any]
    if (browserTheme?["is_grayscale2"] as? Bool) == true { return nil }
    if let c = ((prefs["autogenerated"] as? [String: Any])?["theme"] as? [String: Any])?["color"] as? Int { return argbColor(c) }
    if let c = browserTheme?["user_color2"] as? Int ?? browserTheme?["user_color"] as? Int { return argbColor(c) }
    return nil
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
    guard let index = adjacentProfileIndex(in: profiles, direction: direction,
                                          pending: OpenPrompt.shared.profile?.dir, focused: focused) else { return }
    selectProfile(at: index, in: profiles)
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
    let prompt = OpenPrompt.shared
    if matches.isEmpty, case .ask(let shortcut) = ifClosed {
        performSwitchHaptic()
        prompt.show(target, shortcut: shortcut, over: sourceFrame)
        return
    }
    if prompt.isVisible { prompt.dismiss() }
    snapshotSessionsIfNeeded() // save the tabs of the profile being left
    SetupGuide.shared.willSwitch(to: target.dir, in: app)
    let visible = matches.first { (attr($0, kAXMinimizedAttribute) as? Bool) != true }
    guard let w = visible ?? matches.first else { openProfileWindow(target); return }

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

func alignNewWindow(in app: AXUIElement, for dir: String, excluding before: [AXUIElement], to ref: CGRect) {
    var tries = 0
    Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { t in
        tries += 1
        if let w = profileWindows(app, for: dir, excluding: before).first {
            setWindowFrame(w, to: ref)
            overlay?.refresh()
            t.invalidate()
        } else if tries > 60 {
            t.invalidate()
        }
    }
}

/// Opens a window for a profile with none, then gives it the current window's frame.
func openProfileWindow(_ target: Profile) {
    let chrome = chromeApp()
    let app = chrome.map(chromeAX)
    let reference = app.flatMap { element($0, kAXFocusedWindowAttribute).flatMap(frame) }
    let before = app.map(standardWindows) ?? []
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let urls = launchURLs(for: target)
    p.arguments = ["-nb", chromeBundleID, "--args", "--profile-directory=\(target.dir)"] + urls
    if !urls.isEmpty { log("  with \(urls.count) tab(s) (\(target.settings.opens.rawValue))") }
    do { try p.run() } catch { log("could not open \(target.dir): \(error)"); return }
    performSwitchHaptic()
    log("opening window for \(target.name) (\(target.dir))")

    let visibleProfiles = orderedProfiles()
    var openDirs = openProfileDirs()
    openDirs.insert(target.dir)
    SwitchHUD.shared.show(profile: target, profiles: visibleProfiles, openDirs: openDirs,
                          subtitle: urls.isEmpty ? "Opening…" : "Opening \(urls.count) tab\(urls.count == 1 ? "" : "s")…",
                          over: reference)
    overlay?.flash(name: target.name)
    MenuBarController.shared.updateButton(focusedProfile: target)
    guard let app, let ref = reference else { return }
    alignNewWindow(in: app, for: target.dir, excluding: before, to: ref)
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

/// Renders an emoji to an image, optionally desaturated (for closed profiles).
func emojiImage(_ e: String, size: CGFloat, gray: Bool) -> NSImage {
    let key = "\(e)|\(size)|\(gray)"
    if let img = emojiImages[key] { return img }
    let s = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: size)])
    let sz = s.size()
    var img = NSImage(size: sz, flipped: false) { r in s.draw(in: r); return true }
    if gray, let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff),
       let f = CIFilter(name: "CIColorControls") {
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(0, forKey: kCIInputSaturationKey)
        if let out = f.outputImage {
            let rep = NSCIImageRep(ciImage: out)
            let g = NSImage(size: sz); g.addRepresentation(rep); img = g
        }
    }
    emojiImages[key] = img
    return img
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
    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    var swipeProgress: Double = 0 { didSet { if abs(swipeProgress - oldValue) > 0.01 { needsDisplay = true } } }
    var label: String? { didSet { if label != oldValue { needsDisplay = true } } }

    func update(_ profiles: [Profile], windows: WindowProfiles) {
        self.profiles = profiles // click targets track configuration even when the dots look identical
        let next = profiles.map {
            Dot(color: $0.color, emoji: $0.settings.emoji,
                isOpen: windows.openDirs.contains($0.dir), active: windows.focusedDir == $0.dir)
        }
        if let h = hoveredIndex, !profiles.indices.contains(h) { hoveredIndex = nil }
        if dots != next { dots = next; needsDisplay = true }
    }

    let dot: CGFloat = 7, activeDot: CGFloat = 9, maxSpacing: CGFloat = 22
    let dotsHeight: CGFloat = 24

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
        return min(maxSpacing, max(14, (bounds.width - 12) / CGFloat(profiles.count)))
    }

    private func dotCenters() -> [CGPoint] {
        let sp = effectiveSpacing
        let total = CGFloat(profiles.count) * sp
        let swipeOffset = CGFloat(swipeProgress) * 10
        let x0 = (bounds.width - total) / 2 + sp / 2 + swipeOffset
        return profiles.indices.map { CGPoint(x: x0 + CGFloat($0) * sp, y: dotsHeight / 2) }
    }

    private func dotIndex(at point: CGPoint) -> Int? {
        let half = effectiveSpacing / 2
        return dotCenters().firstIndex(where: { abs($0.x - point.x) < half && point.y >= 0 && point.y <= dotsHeight })
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

    override func draw(_ dirtyRect: NSRect) {
        let centers = dotCenters()
        for (i, c) in centers.enumerated() where i < dots.count {
            let active = dots[i].active, isOpen = dots[i].isOpen
            let hovered = hoveredIndex == i
            if hovered {
                let pillRect = CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)
                let pill = NSBezierPath(roundedRect: pillRect, xRadius: 7, yRadius: 7)
                let tint = (dots[i].color ?? NSColor.labelColor).withAlphaComponent(0.16)
                tint.setFill()
                pill.fill()
            }
            if !dots[i].emoji.isEmpty {
                let size: CGFloat = active ? 15 : (hovered ? 14 : 12)
                let img = emojiImage(dots[i].emoji, size: size, gray: !isOpen && !active && !hovered)
                let sz = img.size
                let alpha: CGFloat = active ? 1 : (hovered ? 0.92 : (isOpen ? 0.58 : 0.4))
                img.draw(in: CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height),
                         from: .zero, operation: .sourceOver, fraction: alpha)
                continue
            }
            let d = active ? activeDot : (hovered ? dot + 1.5 : dot)
            let color = dots[i].color ?? NSColor.labelColor
            let path = NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            if isOpen || active {
                (active ? color : color.withAlphaComponent(hovered ? 0.85 : 0.42)).setFill(); path.fill()
            } else {
                (hovered ? color.withAlphaComponent(0.85) : NSColor.systemGray.withAlphaComponent(0.6)).setStroke()
                path.lineWidth = hovered ? 1.4 : 1
                path.stroke()
            }
        }
        if let text = displayedLabel, !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88),
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            let padX: CGFloat = 7, padY: CGFloat = 2
            let pillW = min(bounds.width - 4, sz.width + padX * 2)
            let pillH = sz.height + padY * 2
            let pillRect = CGRect(x: (bounds.width - pillW) / 2, y: dotsHeight + 1, width: pillW, height: pillH)
            let bg = NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2)
            NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
            bg.fill()
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            bg.lineWidth = 0.5
            bg.stroke()
            let textRect = CGRect(x: pillRect.minX + padX, y: pillRect.minY + padY,
                                  width: pillRect.width - padX * 2, height: sz.height)
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
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 46),
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

    func sidebarFrame(in w: AXUIElement) -> CGRect? {
        if window == nil || !CFEqual(window, w) {
            window = w
            tabStrip = nil
            nextLookup = 0
            retryDelay = 0.25
        }
        if let t = tabStrip, let f = frame(t), let wf = frame(w), isSidebarFrame(f, in: wf) {
            return f
        }
        tabStrip = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextLookup else { return nil }
        if let t = findTabStrip(in: w), let f = frame(t) {
            tabStrip = t
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
        let width = min(f.width - 12, 260), height: CGFloat = 46
        let rect = CGRect(x: f.midX - width / 2, y: primaryHeight - f.maxY + 8, width: width, height: height)
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
