import AppKit
import SwiftUI

/// One settings window, reused. Opening it twice should raise the one that exists
/// rather than stack a second copy behind it.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    /// Settings records a new chord and the delegate re-registers it, because
    /// only the app layer can reach Carbon.
    var onHotkeyChanged: (() -> Void)?
    var onLauncherChanged: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView(onHotkeyChanged: onHotkeyChanged,
                                                            onLauncherChanged: onLauncherChanged))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = "Celeritas"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        // Pinned light. The content is paper whatever the system is set to, and an
        // inherited dark appearance makes AppKit draw a white scroller knob on it,
        // which is invisible. The palette panel is pinned for the same reason.
        w.appearance = NSAppearance(named: .aqua)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
