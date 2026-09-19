import Foundation

public struct SecondaryAction: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    /// Spelled for a person: "command c", not "⌘C".
    public let keys: [String]

    public init(id: String, title: String, keys: [String]) {
        self.id = id
        self.title = title
        self.keys = keys
    }
}

/// What else you can do with the selected row. Kept here rather than in the view
/// so the list is testable and cannot drift from what the row actually is.
public enum Actions {
    public static func forResult(_ result: Result) -> [SecondaryAction] {
        switch result.kind {
        case .app:
            return [
                SecondaryAction(id: "open", title: "Open", keys: ["return"]),
                SecondaryAction(id: "reveal", title: "Show in Finder", keys: ["command", "return"]),
                SecondaryAction(id: "copyPath", title: "Copy path", keys: ["command", "c"]),
            ]
        case .calculator:
            return [
                SecondaryAction(id: "copy", title: "Copy answer", keys: ["return"]),
            ]
        case .action:
            return [
                SecondaryAction(id: "run", title: "Run", keys: ["return"]),
                SecondaryAction(id: "copyName", title: "Copy tool name", keys: ["command", "c"]),
            ]
        case .ask:
            return [
                SecondaryAction(id: "ask", title: "Ask the model", keys: ["return"]),
                SecondaryAction(id: "copyQuery", title: "Copy question", keys: ["command", "c"]),
            ]
        case .settings:
            return [
                SecondaryAction(id: "settings", title: "Open Settings", keys: ["return"]),
            ]
        case .conversion:
            // A token row carries its address, which is what makes it pinnable
            // and is worth copying on its own. Everything else that copies is
            // just an answer.
            if let address = result.arguments["token"] {
                return [
                    SecondaryAction(id: "copy", title: "Copy price", keys: ["return"]),
                    Settings.isPinned(address)
                        ? SecondaryAction(id: "unpin", title: "Unpin from the empty screen",
                                          keys: ["command", "p"])
                        : SecondaryAction(id: "pin", title: "Pin to the empty screen",
                                          keys: ["command", "p"]),
                    Settings.isWatched(address)
                        ? SecondaryAction(id: "forget", title: "Stop following",
                                          keys: ["command", "d"])
                        : SecondaryAction(id: "follow", title: "Follow this token",
                                          keys: ["command", "d"]),
                    SecondaryAction(id: "copyAddress", title: "Copy address",
                                    keys: ["command", "c"]),
                ]
            }
            return [
                SecondaryAction(id: "copy", title: "Copy answer", keys: ["return"]),
            ]
        }
    }
}
