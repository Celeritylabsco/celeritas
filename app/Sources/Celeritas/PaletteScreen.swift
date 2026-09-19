import AppKit
import CeleritasKit
import SwiftUI

struct PaletteView: View {
    @ObservedObject var state: PaletteState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if state.outcome != nil {
                answer.padding(.horizontal, 18).padding(.vertical, 13)
            } else if !state.sections.isEmpty {
                list
            } else {
                emptyState
            }
            divider
            footer
        }
        .background(Palette.paper)
        .overlay(alignment: .bottomTrailing) {
            if state.showingActions { actionsPanel }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
        .frame(width: 660)
        .onAppear { focused = true }
    }

    /// What else you can do with the highlighted row. Raycast puts this behind
    /// command K and so does this, because it is the one shortcut people already
    /// know for "the other things".
    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ACTIONS")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.35))
                .tracking(0.6)
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 4)
            ForEach(Array(state.actions.enumerated()), id: \.element.id) { index, action in
                let chosen = index == state.actionIndex
                Button { state.perform(action) } label: {
                    HStack(spacing: 14) {
                        Text(action.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 20)
                        HStack(spacing: 4) {
                            ForEach(action.keys, id: \.self) { keycap($0) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(chosen ? Palette.cobalt.opacity(0.11) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .leading) {
                        if chosen {
                            RoundedRectangle(cornerRadius: 2).fill(Palette.cobalt)
                                .frame(width: 3, height: 15)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
        .padding(.bottom, 7)
        .frame(width: 270)
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Palette.ink.opacity(0.16)))
        .shadow(color: Palette.ink.opacity(0.22), radius: 18, y: 7)
        .padding(.trailing, 11)
        .padding(.bottom, 42)
    }

    private var divider: some View {
        Rectangle().fill(Palette.ink.opacity(0.09)).frame(height: 1)
    }


    /// Pinned tokens, above the machine.
    ///
    /// Only here once somebody pins something, so a launcher nobody has set up
    /// opens on what it can do rather than on an empty shelf.
    private var tokenStrip: some View {
        HStack(alignment: .top, spacing: 9) {
            ForEach(state.tokens) { token in
                Button {
                    state.query = token.symbol.lowercased()
                    state.queryChanged()
                } label: {
                    card(token.symbol.uppercased()) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Tokens.money(token.price))
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            HStack(spacing: 5) {
                                if let change = token.change24h {
                                    Text(String(format: "%@%.2f%%", change >= 0 ? "+" : "", change))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Palette.ink.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                                Text(Tokens.short(token.liquidity))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Palette.ink.opacity(0.32))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 1)
    }

    /// The machine, before anybody types anything.
    ///
    /// Sampled only while this panel is open, so nothing runs in the background
    /// all day. The bars are cobalt because a bar is a rule, and the figures
    /// stay ink on paper where they can be read.
    private var machineStrip: some View {
        HStack(alignment: .top, spacing: 9) {
            meterCard("CPU", state.machine.cpuText, state.machine.cpu / 100)
            meterCard("MEMORY", state.machine.memoryText, state.machine.memoryFraction)
            meterCard("DISK FREE", state.machine.diskText, state.machine.diskFraction)
            listCard("TOP CPU", state.machine.topCPU)
            listCard("TOP MEMORY", state.machine.topMemory)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 4)
    }

    private func meterCard(_ label: String, _ value: String, _ fraction: Double) -> some View {
        card(label, width: 84) {
            VStack(alignment: .leading, spacing: 6) {
                Text(value)
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.ink.opacity(0.09))
                        Capsule().fill(Palette.cobalt)
                            .frame(width: max(2, geometry.size.width
                                                 * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func listCard(_ label: String, _ rows: [Usage]) -> some View {
        card(label) {
            VStack(alignment: .leading, spacing: 3) {
                if rows.isEmpty {
                    Text("reading")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.3))
                }
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink.opacity(0.8))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(row.value)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.ink.opacity(0.45))
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func card<Content: View>(_ label: String, width: CGFloat? = nil,
                                     @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.4))
                .lineLimit(1)
            body()
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Palette.ink.opacity(0.025))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(Palette.ink.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// The first screen anyone sees.
    ///
    /// Each line shows what to type and what it does, because a bare pill teaches
    /// nothing: someone reading "20c" does not know it converts temperature until
    /// they have already tried it. The dot says whether an answer costs anything,
    /// which is the thing worth learning first, since almost nothing here reaches
    /// a model.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.tokens.isEmpty { tokenStrip }
            if Settings.statCards { machineStrip }
            // The examples can be switched off, because on a small screen they
            // are most of the panel. The way into the tips window stays
            // whatever else is hidden, or there is no way back to it.
            HStack(spacing: 8) {
                Text(Settings.showExamples ? "Try typing" : "Celeritas")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink.opacity(0.45))
                Spacer()
                Button { state.openTips() } label: {
                    HStack(spacing: 5) {
                        Text("Everything it can do")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.cobalt)
                        Text("\u{2192}").font(.system(size: 11)).foregroundStyle(Palette.cobalt)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 13)
            .padding(.bottom, 9)

            ForEach(Settings.showExamples ? Examples.starters : []) { example in
                Button {
                    state.query = example.query
                    state.queryChanged()
                } label: {
                    HStack(spacing: 11) {
                        Circle()
                            .fill(example.cost == .instant ? Palette.cobalt
                                                           : Palette.ink.opacity(0.22))
                            .frame(width: 5, height: 5)
                        Text(example.query)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Palette.ink.opacity(0.9))
                        Text(example.does)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink.opacity(0.42))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ExampleRow())
            }

            if Settings.showExamples {
            HStack(spacing: 7) {
                Circle().fill(Palette.cobalt).frame(width: 5, height: 5)
                Text("answered here, free and instant")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink.opacity(0.4))
                Circle().fill(Palette.ink.opacity(0.22)).frame(width: 5, height: 5)
                    .padding(.leading, 6)
                Text("asks the model")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink.opacity(0.4))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 13)
            }
        }
    }

    /// Ink on paper, with cobalt in the brackets and the rule underneath.
    ///
    /// This was a cobalt fill with paper text, and it was unreadable: selected
    /// text disappeared into the fill, and a 64 point band of saturated colour
    /// held under the eye while reading a list below it is punishing. The brand
    /// note says it plainly, "ink and paper keep prose readable", and cobalt is
    /// for the mark, rules, links and accents. A field full of type is prose.
    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Text("[")
                    .foregroundStyle(Palette.cobalt)
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                TextField("", text: $state.query, prompt: Text("app, price, sum, emoji or question")
                    .foregroundStyle(Palette.ink.opacity(0.32)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, design: state.query.isEmpty ? .monospaced : .default))
                    .foregroundStyle(Palette.ink)
                    .tint(Palette.cobalt)
                    .focused($focused)
                    .onSubmit { state.submit() }
                    .onChange(of: state.query) { state.queryChanged() }
                    .onKeyPress(.upArrow) { state.move(-1); return .handled }
                    .onKeyPress(.downArrow) { state.move(1); return .handled }
                    if !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 5) {
                        Text("ask").font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.ink.opacity(0.45))
                        keycap("\u{21E5}")
                    }
                    .transition(.opacity)
                }
                Text("]")
                    .foregroundStyle(Palette.cobalt)
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            // The one piece of solid cobalt on the sheet. A rule carries the brand
            // without putting colour behind anything anyone has to read.
            Rectangle().fill(Palette.cobalt).frame(height: 2)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.sections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title.uppercased())
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.ink.opacity(0.32))
                            .tracking(0.6)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 3)
                        ForEach(section.results) { result in
                            let index = state.flat.firstIndex(of: result) ?? 0
                            PaletteRow(result: result,
                                       isSelected: index == state.selected,
                                       number: index < 9 ? index + 1 : nil)
                                .contentShape(Rectangle())
                                .onTapGesture { state.select(index: index) }
                        }
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 9)
        }
        .frame(maxHeight: 340)
        .scrollIndicators(.never)
    }

    @ViewBuilder private var answer: some View {
        switch state.outcome {
        case .thinking(let model):
            HStack(spacing: 9) {
                Text("thinking")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.45))
                Text(model)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.cobalt.opacity(0.7))
                Spacer()
            }

        case .answered(let message, let receipt):
            VStack(alignment: .leading, spacing: 9) {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(9)
                    .fixedSize(horizontal: false, vertical: true)
                receiptLine(receipt)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 5) {
                Text("That did not work")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.45))
                Text(message)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.7))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .confirming(let description, let tool, let arguments):
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Text("changes something")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.paper)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Palette.cobalt, in: RoundedRectangle(cornerRadius: 4))
                    Text(description).font(.system(size: 14)).foregroundStyle(Palette.ink)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button("Do it") { state.confirm(tool: tool, arguments: arguments) }
                        .buttonStyle(SolidButton(cobalt: Palette.cobalt, paper: Palette.paper))
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("Cancel") { state.reset() }
                        .buttonStyle(QuietButton(ink: Palette.ink))
                    Spacer()
                }
            }

        case .none:
            EmptyView()
        }
    }

    /// The footer carries the two things nobody else puts there: which model is
    /// answering, and what the last thing cost.
    private var footer: some View {
        HStack(spacing: 10) {
            // The mark and the name are one unit, so they sit tighter together
            // than the metadata that follows and read as a signature.
            HStack(spacing: 6) {
                Text("[■]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.cobalt)
                Text("Celeritas")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.72))
            }
            Text("·").foregroundStyle(Palette.ink.opacity(0.2))
            // One source for this. It used to read the model name and sniff the
            // base URL, which said "local, on this Mac" while the answer directly
            // above it came from Apple Intelligence.
            Text(Settings.description)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.42))
            if state.query.isEmpty && state.outcome == nil {
                Text("·").foregroundStyle(Palette.ink.opacity(0.2))
                Text("\(ToolCatalog.count) tools")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.42))
            }
            if !state.sections.isEmpty && state.outcome == nil {
                Text("·").foregroundStyle(Palette.ink.opacity(0.2))
                Text("\(state.flat.count) results")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.42))
            }
            Spacer()
            if let kind = state.current?.kind, state.outcome == nil {
                Text(actionName(for: kind))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.5))
                keycap("↩")
                Button { _ = state.toggleActions() } label: {
                    HStack(spacing: 5) {
                        Text("actions").font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.ink.opacity(0.5))
                        keycap("\u{2318}K")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // The bar is the only thing on screen the whole time, so the way into
            // settings belongs on it. This app has no Dock icon and no menu of
            // its own, and the menu bar item is easy to miss.
            Button { state.openSettings() } label: {
                HStack(spacing: 5) {
                    Text("settings").font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.ink.opacity(0.5))
                    keycap("\u{2318},")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Celeritas settings")

            Text("close").font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.35))
            keycap("esc")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.ink.opacity(0.025))
    }

    private func actionName(for kind: ResultKind) -> String {
        switch kind {
        case .app: return "open"
        case .calculator: return "copy"
        case .action: return "run"
        case .ask: return "ask"
        case .settings: return "open"
        case .conversion: return "copy"
        }
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.ink.opacity(0.55))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink.opacity(0.10)))
    }

    private func receiptLine(_ receipt: PaletteState.Receipt) -> some View {
        HStack(spacing: 0) {
            Text(receipt.tool).foregroundStyle(Palette.ink.opacity(0.42))
            Text("  ·  ").foregroundStyle(Palette.ink.opacity(0.22))
            Text(receipt.instant ? "index" : receipt.model).foregroundStyle(Palette.ink.opacity(0.42))
            Text("  ·  ").foregroundStyle(Palette.ink.opacity(0.22))
            Text(String(format: "%.2fs", receipt.seconds)).foregroundStyle(Palette.cobalt)
            if let cost = receipt.cost, cost > 0 {
                Text("  ·  ").foregroundStyle(Palette.ink.opacity(0.22))
                Text(priceText(cost)).foregroundStyle(Palette.cobalt)
            } else if receipt.instant {
                Text("  ·  ").foregroundStyle(Palette.ink.opacity(0.22))
                Text("no model").foregroundStyle(Palette.ink.opacity(0.42))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
    }
}



/// Rows in the empty state. A fill on hover rather than a border on every row,
/// which would turn the first screen into a grid of boxes.
struct ExampleRow: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed
                        ? Palette.cobalt.opacity(0.07) : .clear)
            .onHover { hovering = $0 }
    }
}
