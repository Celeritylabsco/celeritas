import AppKit
import Carbon.HIToolbox
import CeleritasKit
import SwiftUI

/// Click it, press a chord, it is recorded.
///
/// The keys are captured by an AppKit view rather than SwiftUI's `onKeyPress`,
/// because recording needs the raw key code and the modifier flags at the moment
/// of the press. SwiftUI hands over an interpreted character, which is the one
/// thing a hotkey recorder cannot use: Option-Space types a non-breaking space
/// and Control-Option-S types nothing at all.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var chord: Chord
    @Binding var recording: Bool

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { captured in
            chord = captured
            recording = false
        }
        view.onCancel = { recording = false }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.isRecording = recording
        if recording, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }
}

final class RecorderView: NSView {
    var onRecord: ((Chord) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Escape abandons, so a recorder cannot trap someone who opened it by
        // accident. Escape as a hotkey would be a bad idea anyway.
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        let carbon = HotkeyRecorder.carbonModifiers(event.modifierFlags)
        // A bare key is not a global hotkey. Registering "S" would swallow the
        // letter S everywhere on the machine.
        guard carbon != 0 else { NSSound.beep(); return }

        onRecord?(Chord(keyCode: UInt32(event.keyCode),
                        modifiers: carbon,
                        label: HotkeyRecorder.spell(event)))
    }

    /// Modifier-only presses are swallowed so holding Control while reaching for
    /// the key does not read as a chord.
    override func flagsChanged(with event: NSEvent) {
        if !isRecording { super.flagsChanged(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { onCancel?() }
        return true
    }
}

extension HotkeyRecorder {
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Written out rather than in symbols. The glyphs for control, option and
    /// command look alike to anyone who has not had to learn them, and getting
    /// the shortcut wrong means the app appears not to work at all.
    static func spell(_ event: NSEvent) -> String {
        var parts: [String] = []
        if event.modifierFlags.contains(.control) { parts.append("Control") }
        if event.modifierFlags.contains(.option) { parts.append("Option") }
        if event.modifierFlags.contains(.shift) { parts.append("Shift") }
        if event.modifierFlags.contains(.command) { parts.append("Command") }
        parts.append(keyName(event))
        return parts.joined(separator: " + ")
    }

    /// Named keys first, then whatever the layout actually produces. Asking the
    /// event for the character keeps this correct on a layout we have never seen.
    static func keyName(_ event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up",
            kVK_PageDown: "Page Down", kVK_LeftArrow: "Left", kVK_RightArrow: "Right",
            kVK_UpArrow: "Up", kVK_DownArrow: "Down", kVK_ANSI_Grave: "Backtick",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        let typed = event.charactersIgnoringModifiers ?? ""
        return typed.isEmpty ? "Key \(event.keyCode)" : typed.uppercased()
    }
}
