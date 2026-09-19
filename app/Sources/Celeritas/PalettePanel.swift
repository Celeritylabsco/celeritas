import AppKit

/// Borderless floating panel that hosts the palette.
///
/// `.nonactivatingPanel` is what lets it take keystrokes without stealing focus
/// from whatever you were doing, which is the whole point of a launcher. It also
/// means the panel has to say it can become key, because a non-activating panel
/// will not by default.
final class PalettePanel: NSPanel {
    var onEscape: (() -> Void)?
    /// Command plus a digit, handled here because the field editor eats command
    /// chords before any SwiftUI key handler sees them.
    var onCommandNumber: ((Int) -> Bool)?
    /// Tab, which the field editor uses for focus movement, and command-K.
    var onTab: (() -> Bool)?
    var onCommandK: (() -> Bool)?
    var onCommandComma: (() -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        // Pinned to light. The palette is paper and ink whatever the system is
        // set to, and inheriting dark made every colour resolve to its opposite:
        // the placeholder came out white on cream and could not be read.
        appearance = NSAppearance(named: .aqua)
        hasShadow = true
        // Show above a fullscreen app, and do not appear in Mission Control as a
        // window of its own.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape reaches `cancelOperation` rather than a key handler, and a SwiftUI
    /// text field swallows it before any `onKeyPress` would see it.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           let characters = event.charactersIgnoringModifiers {
            if let digit = Int(characters), digit >= 1, digit <= 9,
               onCommandNumber?(digit) == true { return }
            if characters.lowercased() == "k", onCommandK?() == true { return }
        }
        if event.type == .keyDown, event.charactersIgnoringModifiers == ",",
           event.modifierFlags.contains(.command), onCommandComma?() == true {
            return
        }
        // 48 is tab.
        if event.type == .keyDown, event.keyCode == 48,
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
           onTab?() == true {
            return
        }
        super.sendEvent(event)
    }
}
