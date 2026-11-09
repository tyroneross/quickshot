# QuickShot

A small macOS app for screenshots and screen recordings. It opens the system capture picker (the same toolbar as Command Shift 5), files every capture into one folder, and shows them in one small window: a camera button, a record button, and your recent captures. The window is only as large as its content needs.

## Use

| To do this | Do this |
|---|---|
| Take a screenshot | Press Control Shift S in any app, or click the camera button (**Screenshot**) |
| Record the screen | Press Control Shift R in any app, or click the red record button (**Record**), then click Record in the system toolbar |
| End a recording | Click the system Stop button in the menu bar |
| Cancel the picker | Press Escape, or choose **Cancel Capture** |
| Copy a capture | Select it, then Command C (or the copy symbol in the title bar) |
| Annotate a screenshot | Select it, then Command Return (opens Preview; use Markup) |
| Trim a recording | Select it, then Command Return (opens QuickTime Player) |
| Find the file | Select it, then the folder symbol in the title bar; or drag the card into another app |
| Remove a capture | Command Delete (moves it to the Trash) |

Captures are saved to `~/Pictures/QuickShot`. That folder is the only record: files you add, rename or delete there in Finder show up in the window as they are.

Selecting a capture shows four symbols in the title bar: copy, annotate (or open, for a recording), show in Finder, and move to Trash. Hover for the name; right-click a capture for the same actions with names.

The menu bar item offers the same capture actions when the window is closed.

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

- `Sources/QuickShotCore` has no interface code. `CaptureRunner` runs `/usr/sbin/screencapture -i -U -J selection|video` as a child process. `CaptureFiler` reads the first bytes of the result to tell a still from a movie, because the system toolbar lets you switch after it opens. `CaptureLibrary` lists the folder.
- `Sources/QuickShot` is the app: one window, a menu bar item, and two system-wide shortcuts registered through Carbon hot keys, which need no extra permission.

## Not included

A built-in annotation editor, scrolling capture, cloud sharing, configurable shortcuts, launch at login, and a custom app icon.
