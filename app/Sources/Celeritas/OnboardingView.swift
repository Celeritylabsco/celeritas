import AppKit
import CeleritasKit
import SwiftUI

/// First run. Three ways to answer a question, with what each one scored.
///
/// The ladder is real and it is the point of showing it. Apple Intelligence needs
/// nothing and costs nothing. Our own model needs a download and scores better.
/// A frontier model through an Orbio key scores better again and costs a fraction
/// of a cent per question. Someone choosing should see that before they choose,
/// not discover it later when an answer is worse than they expected.
struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    var finish: () -> Void

    /// Header and footer stay put, the choices scroll. On a short screen the key
    /// field pushed "Start Celeritas" off the bottom, which left no way to finish.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.cobalt).frame(height: 2)
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        ForEach(Backend.allCases, id: \.self) { backend in
                            card(backend)
                        }
                    }
                    .padding(18)

                    if state.choice == .orbio { keyField }
                    if state.choice == .localModel { localStatus }
                }
            }
            Divider().overlay(Palette.ink.opacity(0.12))
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 620)
        .background(Palette.paper)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("[■]").font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.cobalt)
                Text("Celeritas").font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.72))
            }
            Text("Pick where answers come from")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Palette.ink)
            // Never write the count out. The scores beside each option come from
            // the held-out split, and this line said 55 while they said 22.
            Text("Scores are out of \(Shortlist.current.tasks) held-out tool-use tasks, "
                 + "the same tasks for every model. You can change this any time in Settings.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func card(_ backend: Backend) -> some View {
        let chosen = state.choice == backend
        let blocked = state.blocked(backend)
        return Button { if blocked == nil { state.choice = backend } } label: {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    Circle().strokeBorder(chosen ? Palette.cobalt : Palette.ink.opacity(0.25),
                                          lineWidth: chosen ? 5 : 1)
                        .frame(width: 15, height: 15)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(Self.title(backend))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text(Self.score(backend))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Self.scored(backend) ? Palette.cobalt
                                                                  : Palette.ink.opacity(0.4))
                    }
                    Text(blocked ?? Self.detail(backend))
                        .font(.system(size: 12))
                        .foregroundStyle(blocked == nil ? Palette.ink.opacity(0.55)
                                                        : Palette.ink.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Palette.cobalt.opacity(0.07) : Palette.ink.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(chosen ? Palette.cobalt.opacity(0.4) : Palette.ink.opacity(0.1)))
            .opacity(blocked == nil ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    static func title(_ backend: Backend) -> String {
        switch backend {
        case .apple: return "Apple Intelligence"
        case .localModel: return "Our model, on this Mac"
        case .orbio: return "Your own Orbio key"
        }
    }

    /// Never invent a number. Apple Intelligence has a score because it was put
    /// through the same suite; anything unmeasured says so instead.
    static func score(_ backend: Backend) -> String {
        switch backend {
        case .apple: return AppleBaseline.score ?? "not measured yet"
        // Both from the same split, or the toggle shows 39/55 beside 18/22 and
        // invites a comparison that is not one.
        case .localModel:
            return Shortlist.current.byScore.first { $0.local == true }?.score
                ?? LocalBaseline.score
        case .orbio: return Shortlist.current.throughGateway.first?.score ?? ""
        }
    }

    static func scored(_ backend: Backend) -> Bool {
        backend != .apple || AppleBaseline.score != nil
    }

    static func detail(_ backend: Backend) -> String {
        switch backend {
        case .apple:
            return "Already on this Mac. Nothing to install, nothing leaves the machine, "
                 + "and no cost. Slower than a frontier model and not yet scored on our "
                 + "suite, so pick it for privacy rather than for strength."
        case .localModel:
            return "\(LocalModel.repo.split(separator: ":").first.map(String.init) ?? "") "
                 + "downloaded once, then served on this machine. Free and private, and "
                 + "it needs llama.cpp and about 1.6 GB of disk."
        case .orbio:
            // Per question, never per run. costPerRun is the whole benchmark
            // suite, and printing it here made one question look 55x dearer.
            let best = Shortlist.current.byScore.first
            let each = best.map { Shortlist.current.perQuestion($0) } ?? 0.00006
            return "The strongest models here, about $\(String(format: "%.5f", each)) "
                 + "a question, paid to Orbio. Every answer shows what it cost. "
                 + "Your questions leave this Mac."
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your Orbio key")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.7))
            SecureField("", text: $state.key, prompt: Text("sk-orb-…")
                .foregroundStyle(Palette.ink.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Palette.ink.opacity(0.18)))
            Text("Stored on this Mac only. You can skip this and add it later in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink.opacity(0.45))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var localStatus: some View {
        HStack(spacing: 9) {
            switch state.local {
            case .needsLlama:
                Text("llama.cpp is not installed. Run  brew install llama.cpp  then come back.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.6))
            case .downloading(let what):
                ProgressView().controlSize(.small)
                Text(what).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
            case .starting:
                ProgressView().controlSize(.small)
                Text("Loading the model").font(.system(size: 12))
                    .foregroundStyle(Palette.ink.opacity(0.6))
            case .ready:
                Text("Ready").font(.system(size: 12)).foregroundStyle(Palette.cobalt)
            case .failed(let why):
                Text(why).font(.system(size: 11.5)).foregroundStyle(Palette.ink.opacity(0.6))
                    .lineLimit(2)
            case .idle:
                Text("The download starts when you continue, and runs once.")
                    .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Change this any time in Settings")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink.opacity(0.45))
            Spacer()
            Button("Start Celeritas") { state.commit(); finish() }
                .buttonStyle(SolidButton(cobalt: Palette.cobalt, paper: Palette.paper))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Palette.ink.opacity(0.025))
    }
}

@MainActor
final class OnboardingState: ObservableObject {
    @Published var choice: Backend = .apple
    @Published var key: String = ""
    @Published var local: LocalModel.State = .idle

    private var watching: Task<Void, Never>?

    init() {
        // Start on something this Mac can actually run, so the default is never a
        // greyed out card.
        if #available(macOS 26.0, *), AppleClient.isAvailable {
            choice = .apple
        } else {
            choice = .orbio
        }
    }

    /// Why a card cannot be picked, or nil when it can.
    func blocked(_ backend: Backend) -> String? {
        switch backend {
        case .apple:
            if #available(macOS 26.0, *) { return AppleClient.unavailableReason }
            return "Apple Intelligence needs macOS 26."
        case .localModel, .orbio:
            return nil
        }
    }

    func commit() {
        Settings.backend = choice
        switch choice {
        case .orbio:
            var endpoint = Endpoint.orbio
            endpoint.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.endpoint = endpoint
        case .localModel:
            Settings.endpoint = .local
            watching?.cancel()
            watching = Task { await LocalModel.shared.start() }
        case .apple:
            if #available(macOS 26.0, *) { AppleClient.prewarm() }
        }
        Settings.hasOnboarded = true
    }

    /// Mirror the download state onto this screen while it runs.
    func watchLocal() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                self?.local = LocalModel.shared.state
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}
