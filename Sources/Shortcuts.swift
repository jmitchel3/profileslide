// ⌃1–⌃9 jump to the Nth visible profile while Chrome is frontmost.
// A closed profile asks first ("Open X?"); another ⌃ number skips the question,
// the same ⌃ number again (or Return) opens it, Esc cancels.

import SwiftUI

func selectProfile(at index: Int, in profiles: [Profile]) {
    let target = profiles[index]
    let prefs = preferences()
    let action = ClosedProfileAction(selecting: target.dir, at: index, pending: OpenPrompt.shared.profile?.dir,
                                     shortcutsEnabled: prefs.controlNumberShortcuts,
                                     confirmClosed: prefs.confirmClosedProfiles)
    activateProfile(target, ifClosed: action)
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
        panel.hasShadow = false // the card draws its own soft shadow
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    var isVisible: Bool { profile != nil && panel.isVisible }
    var windowNumber: Int { panel.windowNumber }

    func receivesMouseDown(_ event: CGEvent) -> Bool {
        isVisible && NSWindow.windowNumber(at: event.unflippedLocation, belowWindowWithWindowNumber: 0) == windowNumber
    }

    /// `windowFrame` is in AX coordinates (top-left origin).
    func show(_ p: Profile, shortcut: Int?, over windowFrame: CGRect?) {
        profile = p
        let view = OpenPromptView(profile: p, emoji: p.settings.emoji, shortcut: shortcut,
                                  onOpen: { [weak self] in self?.confirm() },
                                  onCancel: { [weak self] in self?.dismiss() })
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host

        // Center on the active Chrome window (AX frames use a top-left origin).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin: CGPoint
        if let f = windowFrame {
            origin = CGPoint(x: f.midX - size.width / 2, y: primaryHeight - f.midY - size.height / 2)
        } else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            origin = CGPoint(x: s.midX - size.width / 2, y: s.midY - size.height / 2)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        log("asked to open \(p.name)")

        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func confirm() {
        guard let p = profile else { return }
        dismiss()
        DispatchQueue.main.async { activateProfile(p) }
    }

    func dismiss() {
        autoHide?.cancel()
        profile = nil
        panel.orderOut(nil)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Small keycap label, e.g. ⌃3 or esc.
struct Keycap: View {
    let text: String
    var onColor = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(onColor ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .foregroundStyle(onColor ? Color.white.opacity(0.9) : Color.secondary)
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color?
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(fill == nil ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Capsule(style: .continuous).fill(fill ?? Color.primary.opacity(0.07)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(fill == nil ? 0 : 0.18)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct OpenPromptView: View {
    let profile: Profile
    let emoji: String
    let shortcut: Int?
    let onOpen: () -> Void
    let onCancel: () -> Void
    @State private var shown = false

    private var tint: Color { Color(nsColor: profile.color ?? .systemGray) }
    private var buttonFill: Color {
        profile.color.map { Color(nsColor: $0) } ?? Color(nsColor: .darkGray)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)],
                                         center: .topLeading, startRadius: 2, endRadius: 70))
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if emoji.isEmpty {
                    Circle().fill(.white.opacity(0.92)).frame(width: 16, height: 16)
                } else {
                    Text(emoji).font(.system(size: 32))
                }
            }
            .frame(width: 64, height: 64)
            .shadow(color: tint.opacity(0.45), radius: 14, y: 6)
            .padding(.top, 6)

            VStack(spacing: 4) {
                Text("Open \(profile.name)?")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("This space has no window yet.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(action: onCancel) {
                    HStack(spacing: 6) { Text("Cancel"); Keycap(text: "esc") }
                }
                .buttonStyle(PillButtonStyle(fill: nil))
                Button(action: onOpen) {
                    HStack(spacing: 6) { Text("Open"); Keycap(text: shortcut.map { "⌃\($0)" } ?? "↩", onColor: true) }
                }
                .buttonStyle(PillButtonStyle(fill: buttonFill))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
        .frame(width: 300)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.06), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .scaleEffect(shown ? 1 : 0.94)
        .padding(36) // room for the shadow
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { shown = true } }
    }
}
