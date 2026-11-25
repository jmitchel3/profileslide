import Foundation

// Replay a sidebar swipe with no momentum, immediately followed by a vertical page scroll.
var gesture = ScrollGesture()
func scroll(_ phase: Int64, _ momentum: Int64 = 0, dx: Double = 0, dy: Double = 0,
            sidebar: Bool = false) -> ScrollGesture.Action {
    gesture.handle(phase: phase, momentum: momentum, dx: dx, dy: dy, overSidebar: sidebar)
}
precondition(scroll(1, dx: 45, sidebar: true) == .switchProfile(-1))
precondition(scroll(4, sidebar: true) == .suppress)
precondition(scroll(1, dy: 25) == .pass)
precondition(scroll(4) == .pass)
precondition(scroll(0, 1, dy: 12) == .pass)
precondition(scroll(0, 2, dy: 8) == .pass)
precondition(scroll(0, 3) == .pass)

// The initial hit test sticks through mayBegin -> began, even if the pointer moves.
precondition(scroll(128, sidebar: true) == .pass)
precondition(scroll(1, dx: -45) == .switchProfile(1))
precondition(scroll(2, dx: -50) == .suppress)
precondition(scroll(4) == .suppress)
for phase: Int64 in [1, 2, 3] { precondition(scroll(0, phase) == .suppress) }
precondition(scroll(0, 1) == .pass)

// Both a fresh mayBegin and losing focus release pending momentum.
precondition(scroll(1, dx: 45, sidebar: true) == .switchProfile(-1))
precondition(scroll(4) == .suppress)
precondition(scroll(128) == .pass)
precondition(scroll(1, dy: 25, sidebar: true) == .pass)
precondition(scroll(4) == .pass)
precondition(scroll(0, 1) == .pass)
precondition(scroll(1, dx: 45, sidebar: true) == .switchProfile(-1))
gesture = ScrollGesture()
precondition(scroll(0, 2) == .pass)
precondition(scroll(2, dx: 60, sidebar: true) == .pass)
precondition(scroll(0, dy: 50, sidebar: true) == .pass)
print("Gesture replays passed")

let ada = Profile(dir: "Default", name: "Work", email: "one@example.com", color: nil, accountName: "Ada")
let grace = Profile(dir: "Profile 2", name: "Work", email: "two@example.com", color: nil, accountName: "Grace")
let personal = Profile(dir: "Profile 3", name: "Home", email: "", color: nil, accountName: nil)
let profiles = [ada, grace, personal]
// Two closed profiles after Ada: move through the prompts, reverse, or wrap back to Ada.
func swipe(_ direction: Int, pending: String? = nil, focused: String? = ada.dir) -> Int? {
    adjacentProfileIndex(in: profiles, direction: direction, pending: pending, focused: focused)
}
precondition(swipe(1) == 1)
precondition(swipe(1, pending: grace.dir) == 2)
precondition(swipe(-1, pending: personal.dir) == 1)
precondition(swipe(1, pending: personal.dir) == 0)
precondition(swipe(-1) == 2)
precondition(swipe(1, pending: "removed") == 1)
precondition(swipe(1, focused: nil) == nil && swipe(-1, focused: nil) == nil)
precondition(swipe(1, focused: "hidden") == 0 && swipe(-1, focused: "hidden") == 2)
precondition(adjacentProfileIndex(in: [ada], direction: 1, pending: nil, focused: ada.dir) == nil)
print("Swipe navigation checks passed")

// Swipes and shortcuts use the same decision when the selected profile has no window.
func selectClosed(_ dir: String, index: Int = 1, pending: String? = nil, shortcuts: Bool = true) -> ClosedProfileAction {
    ClosedProfileAction(selecting: dir, at: index, pending: pending, shortcutsEnabled: shortcuts)
}
precondition(selectClosed(grace.dir) == .ask(shortcut: 2))
precondition(selectClosed(grace.dir, pending: grace.dir) == .open)
precondition(selectClosed(personal.dir, index: 2, pending: grace.dir) == .ask(shortcut: 3))
precondition(selectClosed(grace.dir, shortcuts: false) == .ask(shortcut: nil))
precondition(selectClosed(grace.dir, index: 9) == .ask(shortcut: nil))
print("Closed profile prompt checks passed")

func resolve(_ suffix: String, in all: [Profile] = profiles) -> String? {
    profileDir(forWindowTitle: "Docs - Google Chrome - " + suffix, all)
}
precondition(resolve("Ada (Work)") == ada.dir)
precondition(resolve("Grace (Work)") == grace.dir)
precondition(resolve("Work") == nil)
precondition(resolve("Unknown (Work)") == nil)
precondition(resolve("Ada") == ada.dir)
precondition(resolve("Home") == personal.dir)
precondition(profileDir(forWindowTitle: "Docs", profiles) == nil)
let sameAccountName = Profile(dir: "Profile 4", name: "Work", email: "", color: nil, accountName: "Grace")
precondition(resolve("Grace (Work)", in: profiles + [sameAccountName]) == nil)

// Chrome labels the personal window "Ada" and the other window "Ada (Work)".
let home = Profile(dir: "Home", name: "Ada", email: "", color: nil, accountName: "Ada")
let shared = [home, ada]
let focusedHome = resolve("Ada", in: shared)
precondition(focusedHome == home.dir)
precondition(resolve("Ada (Work)", in: shared) == ada.dir)
precondition(adjacentProfileIndex(in: shared, direction: 1, pending: nil, focused: focusedHome) == 1)
let defaultName = Profile(dir: "DefaultName", name: "Person 1", email: "", color: nil,
                          accountName: "Ada", usesDefaultName: true)
precondition(resolve("Ada", in: [defaultName, ada]) == defaultName.dir)
precondition(resolve("Ada (Person 1)", in: [defaultName, home]) == defaultName.dir)
let managed = Profile(dir: "Managed", name: "Person 2", email: "", color: nil,
                      accountName: "Ada", usesDefaultName: true, enterpriseLabel: "Company")
precondition(resolve("Ada (Company)", in: [home, managed]) == managed.dir)
let unsigned = Profile(dir: "Unsigned", name: "Ada", email: "", color: nil, accountName: nil)
precondition(resolve("Ada", in: shared + [unsigned]) == nil)
print("Window title checks passed")

func settings(_ json: [String: Any]) -> ConfigEntry { ConfigEntry(json: json)! }
let oldEmail = settings(["match": "TWO@EXAMPLE.COM", "opens": "pages", "pages": ["https://example.com"]])
let oldName = settings(["match": "HOME", "emoji": "🏡"])
let ambiguous = settings(["match": "Work", "hidden": true])
let ordered = configure(profiles, with: [ambiguous, oldEmail, oldName])
precondition(ordered.map(\.dir) == [grace.dir, personal.dir, ada.dir])
precondition(ordered[0].settings.pages == ["https://example.com"])
precondition(ordered[0].settings.opens == .pages && ordered[1].settings.emoji == "🏡")
precondition(ordered.allSatisfy { !$0.settings.hidden })
let exact = settings(["dir": grace.dir, "emoji": "💼", "hidden": true, "opens": "lastSession"])
let renamed = Profile(dir: grace.dir, name: "Business", email: "", color: nil, accountName: nil)
let stable = configure([ada, renamed], with: [oldEmail, settings(exact.json)])
precondition(stable[0].dir == grace.dir && stable[0].settings.emoji == "💼")
precondition(stable[0].settings.hidden && stable[0].settings.opens == .lastSession)
precondition(configure(profiles, with: [oldEmail, exact])[0].settings.hidden)
precondition(resolve("Work", in: configure(profiles, with: [exact])) == nil)
precondition(settings(["dir": "Gone", "match": "home"]).profile(in: profiles) == nil)
print("Profile settings checks passed")

// Gesture sensitivity, reverse direction, and live swipe progress.
var customGesture = ScrollGesture()
precondition(customGesture.handle(phase: 1, momentum: 0, dx: 20, dy: 0, threshold: 40, reversed: false, overSidebar: true) == .suppress)
precondition(abs(customGesture.progress - 0.5) < 0.001)
precondition(customGesture.handle(phase: 2, momentum: 0, dx: 25, dy: 0, threshold: 40, reversed: false, overSidebar: true) == .switchProfile(-1))
precondition(customGesture.progress == 0)
precondition(customGesture.handle(phase: 4, momentum: 0, dx: 0, dy: 0, threshold: 40, reversed: false, overSidebar: true) == .suppress)

var lightGesture = ScrollGesture()
precondition(lightGesture.handle(phase: 1, momentum: 0, dx: -30, dy: 0, threshold: SwipeSensitivity.light.threshold, reversed: false, overSidebar: true) == .switchProfile(1))
var firmGesture = ScrollGesture()
precondition(firmGesture.handle(phase: 1, momentum: 0, dx: -45, dy: 0, threshold: SwipeSensitivity.firm.threshold, reversed: false, overSidebar: true) == .suppress)
precondition(firmGesture.handle(phase: 2, momentum: 0, dx: -20, dy: 0, threshold: SwipeSensitivity.firm.threshold, reversed: false, overSidebar: true) == .switchProfile(1))
var reversedGesture = ScrollGesture()
precondition(reversedGesture.handle(phase: 1, momentum: 0, dx: 45, dy: 0, threshold: 40, reversed: true, overSidebar: true) == .switchProfile(1))
print("Gesture sensitivity & progress checks passed")

// Preferences round-trip and ClosedProfileAction confirmClosed toggle.
var prefs = AppPreferences()
precondition(prefs.syncWindowFrame && prefs.showSwitchHUD && prefs.hapticFeedback && prefs.confirmClosedProfiles)
precondition(!prefs.showMenuBarItem)
precondition(!AppPreferences(json: [:]).showMenuBarItem)
prefs.syncWindowFrame = false
prefs.swipeSensitivity = .firm
prefs.reverseSwipe = true
prefs.confirmClosedProfiles = false
prefs.showMenuBarItem = true
let decodedPrefs = AppPreferences(json: prefs.jsonFields)
precondition(decodedPrefs == prefs)
precondition(ClosedProfileAction(selecting: grace.dir, at: 1, pending: nil, shortcutsEnabled: true, confirmClosed: false) == .open)
print("Preferences checks passed")

// Fuzzy Quick Switcher filtering.
var workP = Profile(dir: "Default", name: "Work", email: "alex@company.com", color: nil, accountName: nil)
workP.settings.emoji = "💼"
var personalP = Profile(dir: "Profile 2", name: "Personal", email: "alex@gmail.com", color: nil, accountName: nil)
personalP.settings.emoji = "🏠"
var sideP = Profile(dir: "Profile 3", name: "Side Project", email: "dev@example.com", color: nil, accountName: nil)
sideP.settings.emoji = "🚀"
let catalog = [workP, personalP, sideP]
precondition(filterProfiles(catalog, query: "").map(\.dir) == [workP.dir, personalP.dir, sideP.dir])
precondition(filterProfiles(catalog, query: "wk").map(\.dir) == [workP.dir])
precondition(filterProfiles(catalog, query: "gmail").map(\.dir) == [personalP.dir])
precondition(filterProfiles(catalog, query: "proj").map(\.dir) == [sideP.dir])
precondition(filterProfiles(catalog, query: "🚀").map(\.dir) == [sideP.dir])
precondition(filterProfiles(catalog, query: "zzzz").isEmpty)
print("Quick Switcher fuzzy filter checks passed")

// Unified Window Mode same-display frame sync logic.
let screen1 = CGRect(x: 0, y: 0, width: 1512, height: 982)
let screen2 = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
let srcOn1 = CGRect(x: 100, y: 80, width: 1200, height: 800)
let dstOn1 = CGRect(x: 200, y: 120, width: 1000, height: 700)
let dstOn2 = CGRect(x: 1700, y: 100, width: 1400, height: 900)
precondition(shouldSyncWindowFrame(source: srcOn1, target: dstOn1, screens: [screen1, screen2], sourceFullscreen: false, targetFullscreen: false))
precondition(!shouldSyncWindowFrame(source: srcOn1, target: srcOn1, screens: [screen1, screen2], sourceFullscreen: false, targetFullscreen: false))
precondition(!shouldSyncWindowFrame(source: srcOn1, target: dstOn2, screens: [screen1, screen2], sourceFullscreen: false, targetFullscreen: false))
precondition(!shouldSyncWindowFrame(source: srcOn1, target: dstOn1, screens: [screen1, screen2], sourceFullscreen: true, targetFullscreen: false))
precondition(!shouldSyncWindowFrame(source: srcOn1, target: dstOn1, screens: [screen1, screen2], sourceFullscreen: false, targetFullscreen: true))
precondition(shouldSyncWindowFrame(source: srcOn1, target: dstOn2, screens: [screen1, screen2], sourceFullscreen: false, targetFullscreen: false, targetMinimized: true))
print("Unified window sync checks passed")

// Tab window matching under identical window frames (Unified Window Mode).
let sharedFrame = CGRect(x: 100, y: 80, width: 1200, height: 800)
let axWins = [
    AXWindowDescriptor(dir: "Default", frame: sharedFrame, title: "Inbox - Google Chrome - Ada (Work)"),
    AXWindowDescriptor(dir: "Profile 2", frame: sharedFrame, title: "Inbox - Google Chrome - Grace (Work)"),
    AXWindowDescriptor(dir: "Profile 3", frame: sharedFrame, title: "Docs - Google Chrome - Home"),
]
let scriptWins = [
    ScriptWindowDescriptor(frame: sharedFrame, activeTitle: "Inbox", urls: ["https://mail.work.com", "chrome://newtab/"]),
    ScriptWindowDescriptor(frame: sharedFrame, activeTitle: "Inbox", urls: ["https://mail.grace.com"]),
    ScriptWindowDescriptor(frame: sharedFrame, activeTitle: "Docs", urls: ["https://docs.home.com"]),
]
let matched = matchTabWindows(axWindows: axWins, scriptWindows: scriptWins)
precondition(matched["Default"] == ["https://mail.work.com"])
precondition(matched["Profile 2"] == ["https://mail.grace.com"])
precondition(matched["Profile 3"] == ["https://docs.home.com"])
print("Tab window matching checks passed")

// Chrome Profiles menu title matching & ambiguity rejection.
precondition(uniqueProfileMenuTitle(for: ada, in: profiles) == "Ada (Work)")
precondition(uniqueProfileMenuTitle(for: grace, in: profiles) == "Grace (Work)")
precondition(uniqueProfileMenuTitle(for: personal, in: profiles) == "Home")
precondition(uniqueProfileMenuTitle(for: grace, in: profiles + [sameAccountName]) == nil)
precondition(uniqueProfileMenuTitle(for: home, in: shared) == "Ada")
precondition(uniqueProfileMenuTitle(for: managed, in: [home, managed]) == "Ada (Company)")
print("Profiles menu title checks passed")

// Pending profile open tracking: duplicate suppression, expiry, swipe-past, and focus cancel.
var pendingTracker = PendingOpenTracker()
let t0 = Date(timeIntervalSince1970: 1000)
pendingTracker.begin(dir: grace.dir, at: t0, timeout: 8.0)
precondition(pendingTracker.activeDir(at: t0.addingTimeInterval(2.0)) == grace.dir)
precondition(pendingTracker.shouldSuppressDuplicateOpen(for: grace.dir, hasExistingWindow: false, at: t0.addingTimeInterval(2.0)))
precondition(!pendingTracker.shouldSuppressDuplicateOpen(for: grace.dir, hasExistingWindow: true, at: t0.addingTimeInterval(2.0)))
precondition(!pendingTracker.shouldSuppressDuplicateOpen(for: personal.dir, hasExistingWindow: false, at: t0.addingTimeInterval(2.0)))
precondition(adjacentProfileIndex(in: profiles, direction: 1, pending: pendingTracker.activeDir(at: t0.addingTimeInterval(1.0)), focused: ada.dir) == 2)
pendingTracker.cancelFocusIfDifferent(than: personal.dir)
precondition(pendingTracker.current?.shouldFocus == false)
precondition(pendingTracker.activeDir(at: t0.addingTimeInterval(8.1)) == nil)
precondition(!pendingTracker.shouldSuppressDuplicateOpen(for: grace.dir, hasExistingWindow: false, at: t0.addingTimeInterval(8.1)))
pendingTracker.clear(ifDir: ada.dir)
precondition(pendingTracker.current != nil)
pendingTracker.clear(ifDir: grace.dir)
precondition(pendingTracker.current == nil)
print("Pending profile open checks passed")
