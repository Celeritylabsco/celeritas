import AppKit
import CeleritasKit
import SwiftUI

/// Owns the panel and its placement. Nothing else creates or positions it.
@MainActor
final class PaletteWindowController {
    private let panel: PalettePanel
    private let state = PaletteState()
    /// Where the panel's top edge sits, held so a growing panel extends downwards.
    private var topEdge: CGFloat = 0
    private var frameObserver: NSObjectProtocol?
    /// Set by the delegate, which owns the settings window.
    var onSettings: (() -> Void)?
    var onTips: (() -> Void)?

    init() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 64))
        // A hosting *controller* rather than a hosting view: setting it as the
        // content view controller is what makes AppKit resize the window when the
        // SwiftUI content grows. A hosting view keeps whatever frame it was given,
        // which silently clips every answer below the first line.
        let host = NSHostingController(rootView: PaletteView(state: state))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        // The actions panel gets escape first. Otherwise one keystroke closes the
        // menu and the launcher and throws away the query with them.
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.state.escape() { return }
            self.hide()
        }
        // AppKit resizes from the bottom-left, so without this the panel would
        // grow upwards and the text field would walk up the screen.
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.topEdge > 0 else { return }
                let f = self.panel.frame
                if abs(f.maxY - self.topEdge) > 0.5 {
                    self.panel.setFrameOrigin(NSPoint(x: f.origin.x, y: self.topEdge - f.height))
                }
            }
        }
        state.onDismiss = { [weak self] in self?.hide() }
        state.onSettings = { [weak self] in self?.onSettings?() }
        state.onTips = { [weak self] in self?.onTips?() }
        panel.onTab = { [weak self] in self?.state.askDirectly() ?? false }
        panel.onCommandK = { [weak self] in self?.state.toggleActions() ?? false }
        panel.onCommandComma = { [weak self] in
            guard let self, let open = self.onSettings else { return false }
            open()
            return true
        }
        panel.onCommandNumber = { [weak self] digit in
            guard let self, self.state.flat.indices.contains(digit - 1) else { return false }
            self.state.select(index: digit - 1)
            return true
        }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    /// Put a line from the tips window into the field and run it.
    func type(_ query: String) {
        if !panel.isVisible { show() }
        state.query = query
        state.queryChanged()
    }

    func show() {
        state.reset()
        // Lay out before placing, so the panel is its collapsed height when we
        // work out where the top edge goes.
        panel.layoutIfNeeded()
        place()
        state.watchMachine()
        panel.makeKeyAndOrderFront(nil)
        // A non-activating panel still needs the app frontmost for the field to
        // take keystrokes when nothing else of ours is on screen.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the panel already filled in, for making the pictures in the readme.
    ///
    /// Bypasses `show()` because that resets the state, which is right for a
    /// person opening the launcher and wrong here. Rendering these views to an
    /// image instead of photographing a real window does not work: the text
    /// field is AppKit underneath and comes out as a yellow placeholder, and
    /// the result rows do not lay out at all.
    func showFilled(_ fill: (PaletteState) -> Void) {
        fill(state)
        panel.layoutIfNeeded()
        place()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Something on the launcher page of settings changed. Rereading the tokens
    /// republishes state, which is what makes the panel redraw and pick up the
    /// toggles it reads straight from the defaults.
    func launcherChanged() {
        Task { @MainActor in await state.refreshTokens() }
    }

    func hide() {
        state.stopWatchingMachine()
        panel.orderOut(nil)
    }

    /// Open on whichever screen has the pointer, a third of the way down. Centring
    /// vertically puts it behind where people look. The top edge is what stays
    /// fixed, so the panel grows downwards as an answer arrives instead of
    /// jumping up the screen.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        topEdge = frame.maxY - frame.height / 3
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: topEdge - size.height))
    }
}
