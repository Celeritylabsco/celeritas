import Foundation

/// Our own model, served by llama.cpp on this machine.
///
/// llama.cpp does the download. Given `-hf owner/repo:quant` it fetches the GGUF
/// into its own cache, resumes a part-finished file and reuses it forever after,
/// which is a lot of behaviour not worth reimplementing. Celeritas starts the
/// process, watches the log, and reports what is happening in words.
@MainActor
public final class LocalModel: ObservableObject {
    public static let shared = LocalModel()

    /// The model the lab publishes and the benchmark scored.
    public static let repo = "LiquidAI/LFM2.5-2.6B-GGUF:Q4_0"
    public static let port = 8138
    /// Measured by deleting it: 1.5 GB on disk. Only used to turn bytes into a
    /// percentage, and the wording says "about" because the quant could change.
    static let approximateBytes: Int64 = 1_500_000_000

    public enum State: Equatable {
        case idle
        /// llama.cpp is not installed, so there is nothing to start.
        case needsLlama
        case downloading(String)
        case starting
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    private var process: Process?
    private var logPath: String { NSTemporaryDirectory() + "celeritas-llama.log" }

    private init() {}

    /// Homebrew installs to different prefixes on Apple silicon and Intel, and a
    /// GUI app does not inherit the shell's PATH, so both are checked by hand.
    public static var llamaServer: String? {
        let candidates = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool { llamaServer != nil }

    /// Already serving, from this launch or a previous one.
    public static func isServing() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Is a server for our model already running, started by us or by a previous
    /// launch of the app? Quitting Celeritas does not kill the download it began,
    /// so a restart has to be able to find it again rather than offer to start a
    /// second one on the same port.
    public static func serverRunning() -> Bool {
        let name = repo.split(separator: ":").first.map(String.init) ?? repo
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "llama-server.*\(name)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return !data.isEmpty
    }

    /// What the state is right now, worked out from the machine rather than from
    /// what this object remembers. Called when settings opens.
    public func refresh() async {
        if await Self.isServing() { state = .ready; return }
        if Self.serverRunning() { state = Self.progress(in: logPath); return }
        if !Self.isInstalled { state = .needsLlama; return }
        let bytes = Self.bytesOnDisk()
        if bytes > 1_000_000 {
            state = .failed("Part downloaded, \(bytes / 1_000_000) MB on disk. Press Save to resume.")
            return
        }
        state = .idle
    }

    public func start() async {
        if await Self.isServing() { state = .ready; return }
        guard let binary = Self.llamaServer else { state = .needsLlama; return }

        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let log = FileHandle(forWritingAtPath: logPath) else {
            state = .failed("Could not open a log file."); return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["-hf", Self.repo,
                          "--port", String(Self.port), "--host", "127.0.0.1",
                          "--jinja", "-c", "8192"]
        task.standardOutput = log
        task.standardError = log
        do { try task.run() } catch {
            state = .failed(error.localizedDescription); return
        }
        process = task
        state = .downloading("Starting")

        // Poll rather than parse a stream. llama.cpp writes progress with carriage
        // returns, so a line reader sees one enormous line and reports nothing.
        for _ in 0..<720 {
            if await Self.isServing() { state = .ready; return }
            if !task.isRunning {
                state = .failed(Self.lastError(in: logPath) ?? "llama-server stopped.")
                return
            }
            state = Self.progress(in: logPath)
            try? await Task.sleep(for: .seconds(1))
        }
        state = .failed("Gave up after twelve minutes.")
    }

    public func stop() {
        process?.terminate()
        process = nil
        state = .idle
    }

    /// Where Hugging Face puts the file llama.cpp asks it for.
    static var cacheDirectory: String {
        let name = repo.split(separator: ":").first.map(String.init) ?? repo
        let slug = "models--" + name.replacingOccurrences(of: "/", with: "--")
        return NSHomeDirectory() + "/.cache/huggingface/hub/" + slug
    }

    /// Free space on the volume the cache lives on, so someone is told before they
    /// start rather than after a download dies part way through.
    public static func freeBytes() -> Int64 {
        let path = NSHomeDirectory()
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        return free
    }

    public static func freeDescription() -> String {
        let free = freeBytes()
        guard free > 0 else { return "unknown" }
        return String(format: "%.1f GB", Double(free) / 1_000_000_000)
    }

    /// Whether the download can fit, with headroom. llama.cpp writes a partial
    /// file first, so the peak is roughly the model plus a little.
    public static func hasRoom() -> Bool {
        freeBytes() > approximateBytes + 500_000_000
    }

    static func bytesOnDisk() -> Int64 {
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: cacheDirectory) else { return 0 }
        var total: Int64 = 0
        for case let file as String in walk {
            let full = cacheDirectory + "/" + file
            if let size = try? fm.attributesOfItem(atPath: full)[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// How far along, measured on disk rather than read out of the log.
    ///
    /// llama.cpp draws its download progress with carriage returns and only when
    /// it has a terminal. Redirected to a file it writes nothing at all, so the
    /// first version of this reported "Starting" for the whole download. The
    /// bytes on disk are the truth and need no parsing.
    static func progress(in path: String) -> State {
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           text.contains("llama_model_loader") || text.contains("loading model") {
            return .starting
        }
        let bytes = bytesOnDisk()
        guard bytes > 1_000_000 else { return .downloading("Fetching the model file") }
        let mb = bytes / 1_000_000
        let percent = min(99, Int(bytes * 100 / approximateBytes))
        return .downloading("\(percent)%, \(mb) MB of about 1.5 GB")
    }

    private static func lastError(in path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").filter {
            $0.lowercased().contains("error") || $0.contains("failed")
        }
        return lines.last.map { String($0.prefix(160)) }
    }
}
