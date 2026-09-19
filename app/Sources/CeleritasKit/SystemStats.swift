import Darwin
import Foundation

/// CPU and memory, read from the kernel rather than a shell.
///
/// The `cpu` and `memory` tools shell out through AppleScript, which is fine
/// for a question somebody asks now and then. The menu bar readout samples
/// every few seconds forever, and spawning `vm_stat` and `ps` on a timer would
/// cost more than the numbers are worth. These are the same figures straight
/// from Mach, in microseconds and with no subprocess.
/// One process and what it is using.
public struct Usage: Sendable, Equatable, Identifiable {
    public let name: String
    public let value: String
    public var id: String { name }
}

public struct SystemStats: Sendable, Equatable {
    /// 0 to 100, across all cores, since the previous sample.
    public let cpu: Double
    public let memoryUsed: UInt64
    public let memoryTotal: UInt64

    public var memoryFraction: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
    }

    /// "8.1G". Menu bar space is scarce, so one decimal and no unit word.
    public var memoryShort: String {
        let gigabytes = Double(memoryUsed) / 1_073_741_824
        return gigabytes >= 10 ? String(format: "%.0fG", gigabytes)
                               : String(format: "%.1fG", gigabytes)
    }

    /// Padded to a fixed width. Unpadded, the menu bar shuffles every time the
    /// figure crosses 10 or 100 and everything to its left twitches.
    public var cpuShort: String { String(format: "%3.0f%%", cpu) }
}

/// Everything the stat cards show. One trip, so the four numbers on screen are
/// all from the same instant rather than drifting apart.
public struct Machine: Sendable, Equatable {
    public let cpu: Double
    public let memoryUsed: UInt64
    public let memoryTotal: UInt64
    public let diskFree: UInt64
    public let diskTotal: UInt64
    public let topCPU: [Usage]
    public let topMemory: [Usage]

    public static let empty = Machine(cpu: 0, memoryUsed: 0, memoryTotal: 0,
                                      diskFree: 0, diskTotal: 0,
                                      topCPU: [], topMemory: [])

    public var cpuText: String { String(format: "%.0f%%", cpu) }
    public var memoryText: String { Machine.gigabytes(memoryUsed) }
    public var diskText: String { Machine.gigabytes(diskFree) }

    public var memoryFraction: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
    }
    public var diskFraction: Double {
        diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        if value >= 1000 { return String(format: "%.1fT", value / 1024) }
        return value >= 100 ? String(format: "%.0fG", value)
                            : String(format: "%.1fG", value)
    }
}

public actor SystemMonitor {
    public static let shared = SystemMonitor()

    /// CPU ticks are counted since boot, so a single reading says what the
    /// machine has averaged since it turned on. The useful number is the
    /// difference between two readings, which means keeping the last one.
    private var previous: (busy: Double, total: Double)?

    /// Everything the cards need. The process lists come from `ps`, which is a
    /// subprocess and therefore only worth running while somebody is looking at
    /// the numbers. The palette stops asking the moment it closes.
    public func machine() -> Machine {
        let stats = sample()
        let (free, total) = disk()
        return Machine(cpu: stats.cpu,
                       memoryUsed: stats.memoryUsed, memoryTotal: stats.memoryTotal,
                       diskFree: free, diskTotal: total,
                       topCPU: totals(flag: "r", column: "pcpu").prefix(3)
                           .map { Usage(name: $0.0, value: percent($0.1)) },
                       topMemory: totals(flag: "m", column: "rss").prefix(3)
                           .map { Usage(name: $0.0, value: megabytes($0.1)) })
    }

    private func disk() -> (UInt64, UInt64) {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeTotalCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        // The "important usage" figure is what Finder shows as available, which
        // counts space macOS would free by evicting purgeable files. Anything
        // else disagrees with the number the person can already see.
        let free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func megabytes(_ kilobytes: Double) -> String {
        let value = kilobytes / 1024
        return value >= 1024 ? String(format: "%.1f GB", value / 1024)
                             : String(format: "%.0f MB", value)
    }

    /// `ps -Aro pcpu=,comm=` for CPU, `-Amo rss=,comm=` for memory.
    ///
    /// Totalled per app rather than per process, which is the honest number.
    /// A browser runs a separate process for every tab, so the largest single
    /// one is a fraction of what the browser is actually holding, and a list of
    /// three renderers tells nobody anything.
    private func totals(flag: String, column: String) -> [(String, Double)] {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A\(flag)o", "\(column)=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        var sums: [String: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
            guard parts.count == 2, let value = Double(parts[0]), value > 0 else { continue }
            let name = Self.appName(from: String(parts[1]))
            guard !name.isEmpty else { continue }
            sums[name, default: 0] += value
        }
        return sums.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    /// The app a process belongs to, from its path.
    ///
    /// `comm` reports the executable, which for anything modern is buried in a
    /// helper bundle: ChatGPT's renderer is "Codex (Renderer)" and Spotify's is
    /// "Spotify Helper (Renderer)". The first `.app` in the path is the one the
    /// person installed, so that is the name to show.
    public static func appName(from path: String) -> String {
        if let range = path.range(of: ".app/") {
            let name = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        var name = (path as NSString).lastPathComponent
        // A reverse domain name is the bundle id, and nobody reads
        // com.apple.Virtualization.VirtualMachine to learn it is a VM.
        if name.filter({ $0 == "." }).count >= 2, let last = name.split(separator: ".").last {
            name = String(last)
        }
        return name
    }

    public func sample() -> SystemStats {
        SystemStats(cpu: cpuPercent(),
                    memoryUsed: memoryUsed(),
                    memoryTotal: ProcessInfo.processInfo.physicalMemory)
    }

    private func cpuPercent() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        defer { previous = (busy, total) }
        // The first sample has nothing to subtract from, so it reports zero
        // rather than the average since boot, which would be a different
        // number wearing the same label.
        guard let last = previous else { return 0 }
        let spentTotal = total - last.total
        guard spentTotal > 0 else { return 0 }
        return min(100, max(0, (busy - last.busy) / spentTotal * 100))
    }

    /// Active, wired and compressed, which is close to what Activity Monitor
    /// calls memory used. Free and inactive pages are available to whatever
    /// asks next, so counting them as used would make every Mac look full.
    private func memoryUsed() -> UInt64 {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Asked for rather than read off the global `vm_kernel_page_size`,
        // which strict concurrency rejects as shared mutable state.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        let page = UInt64(pageSize)
        return (UInt64(info.active_count)
                + UInt64(info.wire_count)
                + UInt64(info.compressor_page_count)) * page
    }
}
