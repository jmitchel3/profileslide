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
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func save() {
        let list: [[String: Any]] = rows.map {
            ["match": $0.email.isEmpty ? $0.name : $0.email, "emoji": $0.emoji, "hidden": $0.hidden]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["profiles": list],
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

    var body: some View {
        let base = Color(nsColor: color ?? .systemGray)
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [base.opacity(0.75), base], startPoint: .top, endPoint: .bottom))
            if emoji.isEmpty {
                Circle().fill(.white.opacity(0.9)).frame(width: 8, height: 8)
            } else {
                Text(emoji).font(.system(size: 16))
            }
        }
        .frame(width: 28, height: 28)
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
                ForEach($model.rows) { $row in ProfileRow(row: $row) }
                    .onMove { model.rows.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Drag to reorder. Click an icon to change its emoji. Hidden profiles are left out of the dots and skipped when swiping.")
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
                    Button("Quit") { NSApp.terminate(nil) }
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
        w.center()
        settingsWindow = w
        settingsModel = model
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
}

/// Debug aid: render the Settings window to a PNG (no Screen Recording permission needed).
func snapshotSettings(to path: String) {
    showSettings()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        // CGWindowListCreateImage is hidden from the SDK but still exported; capturing our
        // own window needs no Screen Recording permission.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let w = settingsWindow,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let img = unsafeBitCast(sym, to: CreateImage.self)(.null, 1 << 3, UInt32(w.windowNumber), (1 << 0) | (1 << 3))?
                .takeRetainedValue() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
