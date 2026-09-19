import Foundation

public struct ToolResult: Sendable, Equatable {
    public let ok: Bool
    public let output: String
    public let needsConfirmation: Bool

    public static func success(_ output: String) -> ToolResult {
        ToolResult(ok: true, output: output, needsConfirmation: false)
    }
    public static func failure(_ message: String) -> ToolResult {
        ToolResult(ok: false, output: message, needsConfirmation: false)
    }
    public static func confirm(_ message: String) -> ToolResult {
        ToolResult(ok: false, output: message, needsConfirmation: true)
    }
}

/// Runs one tool by name.
///
/// The model never writes a command. It names a tool and supplies arguments, and
/// this substitutes them into a script we wrote by hand. Every value is escaped
/// before substitution, and that escaping is the security boundary.
public enum Executor {
    /// Apps that must be running before they can be scripted. Finder is absent:
    /// it is always running, and launching it puts a window on screen.
    static let launchable: Set<String> = ["Mail", "Calendar", "Notes", "Reminders"]

    /// Every integer parameter in the catalogue is a limit, so one default serves.
    static let defaultInteger = 10

    public static func run(_ name: String, _ args: [String: String] = [:],
                           confirm: Bool = false, timeout: TimeInterval = 45) -> ToolResult {
        guard let tool = ToolCatalog.tool(named: name) else {
            return .failure("unknown tool: \(name)")
        }
        let unexpected = Set(args.keys).subtracting(tool.params.keys)
        guard unexpected.isEmpty else {
            return .failure("unknown arguments: \(unexpected.sorted())")
        }
        if tool.destructive && !confirm {
            return .confirm(tool.description)
        }

        var script = tool.script
        let shellsOut = script.contains("do shell script")

        for (key, type) in tool.params {
            let raw = args[key] ?? ""
            var value: String

            switch type {
            case "date":
                let when = DatePhrase.parse(raw)
                for (suffix, number) in when.components {
                    script = script.replacingOccurrences(of: "{\(key)_\(suffix)}", with: String(number))
                }
                value = when.iso
            case "integer":
                value = String(Int(raw.trimmingCharacters(in: .whitespaces)) ?? defaultInteger)
            default:
                value = raw
            }

            if key.contains("path") || key == "dest" {
                value = (value as NSString).expandingTildeInPath
            }
            // mdfind matches substrings and has no glob syntax, so a wildcard from
            // the model silently returns nothing.
            if name == "find_file" && key == "name" {
                value = value.replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "?", with: "")
                while value.hasPrefix(".") { value.removeFirst() }
            }
            // Shell escaping first: it introduces double quotes of its own, which
            // the AppleScript pass then has to escape. The other order leaves them
            // raw and the script fails to parse.
            if shellsOut && type != "integer" { value = shellSafe(value) }
            value = appleScriptSafe(value)
            script = script.replacingOccurrences(of: "{\(key)}", with: value)
        }

        if let leftover = firstPlaceholder(in: script) {
            return .failure("unfilled placeholder: \(leftover)")
        }

        // Only launch when the script addresses the app. Several tools are named
        // after an app for grouping but shell out instead, and launching for those
        // opens a window nobody asked for.
        if launchable.contains(tool.app), script.contains("tell application \"\(tool.app)\"") {
            _ = shell(["/usr/bin/open", "-ga", tool.app], timeout: 15)
        }

        let result = shell(["/usr/bin/osascript", "-e", script], timeout: timeout)
        guard result.status == 0 else {
            let message = result.error.isEmpty ? "exit \(result.status)" : result.error
            return .failure(String(message.prefix(300)))
        }
        return .success(result.output)
    }

    /// Escape for an AppleScript string literal, and strip control characters so a
    /// value cannot break out of one.
    public static func appleScriptSafe(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return String(escaped.unicodeScalars.filter { $0 == "\t" || $0.value >= 32 })
    }

    /// Neutralise single quotes for a value inside '...' in a shell command.
    /// Applied on top of the AppleScript escaping, never instead of it.
    public static func shellSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\"'\"'")
    }

    static func firstPlaceholder(in script: String) -> String? {
        guard let range = script.range(of: "\\{[a-z_]+\\}", options: .regularExpression) else {
            return nil
        }
        return String(script[range])
    }

    struct ShellResult { let status: Int32; let output: String; let error: String }

    static func shell(_ arguments: [String], timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return ShellResult(status: -1, output: "", error: "\(error)")
        }

        // Read before waiting: a pipe that fills up deadlocks a process that is
        // still writing to it.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return ShellResult(status: -1, output: "", error: "timeout after \(Int(timeout))s")
        }
        process.waitUntilExit()

        func text(_ data: Data) -> String {
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ShellResult(status: process.terminationStatus,
                           output: text(outData), error: text(errData))
    }
}
