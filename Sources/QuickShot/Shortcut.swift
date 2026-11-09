import Carbon.HIToolbox
import SwiftUI

/// One system-wide keyboard shortcut, defined once. The hot key registration,
/// the menu's key equivalent and the wording shown to the person all read
/// from the same value, so they cannot disagree.
struct Shortcut: Sendable {
    /// Virtual key code, for the Carbon hot key.
    let keyCode: Int
    /// The same key as a character, for menus.
    let key: Character
    let modifiers: [Modifier]

    enum Modifier: Sendable, CaseIterable {
        case control, option, shift, command

        var carbonMask: Int {
            switch self {
            case .control: controlKey
            case .option: optionKey
            case .shift: shiftKey
            case .command: cmdKey
            }
        }

        var eventModifier: SwiftUI.EventModifiers {
            switch self {
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            }
        }

        var word: String {
            switch self {
            case .control: "Control"
            case .option: "Option"
            case .shift: "Shift"
            case .command: "Command"
            }
        }
    }

    var carbonModifiers: Int { modifiers.reduce(0) { $0 | $1.carbonMask } }
    var eventModifiers: SwiftUI.EventModifiers { modifiers.reduce(into: []) { $0.insert($1.eventModifier) } }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }
    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    /// Spelled out, e.g. "Control Shift S".
    var words: String {
        (modifiers.map(\.word) + [String(key).uppercased()]).joined(separator: " ")
    }

    static let screenshot = Shortcut(keyCode: kVK_ANSI_S, key: "s", modifiers: [.control, .shift])
    static let recording = Shortcut(keyCode: kVK_ANSI_R, key: "r", modifiers: [.control, .shift])
    static let clipboard = Shortcut(keyCode: kVK_ANSI_V, key: "v", modifiers: [.control, .shift])
}
