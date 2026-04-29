import Foundation
import Darwin

/// Lightweight live-stats source for the menu bar popover. Refreshes
/// CPU / memory / disk on a timer that only ticks while the popover is
/// open — `start()` from `.onAppear`, `stop()` from `.onDisappear` so
/// we don't burn battery sampling stats no one's looking at.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var memoryUsedBytes: Int64 = 0
    @Published var memoryTotalBytes: Int64 = 0
    @Published var diskFreeBytes: Int64 = 0
    @Published var diskTotalBytes: Int64 = 0

    private var timer: Timer?
    private var lastUserTicks: UInt64 = 0
    private var lastSystemTicks: UInt64 = 0
    private var lastIdleTicks: UInt64 = 0
    private var lastNiceTicks: UInt64 = 0
    private var hasBaseline = false

    var memoryUsedPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    var diskFreePercent: Double {
        guard diskTotalBytes > 0 else { return 0 }
        return Double(diskFreeBytes) / Double(diskTotalBytes)
    }

    func start(every interval: TimeInterval = 5) {
        stop()
        sampleOnce()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sampleOnce() {
        cpuPercent = currentCPULoad()
        let mem = currentMemory()
        memoryUsedBytes = mem.used
        memoryTotalBytes = mem.total
        let disk = currentDisk()
        diskFreeBytes = disk.free
        diskTotalBytes = disk.total
    }

    // MARK: - CPU

    /// Reads cumulative CPU ticks via host_statistics(HOST_CPU_LOAD_INFO),
    /// then returns the percentage of non-idle ticks since the last
    /// sample. First call returns 0 (no baseline yet) so the bar starts
    /// at zero rather than spiking on launch.
    private func currentCPULoad() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return cpuPercent }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        defer {
            lastUserTicks = user
            lastSystemTicks = system
            lastIdleTicks = idle
            lastNiceTicks = nice
            hasBaseline = true
        }

        guard hasBaseline else { return 0 }
        let userDelta = user &- lastUserTicks
        let systemDelta = system &- lastSystemTicks
        let idleDelta = idle &- lastIdleTicks
        let niceDelta = nice &- lastNiceTicks
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return 0 }
        let nonIdle = userDelta + systemDelta + niceDelta
        return Double(nonIdle) / Double(total)
    }

    // MARK: - Memory

    /// Used = active + wired + compressed (the same definition Activity
    /// Monitor uses for "Memory Used"). Inactive pages aren't counted —
    /// they're available for the system to reclaim instantly.
    private func currentMemory() -> (used: Int64, total: Int64) {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        let activeBytes = Int64(stats.active_count) * Int64(pageSize)
        let wiredBytes = Int64(stats.wire_count) * Int64(pageSize)
        let compressedBytes = Int64(stats.compressor_page_count) * Int64(pageSize)
        let used = activeBytes + wiredBytes + compressedBytes

        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        return (used, total)
    }

    // MARK: - Disk

    private func currentDisk() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]),
              let free = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity
        else { return (0, 0) }
        return (Int64(free), Int64(total))
    }
}
