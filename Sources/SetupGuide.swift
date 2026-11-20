import SwiftUI
import ApplicationServices

enum SetupStep: Int {
    case tabs, accessibility, practice, finished
}

enum PracticeHint: Equatable {
    case openWindow, enableSidebar, widenSidebar, addProfile, showProfiles, regularWindow
    case openDot(String), swipe

    var openingDot: Bool {
        if case .openDot = self { return true }
        return false
    }

    static func forWindow(sidebarWidth: CGFloat?, profiles: [Profile], current: String?, open: Set<String>) -> Self {
        guard let sidebarWidth else { return .enableSidebar }
        guard sidebarWidth > Overlay.minimumDotsWidth else { return .widenSidebar }
        guard profiles.count >= 2 else { return .addProfile }
        guard let current else { return .regularWindow }
        let visible = profiles.filter { !$0.settings.hidden }
        guard visible.count >= 2, visible.contains(where: { $0.dir == current }) else { return .showProfiles }
        if !visible.contains(where: { $0.dir != current && open.contains($0.dir) }),
           let other = visible.first(where: { $0.dir != current }) {
            return .openDot(other.name)
        }
        return .swipe
    }

    var instruction: String {
        switch self {
        case .openWindow: return "Open a regular Chrome window to try switching profiles."
        case .enableSidebar: return "In this Chrome window, choose View → Show Tabs Vertically."
        case .widenSidebar: return "Drag the inside edge of the tab sidebar wider until the profile dots appear."
        case .addProfile: return "In Chrome, click your profile icon and choose Add Chrome profile. You need two profiles to try a switch."
        case .showProfiles: return "In ProfileSlide Settings, turn on Show for your current profile and at least one other."
        case .regularWindow: return "Open a regular window for one of your Chrome profiles so ProfileSlide can identify it."
        case .openDot(let name): return "Only one profile has a window open. Click the dimmed dot for \(name) at the bottom of the sidebar to open it."
        case .swipe: return "Move the pointer over the tabs and swipe sideways on your trackpad or Magic Mouse. You can also click another profile dot."
        }
    }
}

final class SetupGuide: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SetupGuide()
    private static let progressKey = "setupStep"
    @Published private(set) var step = SetupStep(rawValue: UserDefaults.standard.integer(forKey: progressKey)) ?? .tabs
    @Published private(set) var hint = PracticeHint.openWindow
    @Published private(set) var launchError: String?
    private(set) var window: NSWindow?
    private var practiceTimer: Timer?
    private var expectedProfile: String?
    private var switchDeadline = Date.distantPast

    // Saving even the first step distinguishes a fresh install from a dismissed guide.
    var isFirstPresentation: Bool {
        UserDefaults.standard.object(forKey: Self.progressKey) == nil
    }

    func move(to next: SetupStep) {
        expectedProfile = nil
        launchError = nil
        step = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
        observePractice()
    }

    func show() {
        if step == .finished { move(to: .tabs) }
        if step == .practice && !AXIsProcessTrusted() { move(to: .accessibility) }
        if window == nil {
            if isFirstPresentation { UserDefaults.standard.set(step.rawValue, forKey: Self.progressKey) }
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(guide: self)))
            w.title = "Set Up ProfileSlide"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            observePractice()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        practiceTimer?.invalidate()
        practiceTimer = nil
        expectedProfile = nil
        window = nil
        hideDockIfWindowsClosed()
    }

    func openChrome() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) else {
            launchError = "Install Google Chrome, then choose Open Chrome again."
            return
        }
        launchError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { self.launchError = error.localizedDescription } }
        }
    }

    func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            move(to: .practice)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func permissionGranted() {
        guard window != nil, step == .accessibility else { return }
        move(to: .practice)
        show()
    }

    /// A click on the current dot, a failed raise, or switching windows in Chrome by
    /// hand must not count as finishing the exercise.
    func willSwitch(to target: String, in app: AXUIElement) {
        guard step == .practice, window != nil else { return }
        let title = element(app, kAXFocusedWindowAttribute).flatMap { str($0, kAXTitleAttribute) }
        let current = title.flatMap { profileDir(forWindowTitle: $0, loadProfiles()) }
        expectedProfile = current != nil && current != target ? target : nil
        switchDeadline = Date().addingTimeInterval(8)
    }

    private func observePractice() {
        practiceTimer?.invalidate()
        practiceTimer = nil
        guard step == .practice, window != nil else { return }
        refreshPractice()
        practiceTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refreshPractice()
        }
    }

    private func refreshPractice() {
        let next = practiceHint()
        if next != hint { hint = next }
    }

    private func practiceHint() -> PracticeHint {
        guard let chrome = chromeApp() else { return .openWindow }
        let app = chromeAX(chrome)
        guard let w = element(app, kAXFocusedWindowAttribute) else { return .openWindow }
        let all = orderedProfiles(includeHidden: true)
        let windows = WindowProfiles(app: app, focused: w, profiles: all)
        if let target = expectedProfile, Date() < switchDeadline, chrome.isActive, windows.focusedDir == target {
            move(to: .finished)
            window?.close()
            if let profile = all.first(where: { $0.dir == target }) { overlay?.flash(name: profile.name) }
            return .swipe
        }
        return .forWindow(sidebarWidth: overlay?.sidebarFrame(in: w)?.width, profiles: all,
                          current: windows.focusedDir, open: windows.openDirs)
    }

    var dotsHint: String? {
        guard step == .practice, window != nil else { return nil }
        switch hint {
        case .swipe: return "Swipe over the tabs ↔"
        case .openDot: return "Click a dimmed dot"
        default: return nil
        }
    }
}

struct SetupView: View {
    @ObservedObject var guide: SetupGuide

    private var title: String {
        switch guide.step {
        case .tabs: return "Put your tabs on the side"
        case .accessibility: return "Allow profile switching"
        case .practice, .finished: return "Try your first switch"
        }
    }

    private var detail: String {
        switch guide.step {
        case .tabs: return "In Chrome’s menu bar, choose View → Show Tabs Vertically. When the tabs are on the left, come back here to continue."
        case .accessibility:
            if AXIsProcessTrusted() { return "Accessibility is enabled. ProfileSlide can recognize swipes over your tabs and bring the matching Chrome window forward." }
            return "ProfileSlide uses Accessibility to recognize swipes over your tabs and bring the matching Chrome window forward. Turn on ProfileSlide in Accessibility settings."
        case .practice, .finished: return guide.hint.instruction
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Step \(min(guide.step.rawValue + 1, 3)) of 3")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Finish later") { guide.window?.close() }
                    .buttonStyle(.link).keyboardShortcut(.cancelAction)
                    .help("Resume from Settings → Show Setup Guide…")
            }
            SetupIllustration(step: guide.step, openingDot: guide.hint.openingDot)
            Text(title).font(.title.weight(.semibold))
            Text(guide.launchError ?? detail).fixedSize(horizontal: false, vertical: true)
            if guide.step == .practice {
                Text("After closing this guide, reopen ProfileSlide for Settings. You can also right-click the profile dots.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                if guide.step != .tabs {
                    Button("Back") { guide.move(to: guide.step == .practice ? .accessibility : .tabs) }
                }
                Spacer()
                switch guide.step {
                case .tabs:
                    Button("Open Chrome", action: guide.openChrome)
                    Button("My tabs are on the side") { guide.move(to: .accessibility) }
                        .keyboardShortcut(.defaultAction)
                case .accessibility:
                    Button(AXIsProcessTrusted() ? "Continue" : "Open Accessibility Settings", action: guide.openAccessibility)
                        .keyboardShortcut(.defaultAction)
                case .practice, .finished:
                    if guide.hint == .showProfiles {
                        Button("Open ProfileSlide Settings", action: showSettings).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Open Chrome", action: guide.openChrome).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 510, height: 414)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
