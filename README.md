# QuickShot

A small macOS app for screenshots and screen recordings. Screenshots use the system crosshair (the same one as Command Shift 4) or take the whole screen; recordings cover the screen, an area, or one app. Every capture is filed into one local folder, copied to the clipboard, and shown in one window: three buttons and your recent captures.

## Use

| To do this | Do this |
|---|---|
| Capture the whole screen | Press Control Option F in any app, or click **Full Screen**. Every display, no picker |
| Capture an area | Press Control Option S in any app, or click **Area**. Drag over the area, or press Space and click a window |
| Record | Click **Record** and choose **Entire Screen**, **Area** (drag it first) or **App or Window** (pick it in the system picker; only that app is in the movie). Control Option R repeats your last choice. A 3-2-1 count runs first unless you turn **Count Down** off in the Record menu |
| Choose the recording quality | **Quick** (small 1080p file, no audio; for bug reports and AI) or **Demo** (native resolution, microphone and system audio), under the buttons. Screen and Area recordings also mark mouse clicks; an App or Window recording shows the pointer only |
| Stop a recording | Press Control Option R again, click **Stop Recording**, or choose it from the menu bar item (it turns into a filled record dot) |
| Cancel | Press Escape in the crosshair, or **Cancel** during the count |
| Know it worked | A screenshot flashes a border around what was captured; every capture shows a notification (or brings the window forward when notifications are off) and is on the clipboard unless you turn that off in Settings. With more than one display, Full Screen copies the last screen's file |
| Copy a capture again | Select it, then Command C (or the copy symbol in the title bar) |
| Box the part that matters | Select a screenshot, then Command Return (or double-click it). Drag over content to draw a numbered box, as many as you need; click a box and press Delete to remove it; Command Z undoes. **Copy** (Command Return) saves a marked copy next to the original, puts it on the clipboard and selects it, ready to paste into a chat or bug report. Escape closes the editor and keeps your boxes for next time |
| Add arrows or text | Right-click the screenshot, **Open in Preview**, and use Markup |
| Trim a recording | Select it, then Command Return (opens QuickTime Player) |
| Find the file | Click **Open** beside the folder name at the bottom; or select a capture and click the folder symbol; or drag the card into another app |
| Remove a capture | Command Delete (moves it to the Trash) |
| Change the defaults | Command Comma (or **Settings…** in the menu bar item): screenshot fidelity (Lower halves Retina screenshots to their size in points, the default; High keeps every pixel), clipboard copying, recording preset, countdown |

Captures are saved to `~/Pictures/QuickShot`. That folder is the only record: files you add, rename or delete there in Finder show up in the window as they are.

The window sizes itself to its captures until you resize it; after that it keeps your size (the green button fills the screen). Selecting a capture shows four symbols in the title bar: copy, annotate (or open, for a recording), show in Finder, and move to Trash. Hover for the name; right-click a capture for the same actions with names. Marked copies carry a **Marked** chip and are named `<original> (marked).png`; the original is never changed. If a copy or a trash fails, the notice offers **Try Again**.

The menu bar item offers the same capture actions when the window is closed.

The shortcuts use Control Option on purpose: Snagit uses Control Shift S, R and V for its own captures and wins those keys whenever it is running.

## Clipboard library

QuickShot also keeps a history of what you copy. Press Control Option V in any app, or choose **Show Clipboard** from the menu bar item or the Dock menu.

| To do this | Do this |
|---|---|
| Find something you copied | Open the library; **History** lists text, images and files, newest first. Type in Search to filter |
| See it in full | Select it: the right pane shows the whole text, the image, or the file list |
| Use it again | **Copy** (Command C), then paste where you need it; or drag the row into another app |
| Keep it | **Add to Collection**. Items in a collection never expire. Deleting a saved item asks first |
| Put a copy somewhere else | **Save to Folder**. A copy is written to the folder you pick; the item stays in the library |
| See your captures here | **Captures** lists every screenshot and recording in `~/Pictures/QuickShot`, in place |
| Stop recording for a while | **Pause Clipboard History** in the menu bar item |

What is kept and what is not:

- History is stored on this Mac only, in `~/Library/Application Support/QuickShot/Clipboard` (an SQLite index plus image files).
- Items not in a collection are removed after 90 days. A single copy larger than 50 MB is not recorded.
- Copies marked as secret by the app that made them (the nspasteboard.org convention password managers use), and copies made while Keychain Access, Passwords or 1Password is or just was in front, are never read or stored.
- Pausing history is remembered when QuickShot restarts.
- QuickShot does not paste for you: that would need Accessibility permission.
- If macOS is set to deny QuickShot the clipboard (Privacy & Security, Paste from Other Apps), the library says so and records nothing.

## Build and install

Built and tested with Xcode 27.2 (Swift 6.4) on macOS 27. The package declares Swift tools 6.0 and a macOS 15 deployment target; older toolchains are untested.

```bash
scripts/build-app.sh             # builds build/QuickShot.app
scripts/build-app.sh --install   # also copies it to /Applications
swift test                       # runs the test suite
```

## Screen Recording permission

macOS only lets an app capture other apps' windows after you allow it:

1. Click **Turn On** in QuickShot's notice. macOS asks once and System Settings opens at the screen recording list. Turn on QuickShot there.
2. Click **Reopen QuickShot** in the notice.

Until then QuickShot refuses to capture, because macOS would otherwise hand back an image of only the desktop wallpaper.

A Demo recording also uses the microphone: macOS asks for that once, the first time.

By default the build script signs ad hoc, which never touches your Keychain; macOS then ties the permission to that exact build, so after each rebuild you would remove the old QuickShot entry in System Settings and allow the new one. The installed app on this Mac is signed with the owner's Apple Development identity instead, so the permission survives rebuilds. To do the same, sign with your own identity:

```bash
QUICKSHOT_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh --install
```

Recent macOS versions also ask from time to time whether an app may keep recording the screen.

## How it works

- `Sources/QuickShotCore` has no interface code. `CaptureRunner` runs `/usr/sbin/screencapture` as a child process: `<file>` for the full screen, `-i <file>` for an area, and `-v` (with `-i -s` for an area) for a recording, which it ends by interrupting the tool. `WindowRecorder` records one app or window through ScreenCaptureKit. `MovieShrinker` and `ImageShrinker` make the smaller Quick and Lower-fidelity files. `CaptureFiler` reads the first bytes of the result to name it by what it is. `CaptureLibrary` lists the folder.
- The tool's `-U` toolbar is deliberately not used: with it, macOS saves to its own "Save to" location (the Desktop by default) and ignores the file path, so captures never reach the folder.
- Each capture writes one line to the system log. To see the last ten minutes: `/usr/bin/log show --last 10m --predicate 'subsystem == "ai.rosslabs.quickshot"'` (the full path matters in zsh, where `log` is a builtin).
- `Sources/ClipboardCore` has no interface code either. `ClipboardMonitor` checks the clipboard's change counter twice a second (macOS has no change event), `ClipboardReader` decides what to keep before reading any content, and `ClipStore` saves it using the SQLite that ships with macOS, with images as files named by content hash.
- `Sources/QuickShot` is the app: the captures window, the clipboard library window, a menu bar item, and four system-wide shortcuts registered through Carbon hot keys, which need no extra permission.

## Not included

A built-in annotation editor, scrolling capture, cloud sharing, configurable shortcuts, launch at login, pasting into the front app, clipboard sync, a configurable ignore list, and copying every display of a multi-display Full Screen capture to the clipboard.

## Logo

The app icon is a camera with a lightning bolt in the lens: `design/logo/quickshot-logo.svg` (source) and `Resources/AppIcon.icns` (built from it). Two alternatives are kept beside it. To rebuild the icon from an edited SVG, render it with `design/logo/render-svg.swift` at 16 to 1024 px into an `.iconset` folder and run `iconutil -c icns`.
