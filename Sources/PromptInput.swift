import CoreGraphics
import Dispatch

private let digitKeyCodes: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
private let keyReturn: Int64 = 36, keyEnter: Int64 = 76, keyEscape: Int64 = 53

// The event tap runs on the main run loop. A later browser event can arrive
// before the queued shortcut or swipe has had a chance to present its prompt.
private var selectionGeneration: UInt = 0

func enqueueProfileSelection(_ select: @escaping () -> Void) {
    let generation = selectionGeneration
    DispatchQueue.main.async {
        if selectionGeneration == generation { select() }
    }
}

func cancelProfileInput() {
    selectionGeneration &+= 1
    if OpenPrompt.shared.isVisible { OpenPrompt.shared.dismiss() }
}

func handleKey(_ event: CGEvent) -> CGEvent? {
    guard chromeApp()?.isActive == true else { return event }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    let prompt = OpenPrompt.shared

    if prompt.isVisible && mods.isEmpty {
        if code == keyReturn || code == keyEnter { prompt.confirm(); return nil }
        if code == keyEscape { cancelProfileInput(); return nil }
    }

    if mods == .maskControl, let n = digitKeyCodes[code], shortcutsEnabled() {
        let profiles = orderedProfiles()
        if n <= profiles.count {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                enqueueProfileSelection { selectProfile(at: n - 1, in: profiles) }
            }
            return nil
        }
    }

    cancelProfileInput()
    return event
}

func handleMouseDown(_ event: CGEvent) -> CGEvent {
    if !OpenPrompt.shared.receivesMouseDown(event) { cancelProfileInput() }
    return event
}
