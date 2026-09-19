#!/usr/bin/env swift
//
//     ./Scripts/set-icon.swift <icon.icns> <file>
//
// Gives a file its own icon, which is the one thing make-dmg.sh needs from the
// `fileicon` npm package and the only reason it would need node installed.
//
// Used on the Applications alias inside the disk image. A symlink cannot carry
// an icon, because setting one would write to the target, so the image holds a
// real alias file and this puts the system's Applications folder icon on it.
import Cocoa

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: set-icon.swift <icon.icns> <file>\n".data(using: .utf8)!)
    exit(2)
}

guard let icon = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write("cannot read icon at \(arguments[1])\n".data(using: .utf8)!)
    exit(1)
}

guard NSWorkspace.shared.setIcon(icon, forFile: arguments[2], options: []) else {
    FileHandle.standardError.write("cannot set icon on \(arguments[2])\n".data(using: .utf8)!)
    exit(1)
}
