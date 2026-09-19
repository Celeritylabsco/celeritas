import AppKit
import CeleritasKit
import SwiftUI

/// Everything Celeritas can do, on one page.
///
/// A launcher with no Dock icon and no menus has nowhere to put a manual, and a
/// field with a blinking cursor teaches nothing. The list comes from
/// `Examples.groups`, the same list the empty state draws from.
@MainActor
final class TipsWindowController {
    private var window: NSWindow?
    /// Clicking a line types it into the launcher instead of explaining it.
    var onTry: ((String) -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: TipsView { [weak self] query in
            self?.onTry?(query)
        })
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = "What Celeritas can do"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        // Pinned light, same as the other windows. An inherited dark appearance
        // draws a white scroller knob on paper, which is invisible.
        w.appearance = NSAppearance(named: .aqua)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TipsView: View {
    var onTry: (String) -> Void
    @State private var live: [Markets.Highlight] = []

    /// Two columns, balanced by how many lines each group holds rather than by
    /// how many groups. One column put the coins at the top and everything else
    /// below the fold, which is how the most interesting thing in the app
    /// became the thing nobody scrolled to.
    private var columns: ([Examples.Group], [Examples.Group]) {
        var left: [Examples.Group] = []
        var right: [Examples.Group] = []
        var leftRows = 0, rightRows = 0
        for group in Examples.groups {
            if leftRows <= rightRows {
                left.append(group); leftRows += group.examples.count
            } else {
                right.append(group); rightRows += group.examples.count
            }
        }
        return (left, right)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.cobalt).frame(height: 2)
            if !live.isEmpty { liveStrip }
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    column(columns.0)
                    column(columns.1)
                }
                .padding(.vertical, 16)
            }
            Divider().overlay(Palette.ink.opacity(0.12))
            footer
        }
        .frame(width: 700)
        .frame(maxHeight: 620)
        .background(Palette.paper)
        .task { live = await Markets.shared.highlights() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("[■]").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.cobalt)
                Text("Celeritas").font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.72))
            }
            Text("Type any of these")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("\(Examples.instantCount) of these never reach a model. They are answered "
                 + "on this Mac, instantly, and cost nothing.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }

    /// Real prices out of the cache, not an illustration. Saying the launcher
    /// can check crypto is a claim; showing what Bitcoin did today is the thing
    /// working in front of you.
    private var liveStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.paper)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Palette.cobalt)
                Text("in the launcher right now, refreshed every 15 minutes")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.45))
                Spacer()
                if let at = live.first?.at {
                    Text(at).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.ink.opacity(0.4))
                }
            }
            HStack(spacing: 0) {
                ForEach(live) { coin in
                    Button { onTry(coin.symbol.lowercased()) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(coin.symbol)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Palette.ink.opacity(0.5))
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(coin.price)
                                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                if let change = coin.change {
                                    Text(String(format: "%@%.2f%%", change >= 0 ? "+" : "", change))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Palette.ink.opacity(0.5))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Palette.ink.opacity(0.03))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 1)
        }
    }

    private func column(_ groups: [Examples.Group]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.6))
                    // A short rule under each heading. Cobalt belongs in a rule
                    // and never behind words, and it gives the two columns a
                    // shared beat so the eye knows where a group starts.
                    Rectangle().fill(Palette.cobalt).frame(width: 20, height: 2)
                        .padding(.bottom, 3)
                    ForEach(group.examples) { example in
                        row(example)
                    }
                }
                .padding(.horizontal, 22)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ example: Examples.Example) -> some View {
        Button { onTry(example.query) } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(example.cost == .instant ? Palette.cobalt : Palette.ink.opacity(0.22))
                    .frame(width: 5, height: 5)
                Text(example.query)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.9))
                    .fixedSize()
                Text(example.does)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 4.5)
            .padding(.horizontal, 6)
            .padding(.leading, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(ExampleRow())
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.cobalt).frame(width: 5, height: 5)
            Text("free and instant")
                .font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.45))
            Circle().fill(Palette.ink.opacity(0.22)).frame(width: 5, height: 5)
                .padding(.leading, 8)
            Text("asks the model")
                .font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.45))
            Spacer()
            Text("Open with \(Hotkey.current.label)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.45))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(Palette.ink.opacity(0.025))
    }
}
