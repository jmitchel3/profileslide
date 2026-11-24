// Optional native macOS menu bar companion for switching profiles from any app.

import Cocoa

final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    func syncVisibility() {
        if preferences().showMenuBarItem {
            if statusItem == nil { install() }
            updateButton()
        } else {
            remove()
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let m = NSMenu()
        m.delegate = self
        item.menu = m
        statusItem = item
        menu = m
        updateButton()
    }

    private func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        menu = nil
    }

    func updateButton(focusedProfile: Profile? = nil) {
        guard let button = statusItem?.button else { return }
        let profile = focusedProfile ?? currentFocusedChromeProfile()
        if let p = profile {
            if !p.settings.emoji.isEmpty {
                button.image = nil
                button.title = p.settings.emoji
            } else {
                button.title = ""
                button.image = coloredDotImage(p.color ?? .controlAccentColor)
                button.image?.isTemplate = false
            }
            button.toolTip = "\(appDisplayName) — \(p.name)"
        } else {
            button.title = ""
            let img = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: appDisplayName)
            img?.isTemplate = true
            button.image = img
            button.toolTip = appDisplayName
        }
    }

    private func currentFocusedChromeProfile() -> Profile? {
        guard let chrome = chromeApp() else { return nil }
        let app = chromeAX(chrome)
        guard let w = element(app, kAXFocusedWindowAttribute),
              let title = str(w, kAXTitleAttribute) else { return nil }
        let all = orderedProfiles(includeHidden: true)
        guard let dir = profileDir(forWindowTitle: title, all) else { return nil }
        return all.first { $0.dir == dir }
    }

    private func coloredDotImage(_ color: NSColor) -> NSImage {
        let sz = NSSize(width: 14, height: 14)
        return NSImage(size: sz, flipped: false) { _ in
            let rect = NSRect(x: 2, y: 2, width: 10, height: 10)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 0.8
            ring.stroke()
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let all = orderedProfiles(includeHidden: true)
        let visible = all.filter { !$0.settings.hidden }
        let chrome = chromeApp()
        let wp: WindowProfiles
        if let chrome {
            let app = chromeAX(chrome)
            wp = WindowProfiles(app: app, focused: element(app, kAXFocusedWindowAttribute), profiles: all)
        } else {
            wp = WindowProfiles()
        }
        let sessions = SessionStore.load()

        for (i, p) in visible.enumerated() {
            let isOpen = wp.openDirs.contains(p.dir)
            let isFocused = wp.focusedDir == p.dir
            let isSleeping = !isOpen && (sessions[p.dir]?.sleeping == true)
            let prefix = p.settings.emoji.isEmpty ? (isOpen ? "● " : "○ ") : "\(p.settings.emoji) "
            let suffix = isSleeping ? " (sleeping)" : (isOpen ? "" : " (closed)")
            let item = NSMenuItem(title: "\(prefix)\(p.name)\(suffix)", action: #selector(pickProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.dir
            if isFocused { item.state = .on }
            if preferences().controlNumberShortcuts && i < 9 {
                item.keyEquivalent = "\(i + 1)"
                item.keyEquivalentModifierMask = [.control]
            }
            menu.addItem(item)
        }

        if visible.isEmpty {
            let empty = NSMenuItem(title: "No Chrome profiles found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())

        let switcher = NSMenuItem(title: "Quick Switcher…", action: #selector(openQuickSwitcher), keyEquivalent: " ")
        switcher.keyEquivalentModifierMask = [.option, .control]
        switcher.target = self
        menu.addItem(switcher)

        if chrome != nil && visible.count > 1 {
            let moveItem = NSMenuItem(title: "Move Current Tab To", action: nil, keyEquivalent: "")
            let moveSub = NSMenu()
            for p in visible where p.dir != wp.focusedDir {
                let prefix = p.settings.emoji.isEmpty ? "" : "\(p.settings.emoji) "
                let sub = NSMenuItem(title: "\(prefix)\(p.name)", action: #selector(moveTabToProfile(_:)), keyEquivalent: "")
                sub.target = self
                sub.representedObject = p.dir
                moveSub.addItem(sub)
            }
            if !moveSub.items.isEmpty {
                moveItem.submenu = moveSub
                menu.addItem(moveItem)
            }
        }

        let openVisible = visible.filter { wp.openDirs.contains($0.dir) }
        if !openVisible.isEmpty {
            let sleepItem = NSMenuItem(title: "Sleep Profile (Save & Close)", action: nil, keyEquivalent: "")
            let sleepSub = NSMenu()
            for p in openVisible {
                let prefix = p.settings.emoji.isEmpty ? "" : "\(p.settings.emoji) "
                let sub = NSMenuItem(title: "\(prefix)\(p.name)", action: #selector(sleepSelectedProfile(_:)), keyEquivalent: "")
                sub.target = self
                sub.representedObject = p.dir
                sleepSub.addItem(sub)
            }
            sleepItem.submenu = sleepSub
            menu.addItem(sleepItem)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let guide = NSMenuItem(title: "Setup Guide…", action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(appDisplayName)", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func pickProfile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let profile = orderedProfiles(includeHidden: true).first(where: { $0.dir == dir }) else { return }
        activateProfile(profile, ifClosed: .open, allowLaunchChrome: true)
    }

    @objc private func moveTabToProfile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let profile = orderedProfiles(includeHidden: true).first(where: { $0.dir == dir }) else { return }
        moveCurrentTab(to: profile)
    }

    @objc private func sleepSelectedProfile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let profile = orderedProfiles(includeHidden: true).first(where: { $0.dir == dir }) else { return }
        sleepProfile(profile)
    }

    @objc private func openQuickSwitcher() {
        QuickSwitcher.shared.show(global: true)
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openGuide() { SetupGuide.shared.show() }
    @objc private func quitApp() { quitCompletely() }
}
