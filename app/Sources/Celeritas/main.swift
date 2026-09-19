import AppKit

// An accessory app: no Dock icon, no menu bar of its own, just the status item
// and the panel.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Opens one window in one fixed state, for making the pictures in the readme
// and the setup guide. See Shots.swift and Scripts/make-shots.py.
if let flag = CommandLine.arguments.firstIndex(of: "--demo"),
   flag + 1 < CommandLine.arguments.count {
    delegate.demo = CommandLine.arguments[flag + 1]
}

app.setActivationPolicy(.accessory)
app.run()
