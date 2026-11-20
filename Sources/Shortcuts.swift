// ⌃1–⌃9 jump to the Nth visible profile while Chrome is frontmost.
// A closed profile asks first ("Open X?"); another ⌃ number skips the question,
// the same ⌃ number again (or Return) opens it, Esc cancels.

import SwiftUI

let digitKeyCodes: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
let keyReturn: Int64 = 36, keyEnter: Int64 = 76, keyEscape: Int64 = 53

func handleKey(_ event: CGEvent) -> CGEvent? {
    guard let chrome = chromeApp(), chrome.isActive else { return event }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

    if OpenPrompt.shared.isVisible && mods.isEmpty {
        if code == keyReturn || code == keyEnter { DispatchQueue.main.async { OpenPrompt.shared.confirm() }; return nil }
        if code == keyEscape { DispatchQueue.main.async { OpenPrompt.shared.dismiss() }; return nil }
    }

    guard mods == .maskControl, let n = digitKeyCodes[code], shortcutsEnabled(),
          n <= orderedProfiles().count else { return event }
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
    DispatchQueue.main.async { jumpToProfile(number: n) }
    return nil
}

func jumpToProfile(number n: Int) {
    guard let chrome = chromeApp() else { return }
    let profiles = orderedProfiles()
    guard profiles.indices.contains(n - 1) else { return }
    let target = profiles[n - 1]
    let prompt = OpenPrompt.shared

    if prompt.isVisible {
        if prompt.profile?.dir == target.dir { prompt.confirm(); return }
        prompt.dismiss()
    }
    if openProfiles(chrome).contains(where: { $0.dir == target.dir }) {
        activateProfile(target)
    } else {
        let focused = element(chromeAX(chrome), kAXFocusedWindowAttribute).flatMap(frame)
        prompt.show(target, shortcut: n, over: focused)
    }
}

// MARK: Prompt

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OpenPrompt {
    static let shared = OpenPrompt()
    private let panel: NSPanel
    private(set) var profile: Profile?
    private var autoHide: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    var isVisible: Bool { profile != nil && panel.isVisible }
    var windowNumber: Int { panel.windowNumber }

    /// `windowFrame` is in AX coordinates (top-left origin).
    func show(_ p: Profile, shortcut: Int, over windowFrame: CGRect?) {
        profile = p
        let view = OpenPromptView(profile: p, emoji: emoji(for: p) ?? "", shortcut: shortcut,
                                  onOpen: { [weak self] in self?.confirm() },
                                  onCancel: { [weak self] in self?.dismiss() })
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin: CGPoint
        if let f = windowFrame {
            origin = CGPoint(x: f.midX - size.width / 2, y: primaryHeight - f.minY - 110 - size.height)
        } else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            origin = CGPoint(x: s.midX - size.width / 2, y: s.maxY - 160 - size.height)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        log("asked to open \(p.name)")

        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func confirm() {
        guard let p = profile else { return }
        dismiss()
        activateProfile(p)
    }

    func dismiss() {
        autoHide?.cancel()
        profile = nil
        panel.orderOut(nil)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PromptButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Color(nsColor: .systemBlue) : Color.secondary.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct OpenPromptView: View {
    let profile: Profile
    let emoji: String
    let shortcut: Int
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProfileTile(color: profile.color, emoji: emoji, size: 44)
                .padding(.top, 4)
            VStack(spacing: 3) {
                Text("Open \u{201C}\(profile.name)\u{201D}?").font(.headline)
                Text("This profile has no open window.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel).buttonStyle(PromptButtonStyle(prominent: false))
                Button("Open", action: onOpen).buttonStyle(PromptButtonStyle(prominent: true))
            }
            Text("⌃\(shortcut) or Return to open · Esc to cancel")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 270)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}
