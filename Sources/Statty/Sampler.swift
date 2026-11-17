import AppKit
import Darwin
import Foundation

// MARK: - Snapshot types

struct ProcessStat: Identifiable {
    let pid: pid_t
    let name: String
    let path: String
    let memory: UInt64      // physical footprint, bytes (Activity Monitor's "Memory" column)
    let cpu: Double         // percent of one core
    var id: pid_t { pid }
}

struct GroupStat: Identifiable {
    let meta: GroupMeta
    let memory: UInt64
    let cpu: Double
    let processes: [ProcessStat]
    var id: String { meta.key }
}

struct SystemMemory {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: Int = 1      // 1 normal, 2 warning, 4 critical
    var pressurePercent: Int = 0
}

struct SystemCPU {
    var user: Double = 0            // fraction 0...1 of the whole machine
    var system: Double = 0
    var cores: Int = ProcessInfo.processInfo.activeProcessorCount
}

struct Snapshot {
    let date: Date
    let groups: [GroupStat]
    let memory: SystemMemory
    let cpu: SystemCPU
}

// MARK: - Sampler

/// Reads per-process and system-wide stats. Not thread-safe: call from one serial queue.
final class Sampler {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsible: ResponsibleFn?
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    private var pathCache: [pid_t: String] = [:]
    private var nameCache: [pid_t: String] = [:]
    private var groupCache: [pid_t: GroupMeta] = [:]
    private var prevCPU: [pid_t: UInt64] = [:]      // cumulative CPU ns
    private var prevWall: UInt64 = 0
    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    // Footprints for processes we can't read directly (root / other users), refreshed from `top`.
    private let topLock = NSLock()
    private var topMemory: [pid_t: UInt64] = [:]
    private var topRefreshing = false
    private var lastTopRefresh = Date.distantPast
    private let topQueue = DispatchQueue(label: "statty.top", qos: .utility)

    private let resolver = GroupResolver()

    init() {
        let handle = dlopen(nil, RTLD_NOW)
        if let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") {
            responsible = unsafeBitCast(sym, to: ResponsibleFn.self)
        } else {
            responsible = nil
        }
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        timebaseNumer = UInt64(tb.numer)
        timebaseDenom = UInt64(tb.denom)
    }

    func sample() -> Snapshot {
        refreshTopIfNeeded()
        let wall = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let wallDelta = prevWall == 0 ? 0 : wall - prevWall
        prevWall = wall

        let pids = listPids()
        let alive = Set(pids)
        pathCache = pathCache.filter { alive.contains($0.key) }
        nameCache = nameCache.filter { alive.contains($0.key) }
        groupCache = groupCache.filter { alive.contains($0.key) }

        topLock.lock()
        let topMem = topMemory
        topLock.unlock()

        var psCPU: [pid_t: UInt64]? = nil   // lazily loaded for unreadable processes
        var newCPU: [pid_t: UInt64] = [:]
        newCPU.reserveCapacity(pids.count)
        var byGroup: [String: (meta: GroupMeta, procs: [ProcessStat])] = [:]

        for pid in pids {
            let path = cachedPath(pid)
            var memory: UInt64 = 0
            var cpuNs: UInt64? = nil

            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if rc == 0 {
                memory = info.ri_phys_footprint
                cpuNs = (info.ri_user_time + info.ri_system_time) * timebaseNumer / timebaseDenom
            } else {
                memory = topMem[pid] ?? 0
                if psCPU == nil { psCPU = readPSCPU() }
                cpuNs = psCPU?[pid]
            }

            var cpuPct = 0.0
            if let now = cpuNs {
                newCPU[pid] = now
                if let before = prevCPU[pid], wallDelta > 0, now >= before {
                    cpuPct = Double(now - before) / Double(wallDelta) * 100
                }
            }

            let meta = cachedGroup(pid, path: path)
            let stat = ProcessStat(pid: pid, name: cachedName(pid, path: path), path: path, memory: memory, cpu: cpuPct)
            byGroup[meta.key, default: (meta, [])].procs.append(stat)
        }
        prevCPU = newCPU

        var groups: [GroupStat] = []
        groups.reserveCapacity(byGroup.count)
        for (_, entry) in byGroup {
            var memory: UInt64 = 0
            var cpu = 0.0
            for p in entry.procs { memory += p.memory; cpu += p.cpu }
            let procs = entry.procs.sorted { (a: ProcessStat, b: ProcessStat) in a.memory > b.memory }
            groups.append(GroupStat(meta: entry.meta, memory: memory, cpu: cpu, processes: procs))
        }
        return Snapshot(date: Date(), groups: groups, memory: readSystemMemory(), cpu: readSystemCPU())
    }

    // MARK: Per-process helpers

    private func listPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private func cachedPath(_ pid: pid_t) -> String {
        if let p = pathCache[pid] { return p }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = len > 0 ? String(cString: buf) : ""
        pathCache[pid] = path
        return path
    }

    private func cachedName(_ pid: pid_t, path: String) -> String {
        if let n = nameCache[pid] { return n }
        var name = ""
        // Apps can register a friendlier name with LaunchServices (e.g. "ZenCP Isolated Web Content").
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName, !n.isEmpty {
            name = n
        }
        if name.isEmpty {
            var buf = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &buf, UInt32(buf.count)) > 0 { name = String(cString: buf) }
        }
        if name.isEmpty { name = (path as NSString).lastPathComponent }
        if name.isEmpty { name = pid == 0 ? "kernel_task" : "pid \(pid)" }
        nameCache[pid] = name
        return name
    }

    private func cachedGroup(_ pid: pid_t, path: String) -> GroupMeta {
        if let g = groupCache[pid] { return g }
        var resp = responsible?(pid) ?? -1
        if resp <= 1 || resp == pid { resp = -1 }
        let respPath = resp > 0 ? cachedPath(resp) : ""
        let meta = resolver.resolve(pid: pid, path: path, responsiblePath: respPath)
        groupCache[pid] = meta
        return meta
    }

    // MARK: Fallbacks for processes we can't inspect directly

    /// Cumulative CPU time from `ps`, which can see every process.
    private func readPSCPU() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        for line in runTool("/bin/ps", ["-axo", "pid=,time="]).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }
            out[pid] = parseCPUTime(String(parts[1]))
        }
        return out
    }

    /// Parses `[dd-][hh:]mm:ss.cc` into nanoseconds.
    private func parseCPUTime(_ s: String) -> UInt64 {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var seconds = 0.0
        for part in rest.split(separator: ":") { seconds = seconds * 60 + (Double(part) ?? 0) }
        return UInt64((days * 86_400 + seconds) * 1e9)
    }

    /// `top` can read footprints of root-owned processes (WindowServer, kernel_task...). It costs ~0.5s
    /// of CPU, so run it off the sampling queue every 30s; those processes change slowly.
    private func refreshTopIfNeeded() {
        topLock.lock()
        let due = !topRefreshing && Date().timeIntervalSince(lastTopRefresh) > 30
        if due { topRefreshing = true }
        topLock.unlock()
        guard due else { return }
        topQueue.async { [weak self] in
            guard let self else { return }
            var mem: [pid_t: UInt64] = [:]
            var inTable = false
            for line in runTool("/usr/bin/top", ["-l", "1", "-stats", "pid,mem"]).split(separator: "\n") {
                if line.hasPrefix("PID") { inTable = true; continue }
                guard inTable else { continue }
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let pid = pid_t(parts[0]) else { continue }
                mem[pid] = parseTopSize(String(parts[1]))
            }
            self.topLock.lock()
            self.topMemory = mem
            self.topRefreshing = false
            self.lastTopRefresh = Date()
            self.topLock.unlock()
        }
    }

    // MARK: System-wide

    private func readSystemMemory() -> SystemMemory {
        var m = SystemMemory()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if rc == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let active = UInt64(stats.active_count) * page
            let inactive = UInt64(stats.inactive_count) * page
            let speculative = UInt64(stats.speculative_count) * page
            let wired = UInt64(stats.wire_count) * page
            let compressed = UInt64(stats.compressor_page_count) * page
            let purgeable = UInt64(stats.purgeable_count) * page
            let external = UInt64(stats.external_page_count) * page
            let used = active + inactive + speculative + wired + compressed
            m.used = used > purgeable + external ? used - purgeable - external : used
            m.wired = wired
            m.compressed = compressed
            m.app = m.used > wired + compressed ? m.used - wired - compressed : 0
            m.free = m.total > m.used ? m.total - m.used : 0
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = swap.xsu_used }
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressureLevel = Int(level) }
        var available: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &available, &size, nil, 0) == 0 { m.pressurePercent = 100 - Int(available) }
        return m
    }

    private func readSystemCPU() -> SystemCPU {
        var c = SystemCPU()
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return c }
        let now = (user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                   idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        if let p = prevTicks {
            let du = Double(now.user &- p.user + now.nice &- p.nice)
            let ds = Double(now.system &- p.system)
            let di = Double(now.idle &- p.idle)
            let total = du + ds + di
            if total > 0 { c.user = du / total; c.system = ds / total }
        }
        prevTicks = now
        return c
    }
}

// MARK: - Utilities

/// Parses top's MEM column, e.g. "1311M", "512K+", "1.2G".
func parseTopSize(_ raw: String) -> UInt64 {
    let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
    guard let unit = s.last else { return 0 }
    let mult: Double
    switch unit {
    case "B": mult = 1
    case "K": mult = 1024
    case "M": mult = 1024 * 1024
    case "G": mult = 1024 * 1024 * 1024
    case "T": mult = 1024 * 1024 * 1024 * 1024
    default: return UInt64(Double(s) ?? 0)
    }
    return UInt64((Double(s.dropLast()) ?? 0) * mult)
}

func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
