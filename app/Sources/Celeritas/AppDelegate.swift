import AppKit
import CeleritasKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private var controller: PaletteWindowController?
    private let settings = SettingsWindowController()
    private let onboarding = OnboardingWindowController()
    private let tips = TipsWindowController()
    /// Held, because a scheduled timer nobody keeps is released and never fires.
    private var labRefresh: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "[ ]"
        item.button?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        item.menu = buildMenu()
        statusItem = item

        controller = PaletteWindowController()
        controller?.onSettings = { [weak self] in self?.settings.show() }
        controller?.onTips = { [weak self] in self?.tips.show() }
        tips.onTry = { [weak self] query in self?.controller?.type(query) }
        // The only things the app fetches, all of them from the lab. Behind
        // everything else, so a slow network delays nothing, and skipped
        // entirely when a cache is still inside its life.
        refreshLabData()
        // Coins are live and the lab rebuilds them every fifteen minutes, but a
        // menu bar app runs for days without being relaunched. Without a timer
        // the word "live" beside a price would start lying by lunchtime. The
        // call does nothing when nothing is stale, so five minutes is cheap.
        labRefresh = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLabData() }
        }
        bindHotkey(announceFailure: true)
        // Settings owns the recorder and cannot reach Carbon, so it asks for a
        // rebind through here once a new chord is saved.
        settings.onHotkeyChanged = { [weak self] in self?.bindHotkey(announceFailure: true) }
        // A change on the launcher page shows on the empty screen straight
        // away, rather than after the panel is closed and opened again.
        settings.onLauncherChanged = { [weak self] in self?.controller?.launcherChanged() }

        // On a first run, ask where answers should come from before showing a
        // field that would send one somewhere. After that, launching opens the
        // palette, because an app that starts and shows nothing looks broken.
        if Settings.hasOnboarded {
            Backends.prewarm()
            controller?.show()
        } else {
            onboarding.show { [weak self] in
                self?.statusItem?.menu = self?.buildMenu()
                Backends.prewarm()
                self?.controller?.show()
            }
        }
    }

    /// Opening an app that is already running sends this instead of launching a
    /// second copy. With no Dock icon and no window there is nothing for AppKit to
    /// bring forward on its own, so pressing Return in Spotlight did nothing at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Settings.hasOnboarded {
            controller?.show()
        } else {
            onboarding.show { [weak self] in
                self?.statusItem?.menu = self?.buildMenu()
                self?.controller?.show()
            }
        }
        return true
    }

    /// Command V does nothing without this, it just beeps.
    ///
    /// AppKit routes cut, copy and paste through the Edit menu in the main menu
    /// bar. An LSUIElement app has no main menu, so the key equivalent finds no
    /// handler and the system plays the error sound. The menu is never drawn,
    /// because an accessory app has no menu bar, and it exists only so the
    /// shortcuts resolve. This broke pasting an Orbio key into Settings.
    private func refreshLabData() {
        Task {
            await Currency.refreshIfStale()
            await Markets.refreshIfStale()
        }
    }

    private func installEditMenu() {
        let bar = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        let holder = NSMenuItem()
        holder.submenu = edit
        bar.addItem(holder)
        NSApp.mainMenu = bar
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Celeritas", action: #selector(openPalette), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let shortcut = NSMenuItem(title: "   \(Hotkey.current.label)", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        let help = NSMenuItem(title: "What Celeritas can do…", action: #selector(openTips),
                              keyEquivalent: "/")
        help.target = self
        menu.addItem(help)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let tools = NSMenuItem(title: "\(ToolCatalog.count) tools loaded", action: nil, keyEquivalent: "")
        tools.isEnabled = false
        menu.addItem(tools)
        let endpoint = NSMenuItem(title: "Model: \(Settings.description)",
                                  action: nil, keyEquivalent: "")
        endpoint.isEnabled = false
        menu.addItem(endpoint)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func openPalette() { controller?.toggle() }

    @objc private func openSettings() { settings.show() }

    @objc private func openTips() { tips.show() }

    /// Drop the old registration and take the current chord. Carbon refuses a
    /// second registration of a chord someone else owns, so this reports back.
    @discardableResult
    func bindHotkey(announceFailure: Bool) -> Bool {
        hotkey?.unregister()
        let chord = Hotkey.current
        hotkey = Hotkey(keyCode: chord.keyCode, modifiers: chord.modifiers) { [weak self] in
            self?.controller?.toggle()
        }
        let ok = hotkey?.registered == true
        statusItem?.button?.title = ok ? "[ ]" : "[!]"
        statusItem?.menu = buildMenu()
        if !ok && announceFailure { warnHotkeyTaken() }
        return ok
    }

    /// Said out loud rather than logged. Someone whose shortcut does nothing has
    /// no way to find out why, and the usual cause is Raycast or Alfred.
    private func warnHotkeyTaken() {
        let alert = NSAlert()
        alert.messageText = "\(Hotkey.current.label) is already taken"
        alert.informativeText = "Another app holds that shortcut, usually a launcher "
            + "such as Raycast or Alfred. Celeritas still opens from this menu bar "
            + "icon, and the shortcut can be changed in Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.unregister()
    }
}
