// Arc/Raycast-style floating Quick Switcher palette (⌃Space in Chrome, ⌥⌃Space globally).
// Non-activating so Chrome stays focused; keyboard input is handled cleanly by the event tap.

import SwiftUI

final class QuickSwitcherModel: ObservableObject {
    @Published var query = "" {
        didSet { applyFilter() }
    }
    @Published var allProfiles: [Profile] = []
    @Published var filtered: [Profile] = []
    @Published var selectedIndex = 0
    @Published var openDirs: Set<String> = []
    @Published var focusedDir: String?
    @Published var sleepingDirs: Set<String> = []
    @Published var chromeActive = false

    func load(profiles: [Profile], openDirs: Set<String>, focusedDir: String?,
              sleepingDirs: Set<String>, chromeActive: Bool) {
        self.allProfiles = profiles
        self.openDirs = openDirs
        self.focusedDir = focusedDir
        self.sleepingDirs = sleepingDirs
        self.chromeActive = chromeActive
        self.query = ""
        self.filtered = profiles
        // Pre-select the next profile after the currently focused one for instant ⌃Space + Return switching
        if let focusedDir, let current = profiles.firstIndex(where: { $0.dir == focusedDir }), profiles.count > 1 {
            selectedIndex = (current + 1) % profiles.count
        } else {
            selectedIndex = 0
        }
    }

    func applyFilter() {
        filtered = filterProfiles(allProfiles, query: query)
        if selectedIndex >= filtered.count {
            selectedIndex = max(0, filtered.count - 1)
        }
    }

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filtered.count) % filtered.count
    }

    var selectedProfile: Profile? {
        guard filtered.indices.contains(selectedIndex) else { return nil }
        return filtered[selectedIndex]
    }

    func shortcutNumber(for dir: String) -> Int? {
        guard preferences().controlNumberShortcuts,
              let idx = allProfiles.firstIndex(where: { $0.dir == dir }), idx < 9 else { return nil }
        return idx + 1
    }
}

final class QuickSwitcher {
    static let shared = QuickSwitcher()
    private let panel: NSPanel
    let model = QuickSwitcherModel()
    private(set) var isVisible = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    var windowNumber: Int { panel.windowNumber }

    func receivesMouseDown(_ event: CGEvent) -> Bool {
        isVisible && NSWindow.windowNumber(at: event.unflippedLocation, belowWindowWithWindowNumber: 0) == windowNumber
    }

    func toggle(global: Bool) {
        if isVisible { dismiss() } else { show(global: global) }
    }

    func show(global: Bool, previewProfiles: [Profile]? = nil) {
        if OpenPrompt.shared.isVisible { OpenPrompt.shared.dismiss() }
        SwitchHUD.shared.dismiss()

        let profiles = previewProfiles ?? orderedProfiles()
        guard !profiles.isEmpty else { return }

        let chrome = chromeApp()
        let isChromeActive = chrome?.isActive == true
        var openDirs = Set<String>()
        var focusedDir: String?
        var targetWindowFrame: CGRect?
        if let chrome {
            let app = chromeAX(chrome)
            let focusedWin = element(app, kAXFocusedWindowAttribute)
            let all = orderedProfiles(includeHidden: true)
            let wp = WindowProfiles(app: app, focused: focusedWin, profiles: all)
            openDirs = wp.openDirs
            focusedDir = wp.focusedDir
            if isChromeActive { targetWindowFrame = focusedWin.flatMap(frame) }
        }
        let sessions = SessionStore.load()
        let sleeping = Set(sessions.filter { $0.value.sleeping && !$0.value.urls.isEmpty }.keys)

        model.load(profiles: profiles, openDirs: openDirs, focusedDir: focusedDir,
                   sleepingDirs: sleeping, chromeActive: isChromeActive)

        let view = QuickSwitcherView(
            model: model,
            onSelect: { [weak self] p, moveTab in
                self?.activate(p, moveTab: moveTab)
            },
            onSleep: { [weak self] p in
                self?.sleep(p)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin: CGPoint
        if !global, let f = targetWindowFrame {
            let top = primaryHeight - f.minY
            let y = max(primaryHeight - f.maxY + 40, top - size.height - 90)
            origin = CGPoint(x: f.midX - size.width / 2, y: y)
        } else {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            let s = screen?.visibleFrame ?? .zero
            origin = CGPoint(x: s.midX - size.width / 2, y: s.midY - size.height / 2 + 60)
        }

        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        isVisible = true
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        log("opened quick switcher (\(profiles.count) profiles)")
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        model.moveSelection(by: delta)
    }

    func appendText(_ text: String) {
        model.query.append(text)
    }

    func backspace() {
        if !model.query.isEmpty { model.query.removeLast() }
    }

    func confirmSelection(moveTab: Bool = false) {
        guard let p = model.selectedProfile else { dismiss(); return }
        activate(p, moveTab: moveTab)
    }

    func sleepSelection() {
        guard let p = model.selectedProfile, model.openDirs.contains(p.dir) else { return }
        sleep(p)
    }

    private func activate(_ profile: Profile, moveTab: Bool) {
        let canMove = moveTab && model.chromeActive && profile.dir != model.focusedDir
        dismiss()
        DispatchQueue.main.async {
            if canMove {
                moveCurrentTab(to: profile)
            } else {
                activateProfile(profile, ifClosed: .open, allowLaunchChrome: true)
            }
        }
    }

    private func sleep(_ profile: Profile) {
        dismiss()
        DispatchQueue.main.async {
            sleepProfile(profile)
        }
    }
}

struct QuickSwitcherView: View {
    @ObservedObject var model: QuickSwitcherModel
    let onSelect: (Profile, Bool) -> Void
    let onSleep: (Profile) -> Void
    let onDismiss: () -> Void
    @State private var hoveredDir: String?

    private var accentTint: Color {
        if let sel = model.selectedProfile, let c = sel.color { return Color(nsColor: c) }
        return Color.accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search header
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                if model.query.isEmpty {
                    Text("Switch Chrome profile…")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 1) {
                        Text(model.query)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                        Rectangle()
                            .fill(accentTint)
                            .frame(width: 1.5, height: 16)
                    }
                }
                Spacer()
                if !model.query.isEmpty {
                    Text("\(model.filtered.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().opacity(0.45)

            // Results list
            if model.filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No matching profiles")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(Array(model.filtered.enumerated()), id: \.element.dir) { index, profile in
                                let isSelected = index == model.selectedIndex
                                let isOpen = model.openDirs.contains(profile.dir)
                                let isCurrent = profile.dir == model.focusedDir
                                let isSleeping = !isOpen && model.sleepingDirs.contains(profile.dir)
                                QuickSwitcherRow(
                                    profile: profile,
                                    isSelected: isSelected,
                                    isHovered: hoveredDir == profile.dir,
                                    isOpen: isOpen,
                                    isCurrent: isCurrent,
                                    isSleeping: isSleeping,
                                    shortcut: model.shortcutNumber(for: profile.dir)
                                )
                                .id(profile.dir)
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onHover { inside in
                                    if inside {
                                        hoveredDir = profile.dir
                                        model.selectedIndex = index
                                    } else if hoveredDir == profile.dir {
                                        hoveredDir = nil
                                    }
                                }
                                .onTapGesture {
                                    let optionHeld = NSEvent.modifierFlags.contains(.option)
                                    onSelect(profile, optionHeld)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: model.selectedIndex) { _, _ in
                        if let dir = model.selectedProfile?.dir {
                            proxy.scrollTo(dir, anchor: .center)
                        }
                    }
                }
            }

            Divider().opacity(0.45)

            // Footer action hints
            HStack(spacing: 12) {
                footerHint("↩", "Switch")
                if model.chromeActive {
                    footerHint("⇧↩", "Move Tab")
                }
                if let sel = model.selectedProfile, model.openDirs.contains(sel.dir) {
                    footerHint("⌘W", "Sleep")
                }
                Spacer()
                footerHint("esc", "Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 390)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                LinearGradient(colors: [accentTint.opacity(0.14), accentTint.opacity(0.03), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .padding(32)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Keycap(text: key)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuickSwitcherRow: View {
    let profile: Profile
    let isSelected: Bool
    let isHovered: Bool
    let isOpen: Bool
    let isCurrent: Bool
    let isSleeping: Bool
    let shortcut: Int?

    private var tint: Color { Color(nsColor: profile.color ?? .systemGray) }

    var body: some View {
        HStack(spacing: 10) {
            ProfileTile(color: profile.color, emoji: profile.settings.emoji, size: 30)
                .opacity(isOpen || isCurrent ? 1 : 0.65)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .lineLimit(1)
                    if isCurrent {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(tint.opacity(0.15)))
                    } else if isSleeping {
                        Text("Sleeping")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                if !profile.email.isEmpty {
                    Text(profile.email)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Circle()
                .fill(isOpen ? Color.green.opacity(0.85) : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
                .help(isOpen ? "Window open" : "Closed")

            if let n = shortcut {
                Keycap(text: "⌃\(n)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? tint.opacity(0.18) : (isHovered ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.32) : .clear, lineWidth: 0.75)
        )
    }
}
