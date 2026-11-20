import Cocoa

// Exercise the event-tap handlers without posting any input to the desktop.
struct Browser { var isActive = true }
func chromeApp() -> Browser? { Browser() }
func shortcutsEnabled() -> Bool { true }
func orderedProfiles() -> [String] { ["Work", "Home"] }

final class OpenPrompt {
    static let shared = OpenPrompt()
    var isVisible = false
    var confirmations = 0
    var clickInside = false
    func dismiss() { isVisible = false }
    func confirm() { confirmations += 1; dismiss() }
    func receivesMouseDown(_ event: CGEvent) -> Bool { isVisible && clickInside }
}

func selectProfile(at index: Int, in profiles: [String]) { OpenPrompt.shared.isVisible = true }

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    event.flags = flags
    return event
}

let prompt = OpenPrompt.shared
let enter = key(36)
let shortcut = key(19, .maskControl)
for browserKey in [key(0), key(37, .maskCommand), key(9, .maskCommand), key(20, .maskControl), key(36, .maskShift)] {
    prompt.isVisible = true
    precondition(handleKey(browserKey) === browserKey && !prompt.isVisible)
    precondition(handleKey(enter) === enter && prompt.confirmations == 0)
}

for button: (CGEventType, CGMouseButton) in [(.leftMouseDown, .left), (.rightMouseDown, .right), (.otherMouseDown, .center)] {
    let click = CGEvent(mouseEventSource: nil, mouseType: button.0, mouseCursorPosition: .zero, mouseButton: button.1)!
    prompt.isVisible = true
    prompt.clickInside = true
    precondition(handleMouseDown(click) === click && prompt.isVisible)
    prompt.clickInside = false
    precondition(handleMouseDown(click) === click && !prompt.isVisible)
    precondition(handleKey(enter) === enter && prompt.confirmations == 0)
}

// Input arriving before a deferred selection gets to display the prompt.
precondition(handleKey(shortcut) == nil)
let letter = key(0)
precondition(handleKey(letter) === letter)
DispatchQueue.main.async {
    precondition(!prompt.isVisible && handleKey(enter) === enter)
    precondition(handleKey(shortcut) == nil)
    DispatchQueue.main.async {
        precondition(prompt.isVisible && handleKey(enter) == nil && prompt.confirmations == 1)
        prompt.isVisible = true
        precondition(handleKey(key(53)) == nil && !prompt.isVisible && prompt.confirmations == 1)
        print("Prompt input replays passed")
        exit(0)
    }
}
dispatchMain()
