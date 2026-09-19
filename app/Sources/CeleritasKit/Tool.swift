import Foundation

/// One thing Celeritas can do. The script is written by hand with `{param}` holes
/// in it; the model only ever chooses a name and fills the holes.
public struct Tool: Codable, Sendable, Equatable {
    public let name: String
    public let app: String
    public let destructive: Bool
    public let description: String
    public let params: [String: String]
    public let script: String
}

public enum ToolCatalog {
    /// Every tool, keyed by name. Loaded once from the bundled catalogue.
    public static let all: [String: Tool] = {
        guard let url = Bundle.module.url(forResource: "tools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tools = try? JSONDecoder().decode([Tool].self, from: data)
        else {
            // A missing catalogue is a build error, not a runtime state to handle.
            fatalError("tools.json is missing from the bundle")
        }
        return Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }()

    public static var count: Int { all.count }

    public static func tool(named name: String) -> Tool? { all[name] }

    /// OpenAI-shaped schema, for the whole set or a named subset.
    public static func schema(names: [String]? = nil) -> [[String: Any]] {
        let chosen = names.map { $0.compactMap { all[$0] } } ?? Array(all.values)
        return chosen.map { tool in
            var properties: [String: Any] = [:]
            for (key, type) in tool.params {
                properties[key] = ["type": type == "integer" ? "integer" : "string"]
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description + (tool.destructive ? " [DESTRUCTIVE]" : ""),
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": Array(tool.params.keys),
                    ],
                ],
            ]
        }
    }
}
