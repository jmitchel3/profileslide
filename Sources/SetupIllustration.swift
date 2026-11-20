import SwiftUI

/// Small, local illustrations of the controls the user will see in Chrome and macOS.
struct SetupIllustration: View {
    let step: SetupStep
    var openingDot = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tint = Color.indigo

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [tint.opacity(0.09), Color.teal.opacity(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            switch step {
            case .tabs:
                HStack(spacing: 14) {
                    browser(vertical: false)
                    Image(systemName: "arrow.right").font(.title3.bold()).foregroundStyle(tint)
                    browser(vertical: true)
                }
            case .accessibility:
                VStack(alignment: .leading, spacing: 9) {
                    Text("Privacy & Security").font(.caption).foregroundStyle(.secondary)
                    Label("Accessibility", systemImage: "accessibility").font(.headline)
                    Divider()
                    HStack {
                        AppIconTile().scaleEffect(0.55).frame(width: 25, height: 25)
                        Text("ProfileSlide").font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 19, alignment: .leading).padding(.leading, 6)
                            .background(Capsule().fill(Color.accentColor))
                            .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
                    }
                }
                .padding(14).frame(width: 270).background(card)
            case .practice, .finished:
                if reduceMotion || openingDot {
                    browser(vertical: true, practice: true)
                } else {
                    PhaseAnimator([false, true]) { shifted in
                        browser(vertical: true, practice: true, shifted: shifted)
                    } animation: { _ in .easeInOut(duration: 1.6) }
                }
            }
        }
        .frame(height: 148)
        .accessibilityHidden(true) // The instructions below describe each illustration.
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
    }

    private func browser(vertical: Bool, practice: Bool = false, shifted: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach([Color.red, .yellow, .green].indices, id: \.self) { i in
                    Circle().fill([Color.red, .yellow, .green][i].opacity(0.75)).frame(width: 5, height: 5)
                }
                if !vertical {
                    tab("Mail", "envelope", selected: true)
                    tab("Notes", "doc.text", selected: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).frame(height: 22)
            Divider()
            HStack(spacing: 0) {
                if vertical {
                    VStack(alignment: .leading, spacing: 3) {
                        tab("Mail", "envelope", selected: true)
                        tab("Notes", "doc.text", selected: false)
                        Spacer(minLength: 0)
                        if practice {
                            Image(systemName: openingDot ? "cursorarrow" : "arrow.left.and.right")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(tint)
                                .frame(maxWidth: .infinity)
                                .offset(x: openingDot ? 8 : (shifted ? 10 : -10))
                            HStack(spacing: 9) {
                                Circle().fill(tint).frame(width: shifted ? 6 : 9, height: shifted ? 6 : 9)
                                Circle().strokeBorder(Color.teal, lineWidth: 1.5)
                                    .background(Circle().fill(openingDot ? Color.clear : Color.teal))
                                    .frame(width: shifted ? 9 : 6, height: shifted ? 9 : 6)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(5).frame(width: practice ? 90 : 64)
                    .background(tint.opacity(0.08))
                    Divider()
                }
                VStack(alignment: .leading, spacing: 5) {
                    if practice {
                        Text(shifted ? "Work" : "Personal")
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach([0.58, 0.90, 0.72], id: \.self) { fraction in
                        GeometryReader { proxy in
                            Capsule().fill((shifted ? Color.teal : tint).opacity(0.23))
                                .frame(width: proxy.size.width * fraction)
                        }
                        .frame(height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: practice ? 258 : 164, height: practice ? 118 : 100)
        .background(card)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func tab(_ name: String, _ symbol: String, selected: Bool) -> some View {
        Label(name, systemImage: symbol)
            .font(.system(size: 9, weight: .medium)).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(selected ? 0.16 : 0)))
    }
}
