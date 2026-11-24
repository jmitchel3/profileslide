import Cocoa

// Exercise the event-tap handlers without posting any input to the desktop.
struct Browser { var isActive = true }
var chromeActive = true
func chromeApp() -> Browser? { Browser(isActive: chromeActive) }
func shortcutsEnabled() -> Bool { true }
func arrowShortcutsEnabled() -> Bool { true }
func quickSwitcherEnabled() -> Bool { true }
func globalQuickSwitcherEnabled() -> Bool { true }
func orderedProfiles() -> [String] { ["Work", "Home"] }

var switchedDirections: [Int] = []
func switchProfile(direction: Int) { switchedDirections.append(direction) }

final class OpenPrompt {
    static let shared = OpenPrompt()
    var isVisible = false
    var confirmations = 0
    var clickInside = false
    func dismiss() { isVisible = false }
    func confirm() { confirmations += 1; dismiss() }
    func receivesMouseDown(_ event: CGEvent) -> Bool { isVisible && clickInside }
}

final class QuickSwitcher {
    static let shared = QuickSwitcher()
    var isVisible = false
    var clickInside = false
    var lastGlobal: Bool?
    var selectionMoves: [Int] = []
    var query = ""
    var confirmedMoveTab: Bool?
    var sleepCalls = 0
    func toggle(global: Bool) { lastGlobal = global; isVisible.toggle() }
    func dismiss() { isVisible = false }
    func moveSelection(by delta: Int) { selectionMoves.append(delta) }
    func appendText(_ text: String) { query.append(text) }
    func backspace() { if !query.isEmpty { query.removeLast() } }
    func confirmSelection(moveTab: Bool = false) { confirmedMoveTab = moveTab; dismiss() }
    func sleepSelection() { sleepCalls += 1; dismiss() }
    func receivesMouseDown(_ event: CGEvent) -> Bool { isVisible && clickInside }
}

func selectProfile(at index: Int, in profiles: [String]) { OpenPrompt.shared.isVisible = true }

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    event.flags = flags
    return event
}

let prompt = OpenPrompt.shared
let switcher = QuickSwitcher.shared
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

// Quick Switcher input handling & global hotkey (even when Chrome is inactive).
chromeActive = false
let globalToggle = key(49, [.maskControl, .maskAlternate])
precondition(handleKey(globalToggle) == nil)
switcher.isVisible = true
precondition(handleKey(key(125)) == nil) // down
precondition(handleKey(key(126)) == nil) // up
precondition(switcher.selectionMoves == [1, -1])
let letterA = key(0)
var ch: UniChar = 97 // 'a'
letterA.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
precondition(handleKey(letterA) == nil && switcher.query == "a")
precondition(handleKey(key(51)) == nil && switcher.query == "") // backspace
precondition(handleKey(key(36, .maskShift)) == nil && !switcher.isVisible && switcher.confirmedMoveTab == true)

switcher.isVisible = true
precondition(handleKey(key(13, .maskCommand)) == nil && !switcher.isVisible && switcher.sleepCalls == 1)

switcher.isVisible = true
let clickOutside = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
switcher.clickInside = true
precondition(handleMouseDown(clickOutside) === clickOutside && switcher.isVisible)
switcher.clickInside = false
precondition(handleMouseDown(clickOutside) === clickOutside && !switcher.isVisible)

chromeActive = true
// Adjacent cycling with ⌃← / ⌃→
precondition(handleKey(key(124, .maskControl)) == nil)
precondition(handleKey(key(123, .maskControl)) == nil)

// Input arriving before a deferred selection gets to display the prompt.
precondition(handleKey(shortcut) == nil)
let letter = key(0)
precondition(handleKey(letter) === letter)
DispatchQueue.main.async {
    precondition(!prompt.isVisible && !switcher.isVisible && handleKey(enter) === enter)
    precondition(handleKey(key(124, .maskControl)) == nil)
    precondition(handleKey(key(123, .maskControl)) == nil)
    precondition(handleKey(shortcut) == nil)
    DispatchQueue.main.async {
        precondition(switchedDirections == [1, -1])
        precondition(prompt.isVisible && handleKey(enter) == nil && prompt.confirmations == 1)
        prompt.isVisible = true
        precondition(handleKey(key(53)) == nil && !prompt.isVisible && prompt.confirmations == 1)
        print("Prompt input replays passed")
        exit(0)
    }
}
dispatchMain()
