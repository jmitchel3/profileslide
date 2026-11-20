// Proof of concept: horizontal two-finger swipe over Chrome's vertical tab
// sidebar switches to the next/previous Chrome window (across profiles).
// Runs as a background app (no Dock icon, no menu bar item).
// Logs to ~/Library/Logs/ChromeProfileSwipe/poc.log

import Cocoa
import ApplicationServices

let chromeBundleID = "com.google.Chrome"
let swipeThreshold: Double = 40      // points of horizontal travel before a switch fires
let horizontalDominance: Double = 2  // |dx| must exceed this multiple of |dy|

// MARK: Logging

let logDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/ChromeProfileSwipe")
let logURL = logDir.appendingPathComponent("poc.log")
let dumpURL = logDir.appendingPathComponent("ax-dump.txt")
let stamp = ISO8601DateFormatter()

func log(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
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

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func describe(_ e: AXUIElement) -> String {
    var out = str(e, kAXRoleAttribute) ?? "?"
    if let v = str(e, kAXSubroleAttribute), !v.isEmpty { out += "/\(v)" }
    if let v = str(e, kAXDescriptionAttribute), !v.isEmpty { out += " desc=\"\(v.prefix(40))\"" }
    if let v = str(e, kAXTitleAttribute), !v.isEmpty { out += " title=\"\(v.prefix(40))\"" }
    if let f = frame(e) { out += " [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]" }
    return out
}

func dumpTree(_ root: AXUIElement) -> String {
    var lines: [String] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        if lines.count > 600 || depth > 16 { return }
        lines.append(String(repeating: "  ", count: depth) + describe(e))
        if str(e, kAXRoleAttribute) == "AXWebArea" { return }
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
    }
    walk(root, 0)
    return lines.joined(separator: "\n")
}

func chromeApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).first
}

// MARK: Sidebar detection

/// True when the point is over Chrome's sidebar: not web content, not a text
/// field, and inside a tall, narrow container on the left of the window.
func isOverSidebar(_ p: CGPoint, chromePid: pid_t) -> Bool {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success,
          let start = hit else { log("hit-test: nothing at \(p)"); return false }
    var pid: pid_t = 0
    AXUIElementGetPid(start, &pid)
    guard pid == chromePid else { return false }

    var chain: [AXUIElement] = []
    var cur: AXUIElement? = start
    var window: AXUIElement?
    while let e = cur, chain.count < 40 {
        chain.append(e)
        if str(e, kAXRoleAttribute) == kAXWindowRole { window = e; break }
        cur = element(e, kAXParentAttribute)
    }
    let roles = chain.compactMap { str($0, kAXRoleAttribute) }
    log("hit-test at \(Int(p.x)),\(Int(p.y)):\n    " + chain.map(describe).joined(separator: "\n    "))

    if roles.contains("AXWebArea") || roles.contains("AXTextField") || roles.contains("AXToolbar") {
        log("  -> not sidebar (web/text/toolbar)"); return false
    }
    guard let win = window, let wf = frame(win) else { log("  -> not sidebar (no window)"); return false }
    let tallNarrow = chain.dropLast().contains { e in
        guard let f = frame(e) else { return false }
        return f.width < wf.width * 0.5 && f.height > wf.height * 0.6 && f.minX - wf.minX < 40
    }
    log("  -> \(tallNarrow ? "SIDEBAR" : "not sidebar (no tall narrow left container)")")
    return tallNarrow
}

// MARK: Window switching

func profileName(_ title: String) -> String {
    // Chrome appends " - <Profile>" after "Google Chrome" when several profiles exist.
    if let r = title.range(of: " - Google Chrome - ", options: .backwards) { return String(title[r.upperBound...]) }
    return ""
}

func switchWindow(direction: Int) {
    guard let chrome = chromeApp() else { return }
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    let wins = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter {
        str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole &&
        (attr($0, kAXMinimizedAttribute) as? Bool) != true
    }
    let sorted = wins.sorted { a, b in
        let pa = profileName(str(a, kAXTitleAttribute) ?? ""), pb = profileName(str(b, kAXTitleAttribute) ?? "")
        if pa != pb { return pa < pb }
        let fa = frame(a) ?? .zero, fb = frame(b) ?? .zero
        return (fa.minX, fa.minY, fa.width) < (fb.minX, fb.minY, fb.width)
    }
    log("windows (\(sorted.count)): " + sorted.map { "\"\(str($0, kAXTitleAttribute) ?? "?")\"" }.joined(separator: ", "))
    guard sorted.count > 1 else { log("only one window, nothing to switch"); return }
    let focused = element(app, kAXFocusedWindowAttribute)
    let idx = focused.flatMap { f in sorted.firstIndex { CFEqual($0, f) } } ?? 0
    let target = sorted[(idx + direction + sorted.count) % sorted.count]
    AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    chrome.activate()
    log("switched \(direction > 0 ? "next" : "prev") -> \"\(str(target, kAXTitleAttribute) ?? "?")\"")
}

// MARK: Gesture tracking

struct Gesture {
    var decided = false
    var inSidebar = false
    var dx = 0.0, dy = 0.0
    var fired = false
}
var gesture = Gesture()
var swallowMomentum = false
var dumpedWindows = Set<String>()
var tap: CFMachPort?

func handleScroll(_ event: CGEvent) -> CGEvent? {
    guard let chrome = chromeApp(), chrome.isActive else { return event }

    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

    if momentum != 0 {
        if swallowMomentum {
            if momentum == 3 { swallowMomentum = false } // momentum ended
            return nil
        }
        return event
    }
    if phase == 0 { return event } // non-gesture wheel (classic mouse)

    // 128 = mayBegin (fingers down), 1 = began
    if phase == 128 || (phase == 1 && !gesture.decided) {
        gesture = Gesture()
        gesture.decided = true
        gesture.inSidebar = isOverSidebar(event.location, chromePid: chrome.processIdentifier)
        if gesture.inSidebar { dumpOnce(chrome) }
    }
    guard gesture.inSidebar else {
        if phase == 4 || phase == 8 { gesture = Gesture() }
        return event
    }

    gesture.dx += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
    gesture.dy += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    let horizontal = abs(gesture.dx) > abs(gesture.dy) * horizontalDominance

    if !gesture.fired && horizontal && abs(gesture.dx) > swipeThreshold {
        gesture.fired = true
        swallowMomentum = true
        let dir = gesture.dx > 0 ? -1 : 1
        DispatchQueue.main.async { switchWindow(direction: dir) }
    }
    let swallow = gesture.fired || horizontal
    if phase == 4 || phase == 8 { gesture = Gesture() } // ended / cancelled
    return swallow ? nil : event
}

func dumpOnce(_ chrome: NSRunningApplication) {
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    guard let w = element(app, kAXFocusedWindowAttribute) else { return }
    let key = str(w, kAXTitleAttribute) ?? "?"
    guard !dumpedWindows.contains(key) else { return }
    dumpedWindows.insert(key)
    DispatchQueue.main.async {
        let text = "=== \(stamp.string(from: Date())) window \"\(key)\"\n" + dumpTree(w) + "\n\n"
        if let h = try? FileHandle(forWritingTo: dumpURL) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
        } else { try? text.data(using: .utf8)!.write(to: dumpURL) }
    }
}

func installTap() {
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            log("tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return Unmanaged.passUnretained(event)
        }
        guard let out = handleScroll(event) else { return nil }
        return Unmanaged.passUnretained(out)
    }, userInfo: nil)
    guard let tap else { log("ERROR: could not create event tap"); return }
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("event tap installed; swipe over Chrome's sidebar")
}

// MARK: Main

try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
AXUIElementSetMessagingTimeout(systemWide, 0.15)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
log("started pid \(ProcessInfo.processInfo.processIdentifier)")

let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if AXIsProcessTrustedWithOptions(opts) {
    installTap()
} else {
    log("waiting for Accessibility permission")
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
        if AXIsProcessTrusted() { t.invalidate(); log("Accessibility granted"); installTap() }
    }
}
app.run()
