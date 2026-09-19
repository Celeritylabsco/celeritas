import AppKit
import CeleritasKit
import SwiftUI

/// Palette colours in one place, so nothing on screen is painted in the system
/// accent by accident.
enum Palette {
    static let ink = Color(red: 0.102, green: 0.098, blue: 0.098)
    static let cobalt = Color(red: 0.0, green: 0.278, blue: 0.671)
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
}

/// App icons, asked of the system once each. Loading one is cheap, doing it on
/// every keystroke for every row is not.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache[path] = image
        return image
    }
}

struct PaletteRow: View {
    let result: Result
    let isSelected: Bool
    /// 1 to 9, shown as a command shortcut. Nil past the ninth row.
    let number: Int?

    var body: some View {
        HStack(spacing: 11) {
            leading
                .frame(width: 26, height: 26)

            Text(result.title)
                .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(result.tag)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.42))
                .lineLimit(1)

            if let number, isSelected == false {
                Text("⌘\(number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.28))
                    .frame(width: 22, alignment: .trailing)
            } else if isSelected {
                Text("↩")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.cobalt)
                    .frame(width: 22, alignment: .trailing)
            } else {
                Spacer().frame(width: 22)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(isSelected ? Palette.cobalt.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))

    }

    @ViewBuilder private var leading: some View {
        switch result.kind {
        case .app:
            if let path = result.iconPath {
                Image(nsImage: IconCache.icon(for: path))
                    .resizable().frame(width: 24, height: 24)
            }
        case .calculator:
            glyph("=")
        case .action:
            glyph("▸")
        case .ask:
            glyph("?")
        case .settings:
            glyph("[■]")
        case .conversion:
            glyph("=")
        }
    }

    private func glyph(_ character: String) -> some View {
        Text(character)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.cobalt)
            .frame(width: 24, height: 24)
            .background(Palette.cobalt.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }
}
