// Settings window in the style of macOS System Settings.
// Opened by launching the app again or right-clicking the profile dots.

import SwiftUI
import ServiceManagement

let appDisplayName = "Chrome Profile Swipe"

final class SettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String // profile directory
        let name: String
        let email: String
        let color: NSColor?
        var emoji: String
        var hidden: Bool
    }

    @Published var rows: [Row] = [] { didSet { if !loading { save() } } }
    @Published var shortcutsEnabled = true { didSet { if !loading { save() } } }

    /// ⌃ number for each visible profile, by position.
    var shortcutNumbers: [String: Int] {
        var out: [String: Int] = [:]
        for (i, r) in rows.filter({ !$0.hidden }).enumerated() where i < 9 { out[r.id] = i + 1 }
        return out
    }
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

    init() { reload() }

    func reload() {
        loading = true
        defer { loading = false }
        let entries = configEntries()
        rows = orderedProfiles(includeHidden: true).map { p in
            let e = configIndex(p).map { entries[$0] }
            return Row(id: p.dir, name: p.name, email: p.email, color: p.color,
                       emoji: e?.emoji ?? "", hidden: e?.hidden ?? false)
        }
        shortcutsEnabled = ChromeProfileSwipe.shortcutsEnabled()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func save() {
        let list: [[String: Any]] = rows.map {
            ["match": $0.email.isEmpty ? $0.name : $0.email, "emoji": $0.emoji, "hidden": $0.hidden]
        }
        let config: [String: Any] = ["profiles": list, "controlNumberShortcuts": shortcutsEnabled]
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL)
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
                    .onChange(of: emoji) { v in
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
        }
        .padding(.vertical, 2)
        .opacity(row.hidden ? 0.55 : 1)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

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
                let numbers = model.shortcutsEnabled ? model.shortcutNumbers : [:]
                ForEach($model.rows) { $row in ProfileRow(row: $row, shortcut: numbers[row.id]) }
                    .onMove { model.rows.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Drag to reorder. Click an icon to change its emoji. Hidden profiles are left out of the dots and skipped when swiping.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Switch profiles with ⌃1 – ⌃9", isOn: $model.shortcutsEnabled)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Works while Chrome is in front. If a profile isn't open you're asked first; pressing another ⌃ number skips the question.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("General") {
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
        .frame(width: 500, height: 600)
    }
}

// MARK: Window

var settingsWindow: NSWindow?
var settingsModel: SettingsModel?

/// Drops the Dock icon when Settings closes; the app keeps running in the background.
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
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
/// `--snapshot-settings <png>` or `--snapshot-prompt <png>`.
func snapshot(_ which: String, to path: String) {
    if which == "prompt" {
        OpenPrompt.shared.show(loadProfiles()[0], shortcut: 3, over: nil)
    } else {
        showSettings()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        // CGWindowListCreateImage is hidden from the SDK but still exported; capturing our
        // own window needs no Screen Recording permission.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let number = which == "prompt" ? OpenPrompt.shared.windowNumber : settingsWindow?.windowNumber
        guard let n = number,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let img = unsafeBitCast(sym, to: CreateImage.self)(.null, 1 << 3, UInt32(n), (1 << 0) | (1 << 3))?
                .takeRetainedValue() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
