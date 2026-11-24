import CoreGraphics
import Dispatch

private let digitKeyCodes: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
private let keyReturn: Int64 = 36, keyEnter: Int64 = 76, keyEscape: Int64 = 53
private let keySpace: Int64 = 49, keyDelete: Int64 = 51, keyTab: Int64 = 48
private let keyLeft: Int64 = 123, keyRight: Int64 = 124, keyDown: Int64 = 125, keyUp: Int64 = 126
private let keyW: Int64 = 13, keyP: Int64 = 35, keyN: Int64 = 45

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
    if QuickSwitcher.shared.isVisible { QuickSwitcher.shared.dismiss() }
}

private func typedCharacters(from event: CGEvent) -> String? {
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return nil }
    let str = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
    let filtered = str.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
    guard !filtered.isEmpty else { return nil }
    return String(String.UnicodeScalarView(filtered))
}

func handleKey(_ event: CGEvent) -> CGEvent? {
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let switcher = QuickSwitcher.shared

    // Global Quick Switcher hotkey: ⌥⌃Space works from any app.
    if mods == [.maskControl, .maskAlternate], code == keySpace, globalQuickSwitcherEnabled() {
        if !isRepeat {
            enqueueProfileSelection { switcher.toggle(global: true) }
        }
        return nil
    }

    // While the Quick Switcher is open, capture navigation and filter typing cleanly.
    if switcher.isVisible {
        if code == keyEscape {
            switcher.dismiss()
            return nil
        }
        if code == keySpace && (mods == .maskControl || mods == [.maskControl, .maskAlternate]) {
            if !isRepeat { switcher.dismiss() }
            return nil
        }
        if code == keyReturn || code == keyEnter {
            if mods.isEmpty || mods == .maskShift {
                let moveTab = mods == .maskShift
                switcher.confirmSelection(moveTab: moveTab)
                return nil
            }
        }
        if code == keyDown || (mods == .maskControl && code == keyN) || (mods.isEmpty && code == keyTab) {
            switcher.moveSelection(by: 1)
            return nil
        }
        if code == keyUp || (mods == .maskControl && code == keyP) || (mods == .maskShift && code == keyTab) {
            switcher.moveSelection(by: -1)
            return nil
        }
        if mods == .maskCommand && code == keyW {
            if !isRepeat { switcher.sleepSelection() }
            return nil
        }
        if code == keyDelete && mods.isEmpty {
            switcher.backspace()
            return nil
        }
        if mods.isEmpty || mods == .maskShift, let text = typedCharacters(from: event) {
            switcher.appendText(text)
            return nil
        }
        return nil
    }

    guard chromeApp()?.isActive == true else { return event }

    // In-Chrome Quick Switcher: ⌃Space
    if mods == .maskControl, code == keySpace, quickSwitcherEnabled() {
        if !isRepeat {
            enqueueProfileSelection { switcher.toggle(global: false) }
        }
        return nil
    }

    let prompt = OpenPrompt.shared

    if prompt.isVisible && mods.isEmpty {
        if code == keyReturn || code == keyEnter { prompt.confirm(); return nil }
        if code == keyEscape { cancelProfileInput(); return nil }
    }

    // Adjacent profile cycling: ⌃← / ⌃→
    if mods == .maskControl, (code == keyLeft || code == keyRight), arrowShortcutsEnabled() {
        if !isRepeat {
            let direction = code == keyRight ? 1 : -1
            enqueueProfileSelection { switchProfile(direction: direction) }
        }
        return nil
    }

    // Direct jump: ⌃1 – ⌃9
    if mods == .maskControl, let n = digitKeyCodes[code], shortcutsEnabled() {
        let profiles = orderedProfiles()
        if n <= profiles.count {
            if !isRepeat {
                enqueueProfileSelection { selectProfile(at: n - 1, in: profiles) }
            }
            return nil
        }
    }

    cancelProfileInput()
    return event
}

func handleMouseDown(_ event: CGEvent) -> CGEvent {
    let inPrompt = OpenPrompt.shared.receivesMouseDown(event)
    let inSwitcher = QuickSwitcher.shared.receivesMouseDown(event)
    if !inPrompt && !inSwitcher { cancelProfileInput() }
    return event
}
