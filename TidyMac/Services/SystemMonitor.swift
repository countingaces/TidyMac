import Foundation
import Darwin

/// Lightweight live-stats source for the menu bar popover. Refreshes
/// CPU / memory / disk on a timer that only ticks while the popover is
/// open — `start()` from `.onAppear`, `stop()` from `.onDisappear` so
/// we don't burn battery sampling stats no one's looking at.
///
/// All sampling syscalls run on a background `Task.detached` so they
/// can't block the popover's render — even if the system is under
/// load (mid-shutdown, busy disk, etc.). The very first sample is
/// deferred 200 ms after `start()` so the popover paints before we
/// touch the kernel.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var memoryUsedBytes: Int64 = 0
    @Published var memoryTotalBytes: Int64 = 0
    @Published var diskFreeBytes: Int64 = 0
    @Published var diskTotalBytes: Int64 = 0

    private var timer: Timer?
    private var baseline = CPUBaseline()

    /// Cumulative tick counts from the previous sample, used to compute
    /// percent CPU as a delta. First sample after start() returns 0.
    private struct CPUBaseline: Sendable {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        var hasBaseline = false
    }

    /// Result handed back to the main actor after a background sample.
    private struct Snapshot: Sendable {
        let cpuPercent: Double
        let memUsed: Int64
        let memTotal: Int64
        let diskFree: Int64
        let diskTotal: Int64
        let newBaseline: CPUBaseline
    }

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
        // First fire is 200 ms out so the popover paints before we
        // syscall. Subsequent fires are on the regular interval.
        let firstFire = Date(timeIntervalSinceNow: 0.2)
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
            self?.scheduleSample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Bounce out to a background task to do the actual host_statistics
    /// / vm_statistics64 / URL.resourceValues work, then back to main
    /// only to publish the new values. Keeps the main thread free.
    private func scheduleSample() {
        let baselineCopy = baseline
        Task.detached(priority: .userInitiated) {
            let snapshot = Self.takeSnapshot(baseline: baselineCopy)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cpuPercent = snapshot.cpuPercent
                self.memoryUsedBytes = snapshot.memUsed
                self.memoryTotalBytes = snapshot.memTotal
                self.diskFreeBytes = snapshot.diskFree
                self.diskTotalBytes = snapshot.diskTotal
                self.baseline = snapshot.newBaseline
            }
        }
    }

    // MARK: - Background sampling (pure functions, never touch @Published)

    private nonisolated static func takeSnapshot(baseline: CPUBaseline) -> Snapshot {
        let cpu = sampleCPU(baseline: baseline)
        let mem = sampleMemory()
        let disk = sampleDisk()
        return Snapshot(
            cpuPercent: cpu.percent,
            memUsed: mem.used,
            memTotal: mem.total,
            diskFree: disk.free,
            diskTotal: disk.total,
            newBaseline: cpu.newBaseline
        )
    }

    private nonisolated static func sampleCPU(baseline: CPUBaseline) -> (percent: Double, newBaseline: CPUBaseline) {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, baseline) }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        var newBaseline = CPUBaseline(user: user, system: system, idle: idle, nice: nice, hasBaseline: true)
        guard baseline.hasBaseline else { return (0, newBaseline) }

        let userDelta = user &- baseline.user
        let systemDelta = system &- baseline.system
        let idleDelta = idle &- baseline.idle
        let niceDelta = nice &- baseline.nice
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return (0, newBaseline) }
        let nonIdle = userDelta + systemDelta + niceDelta
        return (Double(nonIdle) / Double(total), newBaseline)
    }

    /// Used = active + wired + compressed (the same definition Activity
    /// Monitor uses for "Memory Used"). Inactive pages aren't counted —
    /// they're available for the system to reclaim instantly.
    private nonisolated static func sampleMemory() -> (used: Int64, total: Int64) {
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

    private nonisolated static func sampleDisk() -> (free: Int64, total: Int64) {
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
