import Foundation

/// Which of the three the app is thinking with.
///
/// Stored as its own value rather than guessed from the base URL. Inferring the
/// backend from a URL or a key prefix is how a request ends up at the wrong host
/// and returns an authentication error that reads like a broken client.
public enum Backend: String, Codable, Sendable, CaseIterable {
    /// Apple Intelligence, already on the Mac, nothing to install and nothing sent.
    case apple
    /// Our own model, downloaded once and served by llama.cpp on this machine.
    case localModel
    /// The person's own Orbio key, against whichever model they picked.
    case orbio
}

/// A global chord: the key, the modifiers, and how to write it down.
///
/// The label is captured when the chord is recorded rather than derived later.
/// Turning a key code back into a character needs the keyboard layout, and a
/// launcher that prints the wrong key to someone on AZERTY has told them a lie
/// about the one thing they need to know.
public struct Chord: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

/// Where Celeritas sends a request.
///
/// The host is configuration, never inferred from the key. A key belonging to one
/// gateway sent to another returns an authentication error that reads like a
/// broken request and sends you debugging your own client.
public struct Endpoint: Codable, Sendable, Equatable {
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// Our own model, served by llama.cpp on this machine. No key, nothing leaves.
    public static let local = Endpoint(baseURL: "http://127.0.0.1:8138/v1",
                                       apiKey: "", model: "local")

    /// Orbio's gateway. The key is the person's own and starts empty.
    public static let orbio = Endpoint(baseURL: "https://www.orbio.so/api/v1",
                                       apiKey: "", model: Shortlist.current.best)
}

public enum Settings {
    /// Which backend answers. Defaults to Apple Intelligence, which needs no setup,
    /// with onboarding asking on first run before anything is sent anywhere.
    public static var backend: Backend {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "backend"),
                  let value = Backend(rawValue: raw) else { return .apple }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "backend") }
    }

    /// The chord that opens the launcher. nil means the built in one, which the
    /// app layer owns because it needs Carbon to name the key codes.
    public static var hotkey: Chord? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "hotkey") else { return nil }
            return try? JSONDecoder().decode(Chord.self, from: data)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "hotkey")
            } else {
                UserDefaults.standard.removeObject(forKey: "hotkey")
            }
        }
    }

    /// Set once onboarding has been answered, so it is never shown twice.
    /// The CPU, memory and disk cards on the empty screen.
    ///
    /// On unless somebody turns it off, so `bool(forKey:)` is not enough on its
    /// own: an unset key reads as false, which would ship the feature disabled
    /// for everyone who never opened settings.
    public static var statCards: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "statCards") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "statCards")
        }
        set { UserDefaults.standard.set(newValue, forKey: "statCards") }
    }

    /// Tokens the person added, newest last.
    ///
    /// Adding and pinning are different things. A watched token is one we keep
    /// a price for, so typing its symbol answers offline. A pinned one also
    /// sits on the empty screen. Somebody can follow a dozen and want three of
    /// them in front of them.
    ///
    /// Both live on this Mac, in the same defaults as the hotkey. Keeping a
    /// watchlist on the lab would mean accounts and holding people's data, for
    /// nothing gained: it is a preference, not something anybody else needs.
    public static var watchedTokens: [String] {
        get { UserDefaults.standard.stringArray(forKey: "watchedTokens") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "watchedTokens") }
    }

    /// The subset shown on the empty screen.
    public static var pinnedTokens: [String] {
        get {
            let watched = watchedTokens
            // Never a pin for something no longer watched, so removing a token
            // cannot leave a ghost on the strip.
            return (UserDefaults.standard.stringArray(forKey: "pinnedTokens") ?? [])
                .filter { pin in watched.contains { $0.caseInsensitiveCompare(pin) == .orderedSame } }
        }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedTokens") }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    @discardableResult
    public static func addToken(_ address: String) -> Bool {
        var held = watchedTokens
        guard !held.contains(where: { same($0, address) }) else { return false }
        held.append(address)
        // A watchlist is a glance, not a portfolio, and every one of these is a
        // price to keep current.
        watchedTokens = Array(held.suffix(20))
        return true
    }

    public static func removeToken(_ address: String) {
        watchedTokens = watchedTokens.filter { !same($0, address) }
        pinnedTokens = pinnedTokens.filter { !same($0, address) }
    }

    public static func setPinned(_ address: String, _ on: Bool) {
        guard on else {
            pinnedTokens = pinnedTokens.filter { !same($0, address) }
            return
        }
        addToken(address)
        var held = pinnedTokens
        guard !held.contains(where: { same($0, address) }) else { return }
        held.append(address)
        // Past about six the strip stops fitting across the panel.
        pinnedTokens = Array(held.suffix(6))
    }

    public static func isPinned(_ address: String) -> Bool {
        pinnedTokens.contains { same($0, address) }
    }

    public static func isWatched(_ address: String) -> Bool {
        watchedTokens.contains { same($0, address) }
    }

    /// The "Try typing" list on the empty screen.
    ///
    /// On by default, because a launcher with a blinking cursor teaches
    /// nothing. Off for anybody who already knows what it does and wants the
    /// panel small. Same trick as `statCards`: an unset key reads as false, so
    /// checking `bool(forKey:)` alone would ship it disabled for everyone who
    /// never opened settings.
    public static var showExamples: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "showExamples") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "showExamples")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showExamples") }
    }

    public static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "hasOnboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "hasOnboarded") }
    }

    /// The HTTP details, used by the local and Orbio backends. Apple Intelligence
    /// ignores it entirely, because there is no host and no key.
    public static var endpoint: Endpoint {
        get {
            guard let data = UserDefaults.standard.data(forKey: "endpoint"),
                  let value = try? JSONDecoder().decode(Endpoint.self, from: data)
            else { return .local }
            return value
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "endpoint")
        }
    }

    /// What the footer and the menu bar should say about where answers come from.
    public static var description: String {
        switch backend {
        case .apple: return "Apple Intelligence"
        case .localModel: return "\(LocalBaseline.model), on this Mac"
        case .orbio: return "\(endpoint.model), via Orbio"
        }
    }
}
