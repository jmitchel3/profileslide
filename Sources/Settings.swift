// Settings window: profile order, emoji, visibility, launch at login.
// Opened by launching the app again or right-clicking the profile dots.

import SwiftUI
import ServiceManagement

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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profiles").font(.headline)
            Text("Drag to reorder. Order sets the dots and swipe sequence; hidden profiles are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($model.rows) { $row in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Circle().fill(Color(nsColor: row.color ?? .labelColor)).frame(width: 10, height: 10)
                        TextField("•", text: $row.emoji)
                            .frame(width: 40)
                            .multilineTextAlignment(.center)
                            .onChange(of: row.emoji) { v in
                                if v.count > 1 { row.emoji = String(v.suffix(1)) } // one emoji
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            if !row.email.isEmpty {
                                Text(row.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("Show", isOn: Binding(get: { !row.hidden }, set: { row.hidden = !$0 }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    .padding(.vertical, 3)
                    .opacity(row.hidden ? 0.5 : 1)
                }
                .onMove { model.rows.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 260)

            HStack {
                Button("Emoji Picker…") { NSApp.orderFrontCharacterPalette(nil) }
                Spacer()
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }
            Divider()
            HStack {
                Button("Reveal Config") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) }
                Button("Reveal Logs") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

var settingsWindow: NSWindow?
var settingsModel: SettingsModel?

func showSettings() {
    if let model = settingsModel {
        model.reload()
    } else {
        let model = SettingsModel()
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        w.title = "ChromeProfileSwipe"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        settingsModel = model
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
}
