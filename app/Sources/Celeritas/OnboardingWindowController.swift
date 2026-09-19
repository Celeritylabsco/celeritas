import AppKit
import CeleritasKit
import SwiftUI

/// The first-run window. Shown once, before the palette, because sending a
/// question somewhere is a choice a person should make rather than discover.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let state = OnboardingState()

    /// Preset the choice and a key, for the picture of the gateway pane. The
    /// key is made of zeroes, so nothing real is ever in a screenshot.
    func preset(_ backend: Backend, key: String = "") {
        state.choice = backend
        state.key = key
    }

    func show(then finished: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: OnboardingView(state: state) { [weak self] in
            self?.close()
            finished()
        })
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to Celeritas"
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
        state.watchLocal()
    }

    private func close() {
        window?.close()
        window = nil
    }
}
