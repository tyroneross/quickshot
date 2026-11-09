import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import QuickShot

@Suite struct ShortcutTests {
    @Test func theScreenshotShortcutIsControlShiftSEverywhere() {
        let shortcut = Shortcut.screenshot
        #expect(shortcut.words == "Control Shift S")
        #expect(shortcut.keyCode == kVK_ANSI_S)
        #expect(shortcut.carbonModifiers == controlKey | shiftKey)
        #expect(shortcut.keyboardShortcut == KeyboardShortcut("s", modifiers: [.control, .shift]))
    }

    @Test func theRecordingShortcutIsControlShiftREverywhere() {
        let shortcut = Shortcut.recording
        #expect(shortcut.words == "Control Shift R")
        #expect(shortcut.keyCode == kVK_ANSI_R)
        #expect(shortcut.carbonModifiers == controlKey | shiftKey)
        #expect(shortcut.keyboardShortcut == KeyboardShortcut("r", modifiers: [.control, .shift]))
    }

    @Test func everyModifierMapsToItsOwnCarbonBitAndWord() {
        let masks = Shortcut.Modifier.allCases.map(\.carbonMask)
        #expect(Set(masks).count == masks.count)
        #expect(Shortcut.Modifier.allCases.map(\.word) == ["Control", "Option", "Shift", "Command"])
        let all = Shortcut(keyCode: 0, key: "a", modifiers: Shortcut.Modifier.allCases)
        #expect(all.carbonModifiers == controlKey | optionKey | shiftKey | cmdKey)
        #expect(all.eventModifiers == [.control, .option, .shift, .command])
    }
}
