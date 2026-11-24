// Brief frosted-glass pill HUD shown on profile switches and actions, plus trackpad haptics.

import SwiftUI

func performSwitchHaptic() {
    guard preferences().hapticFeedback else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

final class SwitchHUD {
    static let shared = SwitchHUD()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    var windowNumber: Int { panel.windowNumber }

    /// Shows a brief banner centered near the top of `windowFrame` (AX top-left coordinates).
    func show(profile: Profile, profiles: [Profile], openDirs: Set<String>,
              subtitle: String? = nil, over windowFrame: CGRect?, duration: TimeInterval? = nil) {
        guard preferences().showSwitchHUD || subtitle != nil else { return }
        let view = SwitchHUDView(profile: profile, profiles: profiles, openDirs: openDirs, subtitle: subtitle)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin: CGPoint
        if let f = windowFrame {
            // Place cleanly in the upper-middle region of the Chrome window (below toolbar)
            let yTop = primaryHeight - f.minY
            let targetY = max(primaryHeight - f.maxY + 24, yTop - size.height - 64)
            origin = CGPoint(x: f.midX - size.width / 2, y: targetY)
        } else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            origin = CGPoint(x: s.midX - size.width / 2, y: s.maxY - size.height - 80)
        }

        hideWork?.cancel()
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }

        let delay: TimeInterval = duration ?? (subtitle == nil ? 1.05 : 1.65)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismiss() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

struct SwitchHUDView: View {
    let profile: Profile
    let profiles: [Profile]
    let openDirs: Set<String>
    let subtitle: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var tint: Color { Color(nsColor: profile.color ?? .systemBlue) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.95), tint.opacity(0.72)],
                                         center: .topLeading, startRadius: 1, endRadius: 34))
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
                if profile.settings.emoji.isEmpty {
                    Circle().fill(.white.opacity(0.92)).frame(width: 10, height: 10)
                } else {
                    Text(profile.settings.emoji).font(.system(size: 18))
                }
            }
            .frame(width: 34, height: 34)
            .shadow(color: tint.opacity(0.35), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if profiles.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(Array(profiles.prefix(12).enumerated()), id: \.offset) { _, item in
                            let isCurrent = item.dir == profile.dir
                            let isOpen = openDirs.contains(item.dir) || isCurrent
                            let dotColor = Color(nsColor: item.color ?? .secondaryLabelColor)
                            Capsule(style: .continuous)
                                .fill(isCurrent ? dotColor : (isOpen ? dotColor.opacity(0.45) : Color.secondary.opacity(0.28)))
                                .frame(width: isCurrent ? 14 : 5, height: 5)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.05), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
        )
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.32), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .padding(24) // shadow room
        .onAppear {
            if !reduceMotion {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) { appeared = true }
            }
        }
    }
}
