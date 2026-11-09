import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import QuickShot

@Suite struct ShortcutTests {
    @Test func theScreenshotShortcutIsControlOptionSEverywhere() {
        let shortcut = Shortcut.screenshot
        #expect(shortcut.words == "Control Option S")
        #expect(shortcut.glyphs == "⌃⌥S")
        #expect(shortcut.keyCode == kVK_ANSI_S)
        #expect(shortcut.carbonModifiers == controlKey | optionKey)
        #expect(shortcut.keyboardShortcut == KeyboardShortcut("s", modifiers: [.control, .option]))
    }

    @Test func theRecordingShortcutIsControlOptionREverywhere() {
        let shortcut = Shortcut.recording
        #expect(shortcut.words == "Control Option R")
        #expect(shortcut.glyphs == "⌃⌥R")
        #expect(shortcut.keyCode == kVK_ANSI_R)
        #expect(shortcut.carbonModifiers == controlKey | optionKey)
    }

    @Test func theClipboardShortcutIsControlOptionVEverywhere() {
        let shortcut = Shortcut.clipboard
        #expect(shortcut.words == "Control Option V")
        #expect(shortcut.keyCode == kVK_ANSI_V)
        #expect(shortcut.carbonModifiers == controlKey | optionKey)
    }

    /// Regression, 2026-11-09: QuickShot shipped with Control Shift S, R and V,
    /// which are Snagit's Image Capture, Repeat Last Capture and Video Capture.
    /// With Snagit running, every "quick capture" went to Snagit. Snagit's Mac
    /// defaults all use Control Shift (TechSmith hotkey guide,
    /// techsmith.com/learn/tutorials/snagit/snagit-hotkeys, read 2026-11-09).
    @Test func noShortcutUsesSnagitsControlShiftKeys() {
        let snagitControlShiftKeys: Set<Character> = ["c", "o", "s", "m", "w", "e", "r", "v", "f", "d", "t", "p", " "]
        for shortcut in [Shortcut.screenshot, .recording, .clipboard] {
            let isControlShift = Set(shortcut.modifiers.map(\.word)) == ["Control", "Shift"]
            #expect(!(isControlShift && snagitControlShiftKeys.contains(shortcut.key)),
                    "\(shortcut.words) is one of Snagit's shortcuts")
        }
    }

    @Test func everyModifierMapsToItsOwnCarbonBitWordAndSymbol() {
        let masks = Shortcut.Modifier.allCases.map(\.carbonMask)
        #expect(Set(masks).count == masks.count)
        #expect(Shortcut.Modifier.allCases.map(\.word) == ["Control", "Option", "Shift", "Command"])
        #expect(Shortcut.Modifier.allCases.map(\.glyph) == ["⌃", "⌥", "⇧", "⌘"])
        let all = Shortcut(keyCode: 0, key: "a", modifiers: Shortcut.Modifier.allCases)
        #expect(all.carbonModifiers == controlKey | optionKey | shiftKey | cmdKey)
        #expect(all.eventModifiers == [.control, .option, .shift, .command])
        #expect(all.glyphs == "⌃⌥⇧⌘A")
    }
}
