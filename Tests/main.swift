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
