# QuickShot

A small macOS app for screenshots and screen recordings. Screenshots use the system crosshair picker (the same one as Command Shift 4); recordings start and stop from QuickShot. Every capture is filed into one folder and shown in one small window: a camera button, a record button, and your recent captures. The window is only as large as its content needs.

## Use

| To do this | Do this |
|---|---|
| Take a screenshot | Press Control Shift S in any app, or click the camera button (**Screenshot**). Drag an area, or press Space to pick a window |
| Record the screen | Press Control Shift R in any app, or click the red record button (**Record**). Recording of the main display starts at once and the QuickShot window hides |
| Stop a recording | Press Control Shift R again, choose **Stop Recording** from the QuickShot menu bar item (it turns into a filled record dot), or click the Dock icon and then **Stop Recording** |
| Cancel a screenshot | Press Escape |
| Copy a capture | Select it, then Command C (or the copy symbol in the title bar) |
| Annotate a screenshot | Select it, then Command Return (opens Preview; use Markup) |
| Trim a recording | Select it, then Command Return (opens QuickTime Player) |
| Find the file | Select it, then the folder symbol in the title bar; or drag the card into another app |
| Remove a capture | Command Delete (moves it to the Trash) |

Captures are saved to `~/Pictures/QuickShot`. That folder is the only record: files you add, rename or delete there in Finder show up in the window as they are.

Selecting a capture shows four symbols in the title bar: copy, annotate (or open, for a recording), show in Finder, and move to Trash. Hover for the name; right-click a capture for the same actions with names.

The menu bar item offers the same capture actions when the window is closed.

## Clipboard library

QuickShot also keeps a history of what you copy. Press Control Shift V in any app, or choose **Show Clipboard** from the menu bar item or the Dock menu.

| To do this | Do this |
|---|---|
| Find something you copied | Open the library; **History** lists text, images and files, newest first. Type in Search to filter |
| See it in full | Select it: the right pane shows the whole text, the image, or the file list |
| Use it again | **Copy** (Command C), then paste where you need it; or drag the row into another app |
| Keep it | **Add to Collection**. Items in a collection never expire |
| Put a copy somewhere else | **Save to Folder**. A copy is written to the folder you pick; the item stays in the library |
| See your screenshots here | **Screenshots** lists everything in `~/Pictures/QuickShot`, in place |
| Stop recording for a while | **Pause Clipboard History** in the menu bar item |

What is kept and what is not:

- History is stored on this Mac only, in `~/Library/Application Support/QuickShot/Clipboard` (an SQLite index plus image files).
- Items not in a collection are removed after 90 days. A single copy larger than 50 MB is not recorded.
- Copies marked as secret by the app that made them (the nspasteboard.org convention password managers use), and copies made while Keychain Access, Passwords or 1Password is in front, are never read or stored.
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

1. Open QuickShot and click **Screenshot**. macOS asks for permission once.
2. Click **Open Settings** in QuickShot's notice. It opens the screen recording list in System Settings > Privacy & Security. Turn on QuickShot there.
3. Quit and reopen QuickShot.

Until then QuickShot refuses to capture, because macOS would otherwise hand back an image of only the desktop wallpaper.

The build is signed ad hoc, which never touches your Keychain. macOS ties the permission to that exact build, so after each rebuild you remove the old QuickShot entry in System Settings and allow the new one. To keep the permission across rebuilds, sign with your own identity:

```bash
QUICKSHOT_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh --install
```

Recent macOS versions also ask from time to time whether an app may keep recording the screen.

## How it works

- `Sources/QuickShotCore` has no interface code. `CaptureRunner` runs `/usr/sbin/screencapture` as a child process: `-i <file>` for a screenshot and `-v <file>` for a recording, which it ends by interrupting the tool. `CaptureFiler` reads the first bytes of the result to name it by what it is. `CaptureLibrary` lists the folder.
- The tool's `-U` toolbar is deliberately not used: with it, macOS saves to its own "Save to" location (the Desktop by default) and ignores the file path, so captures never reach the folder.
- Each capture writes one line to the system log. To see the last ten minutes: `log show --last 10m --predicate 'subsystem == "ai.rosslabs.quickshot"'`
- `Sources/ClipboardCore` has no interface code either. `ClipboardMonitor` checks the clipboard's change counter twice a second (macOS has no change event), `ClipboardReader` decides what to keep before reading any content, and `ClipStore` saves it using the SQLite that ships with macOS, with images as files named by content hash.
- `Sources/QuickShot` is the app: the captures window, the clipboard library window, a menu bar item, and three system-wide shortcuts registered through Carbon hot keys, which need no extra permission.

## Not included

A built-in annotation editor, recording a chosen area or with sound, scrolling capture, cloud sharing, configurable shortcuts, launch at login, pasting into the front app, clipboard sync, and a configurable ignore list.

## Logo

The app icon is a camera with a lightning bolt in the lens: `design/logo/quickshot-logo.svg` (source) and `Resources/AppIcon.icns` (built from it). Two alternatives are kept beside it. To rebuild the icon from an edited SVG, render it with `design/logo/render-svg.swift` at 16 to 1024 px into an `.iconset` folder and run `iconutil -c icns`.
