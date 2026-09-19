import AppKit

// An accessory app: no Dock icon, no menu bar of its own, just the status item
// and the panel.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
