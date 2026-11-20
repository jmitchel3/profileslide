# Chrome Profile Swipe

Arc-style space switching for Google Chrome on macOS. Swipe sideways with two fingers (trackpad or Magic Mouse) on Chrome's vertical tab sidebar to move between Chrome profiles. A row of profile icons sits at the bottom of the sidebar, like Arc's space dots.

- Swipe left or right on the sidebar to bring the next or previous open profile's window to the front.
- Profile dots at the bottom of the sidebar: open profiles in color, closed ones grayed out. Click a dot to jump to that profile, or to open a closed one in a window matching the current one.
- An emoji per profile, custom order, and hide profiles you don't use.
- Runs invisibly in the background: no Dock icon, no menu bar icon. Swipes everywhere else (web pages, other apps) behave normally.

## Requirements

- macOS 13 or later
- Google Chrome with vertical tabs turned on
- Xcode command line tools (`xcode-select --install`) to build

## Build and run

```sh
./build.sh
open build/ChromeProfileSwipe.app
```

On first launch macOS asks for **Accessibility** permission (System Settings → Privacy & Security → Accessibility). The app needs it to see swipes and to read and raise Chrome's windows. It starts working as soon as you allow it.

To keep the permission across rebuilds, sign with a stable identity. `build.sh` uses a local self-signed identity in `~/Library/Application Support/ChromeProfileSwipe/signing/signing.keychain-db` if one exists, and otherwise falls back to ad-hoc signing (macOS then asks again after each rebuild).

## Settings

Open the app again (Spotlight, Finder) while it's running, or right-click the profile dots and choose **Settings…**. While Settings is open the app has a Dock icon; closing the window or pressing ⌘Q sends it back to the background. **Quit Completely** (or ⌥⌘Q) stops it.

Settings are stored in `~/Library/Application Support/ChromeProfileSwipe/config.json`:

```json
{
  "profiles": [
    { "match": "me@example.com", "emoji": "🎮", "hidden": false },
    { "match": "Work", "emoji": "💼", "hidden": false }
  ]
}
```

`match` is the profile's signed-in Google account email or its Chrome profile name. The list order is the dot and swipe order. Profiles not listed follow in Chrome's order. An empty `emoji` draws a dot in the profile's theme color.

Logs: `~/Library/Logs/ChromeProfileSwipe/poc.log`.

## How it works

- A session event tap watches scroll gestures. It only acts when Chrome is frontmost and the gesture starts over Chrome's vertical tab strip, which Chrome exposes to the Accessibility API as a tall `AXTabGroup`. Its live frame is used, so resizing the sidebar just works.
- Chrome suffixes window titles with the profile name when more than one profile exists. That maps windows to profiles listed in Chrome's `Local State` file.
- Profile colors come from each profile's theme in its `Preferences` file.
- The dots are a borderless, non-activating panel positioned over the bottom of the sidebar.

## License

MIT
