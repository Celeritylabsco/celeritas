import AppKit
import CeleritasKit
import SwiftUI

@MainActor
final class PaletteState: ObservableObject {
    @Published var query = ""
    @Published var sections: [ResultSection] = []
    @Published var selected = 0
    @Published var outcome: Outcome?
    @Published var showingActions = false
    /// Which action is highlighted while the panel is up. Separate from `selected`,
    /// because the row underneath must not move while you pick what to do with it.
    @Published var actionIndex = 0
    var onDismiss: (() -> Void)?
    /// The palette does not own the settings window, so it asks for it.
    var onSettings: (() -> Void)?
    var onTips: (() -> Void)?

    /// CPU, memory, disk and what is using them, shown on the empty screen.
    @Published var machine = Machine.empty
    /// Pinned tokens, shown beside them.
    @Published var tokens: [Tokens.Token] = []
    private var watching: Task<Void, Never>?
    private var lookingUp: Task<Void, Never>?

    /// What the panel is showing. A launcher is a list until it has run something,
    /// then it is an answer.
    enum Outcome: Equatable {
        case thinking(String)
        case answered(String, Receipt)
        case failed(String)
        case confirming(String, tool: String, arguments: [String: String])
    }

    /// What ran, on what, how long, what it cost. No other launcher shows this.
    struct Receipt: Equatable {
        let tool: String
        let model: String
        let seconds: Double
        let cost: Double?
        let instant: Bool
    }

    /// Sample while the panel is open and stop the moment it closes.
    ///
    /// The process lists come from `ps`, a subprocess, and a launcher that kept
    /// spawning one every two seconds for the rest of the day would be a worse
    /// citizen than anything it is measuring.
    func watchMachine() {
        watching?.cancel()
        // Watched prices are wanted even with the machine cards off, so they
        // are fetched first and only the sampling loop is skipped.
        Task { @MainActor in
            if await Tokens.shared.refreshWatched() { }
            await refreshTokens()
        }
        guard Settings.statCards else { watching = nil; return }
        watching = Task { @MainActor in
            // Primes the CPU tick delta, which needs two readings to mean
            // anything, and fills the cards before the first full second.
            machine = await SystemMonitor.shared.machine()
            await refreshTokens()
            // Pinned prices are refreshed on a slower beat than the CPU. A
            // price is a network call and moves in minutes; the processor moves
            // in the time it takes to read the number.
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                machine = await SystemMonitor.shared.machine()
                tick += 1
                // Every five minutes, matching how long the lab holds a price.
                // The loop itself ticks every two seconds for the processor.
                if tick % 150 == 0, await Tokens.shared.refreshWatched() {
                    await refreshTokens()
                }
            }
        }
    }

    /// Reread the pinned tokens into the view.
    func refreshTokens() async {
        tokens = await Tokens.shared.pinned()
    }

    func stopWatchingMachine() {
        watching?.cancel()
        watching = nil
    }

    var flat: [Result] { Results.flatten(sections) }
    var current: Result? { flat.indices.contains(selected) ? flat[selected] : nil }

    func reset() {
        query = ""
        sections = []
        selected = 0
        outcome = nil
        showingActions = false
    }

    var actions: [SecondaryAction] {
        current.map(Actions.forResult) ?? []
    }

    func toggleActions() -> Bool {
        guard current != nil else { return false }
        actionIndex = 0
        showingActions.toggle()
        return true
    }

    /// Escape closes the actions panel before it closes the launcher. Anything
    /// else means one keystroke throws away the query as well as the menu.
    func escape() -> Bool {
        guard showingActions else { return false }
        showingActions = false
        return true
    }

    /// Return runs the highlighted action while the panel is up.
    func submit() {
        if showingActions {
            guard actions.indices.contains(actionIndex) else { return }
            perform(actions[actionIndex])
            return
        }
        run()
    }

    /// Tab asks the model whatever is in the field, from anywhere. The affordance
    /// is permanent rather than a row you have to scroll to.
    func askDirectly() -> Bool {
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        showingActions = false
        outcome = .thinking(Settings.description)
        Task { await ask(prompt) }
        return true
    }

    func perform(_ action: SecondaryAction) {
        defer { showingActions = false }
        guard let result = current else { return }
        switch action.id {
        case "reveal":
            if let path = result.iconPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                onDismiss?()
            }
        case "copyPath":
            if let path = result.iconPath { copy(path) }
        case "copyName":
            if let tool = result.tool { copy(tool) }
        case "copyQuery":
            copy(result.arguments["copy"] ?? result.title)
        case "copyAddress":
            if let address = result.arguments["token"] { copy(address) }
        case "pin":
            if let address = result.arguments["token"] {
                Task { await Tokens.shared.addAndFetch(address, pin: true); await refreshTokens() }
            }
        case "unpin":
            if let address = result.arguments["token"] {
                Settings.setPinned(address, false)
                Task { await refreshTokens() }
            }
        case "follow":
            if let address = result.arguments["token"] {
                Task { await Tokens.shared.addAndFetch(address); await refreshTokens() }
            }
        case "forget":
            if let address = result.arguments["token"] {
                Settings.removeToken(address)
                Task { await refreshTokens() }
            }
        default:
            run()
        }
    }

    func queryChanged() {
        outcome = nil
        let text = query
        let model = Settings.description
        Task {
            let built = await Results.build(for: text, modelName: model)
            // The field may have moved on while the index was working.
            guard text == query else { return }
            sections = built
            selected = 0
        }
        lookUpToken(text)
    }

    /// Ask the lab about a token, behind the field.
    ///
    /// Everything else in the launcher is answered from disk, so this is the
    /// one place a network call happens while somebody is typing. Two rules
    /// keep it from being felt. It only fires when the query says a token is
    /// meant, so "safari" never reaches the wire. And it waits out a pause in
    /// typing first, so a pasted address is one request rather than forty two.
    private func lookUpToken(_ text: String) {
        lookingUp?.cancel()
        guard let wanted = Tokens.wanted(in: text) else { return }
        lookingUp = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, text == query else { return }
            guard await Tokens.shared.lookup(wanted) else { return }
            guard text == query else { return }
            // Something arrived, so the list is worth building again. The
            // second pass reads it straight out of memory.
            sections = await Results.build(for: text, modelName: Settings.description)
        }
    }

    func move(_ delta: Int) {
        if showingActions {
            guard !actions.isEmpty else { return }
            actionIndex = max(0, min(actions.count - 1, actionIndex + delta))
            return
        }
        guard !flat.isEmpty else { return }
        selected = max(0, min(flat.count - 1, selected + delta))
    }

    func select(index: Int) {
        guard flat.indices.contains(index) else { return }
        selected = index
        run()
    }

    func run() {
        guard let result = current else { return }
        switch result.kind {
        case .calculator, .conversion:
            copy(result.arguments["copy"] ?? result.title)
            outcome = .answered("\(result.title)  copied",
                                Receipt(tool: "calculator", model: "index",
                                        seconds: 0, cost: nil, instant: true))
        case .app:
            if let path = result.iconPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            onDismiss?()
        case .action:
            guard let tool = result.tool else { return }
            let started = Date()
            let outcomeResult = Executor.run(tool, result.arguments)
            let receipt = Receipt(tool: tool, model: "index",
                                  seconds: Date().timeIntervalSince(started),
                                  cost: nil, instant: true)
            if outcomeResult.needsConfirmation {
                outcome = .confirming(outcomeResult.output, tool: tool,
                                      arguments: result.arguments)
            } else if outcomeResult.ok {
                outcome = .answered(Self.plain(outcomeResult.output.isEmpty ? "Done."
                                                                            : outcomeResult.output), receipt)
            } else {
                outcome = .failed(Self.plain(outcomeResult.output))
            }
        case .ask:
            outcome = .thinking(Settings.description)
            Task { await ask(result.title) }
        case .settings:
            openSettings()
        }
    }

    /// Open settings and stay put. Closing the launcher to show its own settings
    /// loses whatever was typed and makes changing a model a two step trip.
    func openSettings() {
        onSettings?()
    }

    /// Tips stays open beside the launcher, so a line can be clicked straight
    /// into the field without losing the list.
    func openTips() {
        onTips?()
    }

    func confirm(tool: String, arguments: [String: String]) {
        let started = Date()
        let result = Executor.run(tool, arguments, confirm: true)
        let receipt = Receipt(tool: tool, model: "index",
                              seconds: Date().timeIntervalSince(started),
                              cost: nil, instant: true)
        outcome = result.ok
            ? .answered(Self.plain(result.output.isEmpty ? "Done." : result.output), receipt)
            : .failed(Self.plain(result.output))
    }

    private func ask(_ prompt: String) async {
        do {
            let run = try await Backends.current().run(prompt, confirmDestructive: false)
            if let pending = run.pendingConfirmation {
                outcome = .confirming(pending.result.output, tool: pending.tool,
                                      arguments: pending.arguments)
                return
            }
            let chain = run.steps.map { $0.tool }.joined(separator: " → ")
            let receipt = Receipt(tool: chain.isEmpty ? "no tool" : chain,
                                  model: Settings.description,
                                  seconds: run.seconds, cost: run.cost, instant: false)
            if let reply = run.reply, !reply.isEmpty {
                outcome = .answered(Self.plain(reply), receipt)
            } else if let last = run.steps.last {
                outcome = last.result.ok
                    ? .answered(Self.plain(last.result.output.isEmpty ? "Done." : last.result.output), receipt)
                    : .failed(Self.plain(last.result.output))
            } else {
                outcome = .failed("Nothing happened.")
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Models return markdown whether asked to or not, and the panel shows one
    /// short answer rather than a document.
    static func plain(_ text: String) -> String {
        var out = text
        for marker in ["**", "__", "`"] { out = out.replacingOccurrences(of: marker, with: "") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
