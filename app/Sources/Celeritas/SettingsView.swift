import AppKit
import CeleritasKit
import SwiftUI

@MainActor
final class SettingsState: ObservableObject {
    @Published var backend: Backend {
        // A probe result describes one backend. Leaving it on screen after a
        // switch put "The model is not running" over the top of a live download.
        didSet { if backend != oldValue { probe = nil } }
    }
    @Published var baseURL: String
    @Published var apiKey: String
    @Published var model: String
    @Published var probe: Probe?
    @Published var local: LocalModel.State = .idle

    private var watching: Task<Void, Never>?

    enum Probe: Equatable {
        case checking
        case working(Double)
        case problem(title: String, detail: String)

        var isGood: Bool { if case .working = self { return true }; return false }
    }

    init() {
        let endpoint = Settings.endpoint
        let isLocal = endpoint.baseURL.contains("127.0.0.1") || endpoint.baseURL.contains("localhost")
        backend = Settings.backend
        baseURL = isLocal ? Endpoint.orbio.baseURL : endpoint.baseURL
        apiKey = endpoint.apiKey
        model = isLocal ? Shortlist.current.best : endpoint.model
        local = LocalModel.shared.state
    }

    var endpoint: Endpoint {
        backend == .orbio
            ? Endpoint(baseURL: Endpoint.orbio.baseURL, apiKey: apiKey, model: model)
            : .local
    }

    func save() {
        Settings.backend = backend
        Settings.endpoint = endpoint
        if backend == .localModel { startLocal() }
        if backend == .apple, #available(macOS 26.0, *) { AppleClient.prewarm() }
    }

    /// Why a backend cannot be chosen on this Mac, or nil when it can.
    func blocked(_ option: Backend) -> String? {
        guard option == .apple else { return nil }
        if #available(macOS 26.0, *) { return AppleClient.unavailableReason }
        return "Apple Intelligence needs macOS 26."
    }

    /// Called when the window opens. A server left running from a previous launch
    /// is still a running server, and saying "not downloaded" over the top of one
    /// is how a settings screen starts lying.
    func refreshLocal() {
        Task {
            await LocalModel.shared.refresh()
            local = LocalModel.shared.state
            // A download already in flight keeps reporting until it is done.
            if case .downloading = local { watchLocal() }
            if case .starting = local { watchLocal() }
        }
    }

    /// Follow a download this window did not start.
    private func watchLocal() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await LocalModel.shared.refresh()
                self?.local = LocalModel.shared.state
                if case .ready = LocalModel.shared.state { break }
                if case .failed = LocalModel.shared.state { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func startLocal() {
        probe = nil
        watching?.cancel()
        watching = Task { [weak self] in
            async let run: Void = LocalModel.shared.start()
            while !Task.isCancelled {
                self?.local = LocalModel.shared.state
                if case .ready = LocalModel.shared.state { break }
                if case .failed = LocalModel.shared.state { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            await run
            self?.local = LocalModel.shared.state
        }
    }

    /// One real call. A key that looks right and does not work is the thing
    /// settings screens exist to catch, so the answer is said in plain words
    /// rather than handed over as a truncated status code.
    func test() {
        probe = .checking
        let target = endpoint
        let which = backend
        Task {
            do {
                if which == .apple, #available(macOS 26.0, *) {
                    let started = Date()
                    _ = try await AppleClient.askOnce(
                        messages: [["role": "user", "content": "reply with the word ok"]],
                        tools: [])
                    probe = .working(Date().timeIntervalSince(started))
                } else {
                    let turn = try await Client(endpoint: target, timeout: 25).ask(
                        messages: [["role": "user", "content": "reply with the word ok"]],
                        tools: [])
                    probe = .working(turn.seconds)
                }
            } catch {
                probe = SettingsState.explain(error, backend: which)
            }
        }
    }

    /// Status codes are for logs. Every one of these is something the person can
    /// act on, so it says what to do next.
    static func explain(_ error: Error, backend: Backend) -> Probe {
        let raw = error.localizedDescription

        if raw.contains("http 401") || raw.contains("http 403") {
            return .problem(title: "That key was rejected",
                            detail: "Check you pasted the whole key, and that it belongs to the gateway above. An Orbio key only works against Orbio.")
        }
        if raw.contains("http 404") {
            return .problem(title: "That model is not being served",
                            detail: "Nobody is currently hosting it through this gateway. Pick another from the list.")
        }
        if raw.contains("http 429") {
            return .problem(title: "Too many requests on that key",
                            detail: "The gateway is rate limiting. Wait a moment and try again.")
        }
        if raw.contains("http 5") {
            return .problem(title: "The gateway had a problem",
                            detail: "Nothing wrong at this end. Try again shortly.")
        }
        if backend == .apple {
            return .problem(title: "Apple Intelligence did not answer", detail: raw)
        }
        if backend == .localModel {
            return .problem(title: "The model is not running",
                            detail: "Celeritas expects it on 127.0.0.1:8138. Press Save to download and start it, or switch to an Orbio key.")
        }
        return .problem(title: "Could not reach the gateway",
                        detail: raw)
    }
}

struct SettingsView: View {
    var onHotkeyChanged: (() -> Void)?
    var onLauncherChanged: (() -> Void)?
    @State private var statCards = Settings.statCards
    @State private var showExamples = Settings.showExamples
    @State private var page: Page = .model
    /// Which page to open on. Only set when making the pictures, so both pages
    /// can be photographed without anybody clicking.
    var startPage: Page?

    /// Two pages rather than one long scroll. The model settings were already
    /// a full screen on their own, and a launcher option at the bottom of them
    /// read as another setting for the model.
    enum Page: String, CaseIterable, Identifiable {
        case model, launcher
        var id: String { rawValue }
        var title: String { self == .model ? "Model" : "Launcher" }
        var blurb: String {
            switch self {
            case .model:
                return "Every answer is measured on the same \(Shortlist.current.tasks) "
                     + "held-out tasks, so the "
                     + "numbers below compare like with like."
            case .launcher:
                return "What the panel shows before you type anything."
            }
        }
    }
    /// Prices for everything followed, and the two lists behind the rows.
    @State private var known: [Tokens.Token] = []
    @State private var watchlist: [String] = Settings.watchedTokens
    @State private var pins: [String] = Settings.pinnedTokens
    @State private var newToken = ""
    @State private var adding = false
    @State private var tokenError: String?

    @StateObject private var state = SettingsState()
    @State private var chord: Chord = Hotkey.current
    @State private var recording = false

    private let ink = Color(red: 0.102, green: 0.098, blue: 0.098)
    private let cobalt = Color(red: 0.0, green: 0.278, blue: 0.671)
    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)

    /// Scrolling body, pinned bar. The window is as tall as it needs to be up to
    /// a limit, and Save is reachable whatever the content does. The Orbio pane
    /// lists every scored model, which ran off the bottom of a laptop screen and
    /// took the buttons with it.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { scrollingBody.padding(26) }
                .onAppear { state.refreshLocal() }
            Divider().overlay(ink.opacity(0.12))
            actionBar
        }
        .frame(width: 560)
        .frame(maxHeight: 640)
        .background(paper)
    }

    /// Two sections, each with its own heading and a rule between them. The
    /// page was called "Where Celeritas thinks" and was entirely about the
    /// model, so a launcher option dropped into the same flow read as another
    /// setting for the backend.
    private var scrollingBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageTabs
                .onAppear { if let startPage { page = startPage } }
            Text(page.blurb)
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            switch page {
            case .model:
                modeToggle

                switch state.backend {
                case .apple: applePane
                case .localModel: localPane
                case .orbio: gatewayPane
                }

                if let probe = state.probe { probeBanner(probe) }

            case .launcher:
                section("The empty screen", nil) { launcherSection }
                Rectangle().fill(ink.opacity(0.1)).frame(height: 1)
                section("Pinned tokens",
                        "Paste a contract address from any chain we can see, "
                        + "Robinhood and Solana included. It sits on the empty "
                        + "screen and refreshes every five minutes, and after "
                        + "that typing its symbol answers straight away.") {
                    tokenSection
                }
            }
        }
    }

    /// The same control as the backend picker, so the two read as one idea.
    private var pageTabs: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases) { option in
                let selected = page == option
                Button { page = option } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? paper : ink.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selected ? cobalt : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func section<Content: View>(_ title: String, _ blurb: String?,
                                        @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)
                if let blurb {
                    Text(blurb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            body()
        }
    }

    private var actionBar: some View {
            HStack(spacing: 12) {
                hotkeyControl
                Spacer()
                Button("Test") { state.test() }
                    .buttonStyle(QuietButton(ink: ink))
                Button("Save") { state.save() }
                    .buttonStyle(SolidButton(cobalt: cobalt, paper: paper))
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(ink.opacity(0.025))
    }

    /// Our own control. The system segmented picker washes out the unselected
    /// labels and paints the selection in the system accent, which is a second
    /// blue arguing with cobalt on the same screen. Each segment carries its
    /// score, so the tradeoff is on the control itself.
    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(Backend.allCases, id: \.self) { option in
                let selected = state.backend == option
                let blocked = state.blocked(option) != nil
                Button { if !blocked { state.backend = option } } label: {
                    VStack(spacing: 2) {
                        Text(Self.shortTitle(option))
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? paper : ink.opacity(0.75))
                        Text(OnboardingView.score(option))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(selected ? paper.opacity(0.75) : ink.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(selected ? cobalt : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                    .opacity(blocked ? 0.4 : 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    static func shortTitle(_ backend: Backend) -> String {
        switch backend {
        case .apple: return "Apple Intelligence"
        case .localModel: return "Our model"
        case .orbio: return "My Orbio key"
        }
    }

    private var applePane: some View {
        let ready = state.blocked(.apple) == nil
        return VStack(alignment: .leading, spacing: 10) {
            row(title: AppleBaseline.model,
                detail: "Built into this Mac. Nothing to install, nothing leaves the machine, no cost.",
                score: AppleBaseline.score ?? "not measured yet",
                accuracy: AppleBaseline.accuracy ?? 0, cost: nil, selected: ready)
            if let reason = state.blocked(.apple) {
                status(.warn, "unavailable", reason)
            } else {
                status(.live, "ready",
                       "Nothing to install. Expect it to be slower and weaker at tool use "
                       + "than a frontier model through an Orbio key.")
            }
        }
    }

    private var localPane: some View {
        let running = state.local == .ready
        return VStack(alignment: .leading, spacing: 10) {
            row(title: LocalBaseline.model,
                detail: "Our own model, served on this machine. Nothing leaves it, nothing costs anything.",
                score: LocalBaseline.score, accuracy: LocalBaseline.accuracy, cost: nil,
                selected: running)
            switch state.local {
            case .idle:
                if LocalModel.hasRoom() {
                    status(.idle, "not downloaded",
                           "Needs about 1.5 GB of disk. You have \(LocalModel.freeDescription()) free. "
                           + "Press Save to fetch it once and start serving.")
                } else {
                    status(.warn, "not enough disk",
                           "Needs about 1.5 GB plus headroom, and you have \(LocalModel.freeDescription()) free. "
                           + "Clear some space, or use Apple Intelligence or an Orbio key instead.")
                }
            case .needsLlama:
                status(.warn, "llama.cpp missing",
                       "Celeritas serves this model with llama.cpp. Run  brew install llama.cpp  in a terminal, then press Save.")
            case .downloading(let what):
                status(.busy, "downloading", what + ". This runs once and then it is on disk.")
            case .starting:
                status(.busy, "loading", "The file is on disk. Loading it into memory.")
            case .ready:
                status(.live, "running", "Serving on 127.0.0.1:\(LocalModel.port). Answers stay on this Mac.")
            case .failed(let why):
                status(.warn, "failed", why)
            }
        }
    }

    /// The shortcut, as a control rather than a caption. It used to be three
    /// grey keycaps that looked like a label, so nobody could tell the chord was
    /// changeable at all.
    /// The CPU, memory and disk cards on the empty screen. On by default, and
    /// switching them off stops the sampling entirely rather than just hiding
    /// the numbers.
    private var launcherSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            tickBox("Show CPU, memory and disk", statCards) {
                statCards.toggle()
                Settings.statCards = statCards
                onLauncherChanged?()
            }
            Text(statCards
                 ? "Sampled only while the launcher is open."
                 : "Off, so nothing is measured at all.")
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.45))

            tickBox("Show the \"Try typing\" examples", showExamples) {
                showExamples.toggle()
                Settings.showExamples = showExamples
                onLauncherChanged?()
            }
            Text(showExamples
                 ? "Eight lines. Turn this off to make the panel much shorter."
                 : "Hidden. Everything it can do is still one click away, top right.")
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.45))
        }
    }

    /// A cobalt square when on. A system checkbox paints itself in the system
    /// accent, which is a second blue arguing with cobalt on the same screen.
    private func tickBox(_ label: String, _ isOn: Bool,
                         _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(isOn ? cobalt : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 2.5)
                        .stroke(isOn ? cobalt : ink.opacity(0.28), lineWidth: 1.2))
                    .frame(width: 13, height: 13)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(isOn ? 0.85 : 0.6))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            if watchlist.isEmpty {
                Text("Nothing followed yet. Paste a contract address below, or "
                     + "press command D on a token in the launcher.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ink.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(watchlist, id: \.self) { address in
                tokenRow(address)
            }

            if !watchlist.isEmpty {
                Text("The tick pins it to the empty screen. Everything followed "
                     + "answers to its symbol whether it is pinned or not.")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                TextField("", text: $newToken, prompt: Text("0x\u{2026} or a Solana address")
                    .foregroundColor(ink.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(ink.opacity(0.18), lineWidth: 1))
                    .onSubmit { addToken() }
                Button(adding ? "Adding" : "Follow") { addToken() }
                    .buttonStyle(QuietButton(ink: ink))
                    .disabled(adding || !Tokens.isAddress(newToken.trimmingCharacters(in: .whitespaces)))
            }
            if let tokenError {
                Text(tokenError)
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await reloadTokens(fetch: true) }
    }

    private func tokenRow(_ address: String) -> some View {
        let token = known.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
        let isPinned = pins.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
        return HStack(spacing: 10) {
            Button {
                Settings.setPinned(address, !isPinned)
                Task { await reloadTokens(fetch: false) }
            } label: {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(isPinned ? cobalt : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 2.5)
                        .stroke(isPinned ? cobalt : ink.opacity(0.28), lineWidth: 1.2))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Pinned to the empty screen" : "Pin to the empty screen")

            Text(token?.symbol.uppercased() ?? "\u{2026}")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ink.opacity(0.85))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
            Text(token.map { Tokens.money($0.price) } ?? "fetching")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(ink.opacity(0.6))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            Text(token?.chain ?? "")
                .font(.system(size: 10.5))
                .foregroundStyle(ink.opacity(0.4))
                .frame(width: 58, alignment: .leading)
            // The address, shortened. Two tokens can share a symbol, so this is
            // the only part that says which one this row is.
            Text(Self.shortAddress(address))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(ink.opacity(0.3))
            Spacer(minLength: 6)
            Button("Remove") {
                Settings.removeToken(address)
                Task { await reloadTokens(fetch: false) }
            }
            .buttonStyle(QuietButton(ink: ink))
        }
    }

    /// Reread the lists, and tell the launcher, so a pin appears there without
    /// the panel having to be closed and reopened.
    private func reloadTokens(fetch: Bool) async {
        if fetch { _ = await Tokens.shared.refreshWatched() }
        known = await Tokens.shared.watched()
        watchlist = Settings.watchedTokens
        pins = Settings.pinnedTokens
        onLauncherChanged?()
    }

    private func addToken() {
        let address = newToken.trimmingCharacters(in: .whitespaces)
        guard Tokens.isAddress(address) else {
            tokenError = "That is not a contract address. Either 0x and 40 more "
                       + "characters, or a Solana one."
            return
        }
        adding = true
        tokenError = nil
        Task {
            let found = await Tokens.shared.addAndFetch(address)
            if found == nil {
                // Real enough to be an address, but nothing trades it anywhere
                // we can see. Kept, in case a pool appears later.
                tokenError = "No pool found for that address yet. It stays on the "
                           + "list in case one appears."
            }
            newToken = ""
            adding = false
            await reloadTokens(fetch: false)
        }
    }

    /// "0xAa07…28A3". The middle of an address carries no meaning to a reader
    /// and the ends are what people check against a block explorer.
    static func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return address.prefix(6) + "\u{2026}" + address.suffix(4)
    }

    private var hotkeyControl: some View {
        Button {
            recording.toggle()
        } label: {
            HStack(spacing: 10) {
                Text("Open with")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.55))
                HStack(spacing: 5) {
                    if recording {
                        Text("Press any keys")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(cobalt)
                        Text("esc to cancel")
                            .font(.system(size: 10))
                            .foregroundStyle(ink.opacity(0.4))
                    } else {
                        ForEach(Array(chord.label.split(separator: " + ").enumerated()),
                                id: \.offset) { index, key in
                            if index > 0 {
                                Text("+").font(.system(size: 10)).foregroundStyle(ink.opacity(0.3))
                            }
                            Text(key.lowercased())
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ink.opacity(0.8))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(paper, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(ink.opacity(0.22)))
                        }
                    }
                }
                Text(recording ? "" : "Change")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(cobalt)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(recording ? cobalt.opacity(0.07) : ink.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(recording ? cobalt : ink.opacity(0.18),
                              lineWidth: recording ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay(HotkeyRecorder(chord: $chord, recording: $recording)
                .frame(width: 0, height: 0))
        }
        .buttonStyle(.plain)
        .help("Click, then press the keys you want")
        .onChange(of: chord) { _, updated in
            Settings.hotkey = updated
            onHotkeyChanged?()
        }
    }

    enum StatusKind { case idle, busy, live, warn }

    /// A chip that says what the state actually is, next to a sentence saying what
    /// to do about it. The row above used to be tinted whenever the option was
    /// chosen, which read as "installed and running" for a model not yet on disk.
    @ViewBuilder private func status(_ kind: StatusKind, _ label: String,
                                     _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            HStack(spacing: 5) {
                switch kind {
                case .busy:
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 9, height: 9)
                case .live:
                    Circle().fill(cobalt).frame(width: 6, height: 6)
                case .warn:
                    Circle().strokeBorder(ink.opacity(0.4), lineWidth: 1.5).frame(width: 6, height: 6)
                case .idle:
                    Circle().strokeBorder(ink.opacity(0.28), lineWidth: 1).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(kind == .live ? cobalt : ink.opacity(0.6))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(kind == .live ? cobalt.opacity(0.1) : ink.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(kind == .live ? cobalt.opacity(0.28) : ink.opacity(0.1)))
            .fixedSize()

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var gatewayPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            orbioHeader

            if state.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                status(.idle, "no key",
                       "Paste your Orbio key below, then press Test. Nothing is sent until you do.")
            } else if case .working(let seconds) = state.probe {
                status(.live, "working", String(format: "Answered in %.1fs. Press Save to use it.", seconds))
            } else {
                status(.warn, "untested",
                       "A key is set. Press Test to make one real call and check it before you rely on it.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Gateway").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.5))
                // Fixed, not a field. An Orbio key only authenticates against
                // Orbio, and pointing it anywhere else returns "Missing
                // Authentication header", which reads like a broken client and
                // sends people debugging the wrong thing.
                HStack(spacing: 8) {
                    Text(Endpoint.orbio.baseURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.7))
                    Spacer()
                    Text("fixed")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.4))
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.1)))

                Text("Key").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.5))
                SecureField("", text: $state.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("Stored on this Mac and sent to Orbio only.")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.4))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Model").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.5))
                    Text("scored by us on Orbio, cost per question")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.35))
                }
                ForEach(Shortlist.current.byCost.filter { $0.local != true }) { candidate in
                    Button {
                        state.model = candidate.id
                    } label: {
                        row(title: candidate.shortName, detail: candidate.vendor,
                            score: candidate.score, accuracy: candidate.accuracy,
                            cost: Shortlist.current.perQuestion(candidate),
                            selected: state.model == candidate.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Orbio named outright rather than hidden behind "your own key". Holding
    /// ORBIO earns inference credit, and this is somewhere to spend it.
    private var orbioHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("[■]")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(cobalt)
                Text("Powered by Orbio")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                Spacer()
                Link("Get a key", destination: URL(string: "https://www.orbio.so/")!)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(cobalt)
            }
            Text("Paste a key and Celeritas sends your questions to whichever model you pick. You pay Orbio for what you use, and every answer shows what it cost. Celeritas takes nothing.")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(cobalt.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cobalt.opacity(0.22)))
    }

    /// A problem gets its own row, full width, in words. Nothing about a failed
    /// key should have to fit between two buttons.
    @ViewBuilder private func probeBanner(_ probe: SettingsState.Probe) -> some View {
        switch probe {
        case .checking:
            HStack(spacing: 8) {
                Text("[ ]").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(cobalt.opacity(0.5))
                Text("checking").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.5))
                Spacer()
            }
            .padding(12)
            .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))

        case .working(let seconds):
            HStack(spacing: 9) {
                Text("[■]").font(.system(size: 11, design: .monospaced)).foregroundStyle(cobalt)
                Text("Working").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                Text(String(format: "answered in %.2fs", seconds))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.55))
                Spacer()
            }
            .padding(12)
            .background(cobalt.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(cobalt.opacity(0.25)))

        case .problem(let title, let detail):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("[!]").font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ink)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                    Spacer()
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ink.opacity(0.3)))
        }
    }

    private func row(title: String, detail: String, score: String, accuracy: Double,
                     cost: Double?, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(selected ? "[■]" : "[ ]")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(selected ? cobalt : ink.opacity(0.3))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(ink.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(score)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(cobalt)
            Text(cost.map(priceText) ?? "free")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ink.opacity(0.45))
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(selected ? cobalt.opacity(0.07) : ink.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}


/// Buttons in the palette, so nothing on screen is painted in the system accent.
struct SolidButton: ButtonStyle {
    let cobalt: Color
    let paper: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(paper)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(cobalt.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

struct QuietButton: ButtonStyle {
    let ink: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(ink.opacity(0.8))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(ink.opacity(configuration.isPressed ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}
