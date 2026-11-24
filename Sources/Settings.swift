// Settings window in the style of macOS System Settings.
// Opened by launching the app again or right-clicking the profile dots.

import SwiftUI
import ServiceManagement

let appDisplayName = "ProfileSlide"

final class SettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String // profile directory
        let name: String
        let email: String
        let color: NSColor?
        var emoji: String
        var hidden: Bool
        var opens: OpenMode
        var pages: [String]
    }

    @Published var rows: [Row] = [] { didSet { if !loading { save() } } }
    @Published var prefs = AppPreferences() {
        didSet {
            if !loading {
                save()
                MenuBarController.shared.syncVisibility()
                overlay?.refresh()
            }
        }
    }

    /// ⌃ number for each visible profile, by position.
    var shortcutNumbers: [String: Int] {
        var out: [String: Int] = [:]
        for (i, r) in rows.filter({ !$0.hidden }).enumerated() where i < 9 { out[r.id] = i + 1 }
        return out
    }
    @Published var sidebarMissing = false
    @Published var accessibilityAllowed = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log("launch at login change failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    private var loading = false
    private var unmatchedEntries: [ConfigEntry] = []

    init() { reload() }

    func reload() {
        loading = true
        defer { loading = false }
        let all = orderedProfiles(includeHidden: true)
        unmatchedEntries = configEntries().filter { $0.profile(in: all) == nil }
        rows = all.map { p in
            let e = p.settings
            return Row(id: p.dir, name: p.name, email: p.email, color: p.color,
                       emoji: e.emoji, hidden: e.hidden,
                       opens: e.opens, pages: e.pages)
        }
        prefs = preferences()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityAllowed = AXIsProcessTrusted()
        sidebarMissing = overlay?.sidebarMissing ?? false
    }

    func save() {
        let list = rows.map { row in
            let pages = row.pages.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "https://" }
            return ConfigEntry(dir: row.id, emoji: row.emoji, hidden: row.hidden, opens: row.opens, pages: pages).json
        } + unmatchedEntries.map(\.json)
        var config = prefs.jsonFields
        config["profiles"] = list
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
        // Force immediate reload of cached config on next read.
        cachedConfigMTime = nil
    }
}

// MARK: Views

struct AppIconTile: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.33, green: 0.30, blue: 0.92)],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

/// Rounded-square tile in the profile's theme color, like System Settings icons.
struct ProfileTile: View {
    let color: NSColor?
    let emoji: String
    var size: CGFloat = 28

    var body: some View {
        let base = Color(nsColor: color ?? .systemGray)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [base.opacity(0.75), base], startPoint: .top, endPoint: .bottom))
            if emoji.isEmpty {
                Circle().fill(.white.opacity(0.9)).frame(width: size * 0.28, height: size * 0.28)
            } else {
                Text(emoji).font(.system(size: size * 0.57))
            }
        }
        .frame(width: size, height: size)
    }
}

let suggestedEmoji = ["🎮", "🖥️", "🚀", "🌶️", "🎬", "🪐", "💼", "🏠",
                      "🎓", "💻", "📚", "🧪", "🎨", "🎧", "🛒", "💰",
                      "❤️", "⭐️", "🔥", "🌊", "🌲", "☕️", "✈️", "⚽️"]

struct EmojiPicker: View {
    @Binding var emoji: String
    @Binding var isPresented: Bool
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(suggestedEmoji, id: \.self) { e in
                    Button {
                        emoji = e; isPresented = false
                    } label: {
                        Text(e).font(.system(size: 19))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(emoji == e ? Color.accentColor.opacity(0.22) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Other", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.center)
                    .onChange(of: emoji) { _, v in
                        if v.count > 1 { emoji = String(v.suffix(1)) }
                    }
                Button {
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                }
                .help("Emoji & Symbols")
                Spacer()
                Button("Use Dot") { emoji = ""; isPresented = false }
            }
        }
        .padding(12)
        .frame(width: 284)
    }
}

struct ProfileRow: View {
    @Binding var row: SettingsModel.Row
    var shortcut: Int?
    var onDetails: () -> Void = {}
    @State private var picking = false

    var body: some View {
        HStack(spacing: 10) {
            Button { picking = true } label: { ProfileTile(color: row.color, emoji: row.emoji) }
                .buttonStyle(.plain)
                .help("Choose an emoji")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    EmojiPicker(emoji: $row.emoji, isPresented: $picking)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                if !row.email.isEmpty {
                    Text(row.email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDetails) {
                HStack(spacing: 3) {
                    Text(row.opens.title)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.callout).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose what this profile opens with")
            if let n = shortcut {
                Text("⌃\(n)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.secondary.opacity(0.12)))
            }
            Toggle("Show", isOn: Binding(get: { !row.hidden }, set: { row.hidden = !$0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.vertical, 2)
        .opacity(row.hidden ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// Live reordering: rows swap places as a dragged row passes over them.
struct RowDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let model: SettingsModel

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = model.rows.firstIndex(where: { $0.id == d }),
              let to = model.rows.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.rows.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var dragging: String?
    @State private var editing: String?

    private func move(_ id: String, by delta: Int) {
        guard let i = model.rows.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard model.rows.indices.contains(j) else { return }
        withAnimation { model.rows.swapAt(i, j) }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIconTile()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appDisplayName).font(.headline)
                        Text("Swipe sideways on Chrome's tab sidebar to move between profiles.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                let numbers = model.prefs.controlNumberShortcuts ? model.shortcutNumbers : [:]
                ForEach($model.rows) { $row in
                    ProfileRow(row: $row, shortcut: numbers[row.id], onDetails: { editing = row.id })
                        .opacity(dragging == row.id ? 0.4 : 1)
                        .onDrag {
                            dragging = row.id
                            return NSItemProvider(object: row.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: RowDropDelegate(target: row.id, dragging: $dragging, model: model))
                        .contextMenu {
                            Button("Move Up") { move(row.id, by: -1) }
                            Button("Move Down") { move(row.id, by: 1) }
                        }
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Drag to reorder. Click an icon to change its emoji. Hold ⌥ and click a dot to move the current tab to that profile; right-click a dot to sleep or switch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Match window frame when switching", isOn: $model.prefs.syncWindowFrame)
                Toggle("Show switch banner HUD", isOn: $model.prefs.showSwitchHUD)
                Toggle("Trackpad haptic feedback", isOn: $model.prefs.hapticFeedback)
                Toggle("Ask before opening closed profiles", isOn: $model.prefs.confirmClosedProfiles)
                Picker("Swipe sensitivity", selection: $model.prefs.swipeSensitivity) {
                    ForEach(SwipeSensitivity.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reverse swipe direction", isOn: $model.prefs.reverseSwipe)
            } header: {
                Text("Switching & Feel")
            } footer: {
                Text("Matching window frames aligns open profiles on the same display so Chrome feels like one unified browser.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Jump to profile with ⌃1 – ⌃9", isOn: $model.prefs.controlNumberShortcuts)
                Toggle("Cycle adjacent profiles with ⌃← / ⌃→", isOn: $model.prefs.arrowShortcuts)
                Toggle("Quick Switcher in Chrome (⌃Space)", isOn: $model.prefs.quickSwitcherEnabled)
                Toggle("Global Quick Switcher from any app (⌥⌃Space)", isOn: $model.prefs.globalQuickSwitcherEnabled)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("In Quick Switcher, type to filter, press ↩ to switch, ⇧↩ to move the active tab, or ⌘W to sleep an open profile.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show in menu bar", isOn: $model.prefs.showMenuBarItem)
                Button("Show Setup Guide…") { SetupGuide.shared.show() }
                Toggle("Open at login", isOn: $model.launchAtLogin)
                LabeledContent("Accessibility") {
                    if model.accessibilityAllowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                if model.accessibilityAllowed && model.sidebarMissing {
                    Label("Chrome sidebar not detected", systemImage: "sidebar.left")
                }
            }

            Section {
                HStack {
                    Button("Show Config in Finder") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) }
                    Button("Show Logs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                    Spacer()
                    Button("Quit Completely") { quitCompletely() }
                        .help("Stops swipe switching until you open the app again")
                }
            }
        }
        .formStyle(.grouped)
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true } // drag ended outside a row
        .frame(width: 560, height: 680)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let id = editing, let i = model.rows.firstIndex(where: { $0.id == id }) {
                ProfileDetailView(row: $model.rows[i], onDone: { editing = nil })
            }
        }
    }
}

// MARK: Window

var settingsWindow: NSWindow?
var settingsModel: SettingsModel?

func hideDockIfWindowsClosed() {
    DispatchQueue.main.async {
        if settingsWindow?.isVisible != true && SetupGuide.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        hideDockIfWindowsClosed()
    }
}
let settingsWindowDelegate = SettingsWindowDelegate()

func showSettings() {
    if let model = settingsModel {
        model.reload()
    } else {
        let model = SettingsModel()
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        w.title = appDisplayName
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = false
        w.isReleasedWhenClosed = false
        w.delegate = settingsWindowDelegate
        w.center()
        settingsWindow = w
        settingsModel = model
    }
    NSApp.setActivationPolicy(.regular) // Dock icon + menu bar while Settings is open
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
}

/// Debug aid: render a window of ours to a PNG (no Screen Recording permission needed).
/// `--snapshot-settings <png>`, `--snapshot-prompt <png>`, `--snapshot-switcher <png>`, or `--snapshot-hud <png>`.
func snapshot(_ which: String, to path: String) {
    let profiles = orderedProfiles()
    if which == "prompt", let first = profiles.first {
        OpenPrompt.shared.show(first, shortcut: 3, over: nil)
    } else if which == "switcher" {
        QuickSwitcher.shared.show(global: true, previewProfiles: profiles)
    } else if which == "hud", let first = profiles.first {
        SwitchHUD.shared.show(profile: first, profiles: profiles, openDirs: [first.dir], over: nil, duration: 3.0)
    } else {
        showSettings()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        // CGWindowListCreateImage is hidden from the SDK but still exported; capturing our
        // own window needs no Screen Recording permission.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let number: Int?
        switch which {
        case "prompt": number = OpenPrompt.shared.windowNumber
        case "switcher": number = QuickSwitcher.shared.windowNumber
        case "hud": number = SwitchHUD.shared.windowNumber
        default: number = settingsWindow?.windowNumber
        }
        guard let n = number,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let img = unsafeBitCast(sym, to: CreateImage.self)(.null, 1 << 3, UInt32(n), (1 << 0) | (1 << 3))?
                .takeRetainedValue() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}

// MARK: Profile detail (what it opens with)

struct ProfileDetailView: View {
    @Binding var row: SettingsModel.Row
    let onDone: () -> Void
    @State private var sites: [Site] = []
    @State private var isOpen = false
    @State private var busy = false
    @State private var message: String?
    @State private var refresh = 0

    private var session: SavedSession? { _ = refresh; return SessionStore.load()[row.id] }

    private var footer: String {
        switch row.opens {
        case .newTab: return "Chrome opens this profile the way it normally does."
        case .lastSession: return "Reopens the tabs this profile had the last time it was open. Tabs are saved every 30 seconds while Chrome is in front, and when you switch away."
        case .pages: return "Opens these pages, in this order, whenever this profile is opened from a dot or ⌃ number."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileTile(color: row.color, emoji: row.emoji, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.headline)
                    if !row.email.isEmpty { Text(row.email).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 20)

            Form {
                Section {
                    Picker("When opened", selection: $row.opens) {
                        ForEach(OpenMode.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(footer).font(.footnote).foregroundStyle(.secondary)
                }
                switch row.opens {
                case .pages: pagesSection
                case .lastSession: sessionSection
                case .newTab: EmptyView()
                }
            }
            .formStyle(.grouped)

            HStack {
                if let m = message {
                    Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 500, height: 560)
        .onAppear {
            sites = topSites(row.id)
            isOpen = openProfileDirs().contains(row.id)
        }
    }

    @ViewBuilder private var pagesSection: some View {
        Section("Pages") {
            if row.pages.isEmpty {
                Text("No pages yet.").foregroundStyle(.secondary)
            }
            ForEach(row.pages.indices, id: \.self) { i in
                HStack {
                    TextField("https://", text: Binding(get: { i < row.pages.count ? row.pages[i] : "" },
                                                        set: { if i < row.pages.count { row.pages[i] = $0 } }))
                        .textFieldStyle(.plain)
                    Button {
                        if i < row.pages.count { row.pages.remove(at: i) }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Add Page") { row.pages.append("https://") }
                Menu("Add Top Site") {
                    ForEach(sites, id: \.self) { s in
                        Button("\(String(s.title.prefix(40)))  ·  \(displayHost(s.url))") {
                            if !row.pages.contains(s.url) { row.pages.append(s.url) }
                        }
                    }
                }
                .disabled(sites.isEmpty)
                .fixedSize()
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Use Current Tabs") { useCurrentTabs() }
                    .disabled(!isOpen || busy)
                    .help(isOpen ? "Replace the list with this profile's open tabs" : "Open this profile first")
            }
        }
    }

    @ViewBuilder private var sessionSection: some View {
        Section {
            if let s = session, !s.urls.isEmpty {
                ForEach(Array(s.urls.prefix(12).enumerated()), id: \.offset) { _, url in
                    Text(displayHost(url)).lineLimit(1).truncationMode(.middle)
                }
                if s.urls.count > 12 {
                    Text("and \(s.urls.count - 12) more").foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing saved yet. Open this profile and its tabs are saved automatically.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save Now") { saveNow() }.disabled(!isOpen || busy)
            }
        } header: {
            if let s = session {
                Text("Saved \(s.savedAt.formatted(.relative(presentation: .named)))")
            } else {
                Text("Saved Session")
            }
        }
    }

    private func readTabs(_ then: @escaping ([String]) -> Void) {
        busy = true; message = nil
        readChromeTabs { tabs, error in
            busy = false
            if let urls = tabs[row.id], !urls.isEmpty {
                then(urls)
            } else if error != nil {
                message = "Allow ProfileSlide to control Google Chrome in System Settings › Privacy & Security › Automation."
            } else {
                message = "Couldn't find this profile's tabs."
            }
        }
    }

    private func useCurrentTabs() { readTabs { row.pages = $0 } }
    private func saveNow() { readTabs { SessionStore.update([row.id: $0]); refresh += 1 } }
}
