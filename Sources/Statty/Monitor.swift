import AppKit
import Observation
import SwiftUI

enum Metric: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case cpu = "CPU"
    var id: Self { self }
}

enum TimeWindow: Int, CaseIterable, Identifiable {
    case m5 = 300, m15 = 900, m30 = 1800
    var id: Self { self }
    var label: String { "\(rawValue / 60)m" }
}

struct Frame {
    let date: Date
    let memory: [String: UInt64]
    let cpu: [String: Double]
}

/// One stacked layer of the chart at one point in time.
struct LayerPoint: Identifiable {
    let date: Date
    let key: String
    let low: Double
    let high: Double
    var id: String { "\(key)@\(date.timeIntervalSinceReferenceDate)" }
}

struct ChartSeries: Identifiable {
    let key: String
    let name: String
    let color: Color
    var id: String { key }
}

struct ChartFrame {
    let date: Date
    let values: [String: Double]   // includes ChartModel.otherKey
}

struct ChartModel {
    static let otherKey = "__other__"
    var series: [ChartSeries] = []  // bottom of the stack first
    var points: [LayerPoint] = []
    var frames: [ChartFrame] = []
    var domain: ClosedRange<Date> = Date()...Date()
    var yMax: Double = 1

    func nearestFrame(to date: Date) -> ChartFrame? {
        frames.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

@Observable
@MainActor
final class Monitor {
    static let shared = Monitor()
    static let interval: TimeInterval = 2
    static let maxSeries = 7

    private(set) var latest: Snapshot?
    private(set) var chart = ChartModel()
    var metric: Metric = .memory { didSet { rebuildChart() } }
    var window: TimeWindow = .m5 { didSet { rebuildChart() } }
    var expanded: Set<String> = []

    @ObservationIgnored private var frames: [Frame] = []
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var slots: [Metric: [String: Int]] = [:]
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "statty.sampler", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var sampleCount = 0

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.sampler.sample()
            DispatchQueue.main.async { self.ingest(snapshot) }
        }
        t.resume()
        timer = t
    }

    private func ingest(_ s: Snapshot) {
        sampleCount += 1
        latest = s
        // The first sample has no CPU baseline, so it would show every app at 0%.
        guard sampleCount > 1 else { return }
        var mem: [String: UInt64] = [:]
        var cpu: [String: Double] = [:]
        for g in s.groups {
            mem[g.meta.key] = g.memory
            cpu[g.meta.key] = g.cpu
            names[g.meta.key] = g.meta.name
        }
        frames.append(Frame(date: s.date, memory: mem, cpu: cpu))
        let cutoff = s.date.addingTimeInterval(-Double(TimeWindow.m30.rawValue) - 10)
        if let firstKept = frames.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            frames.removeFirst(firstKept)
        }
        rebuildChart()
    }

    func value(_ g: GroupStat) -> Double { metric == .memory ? Double(g.memory) : g.cpu }
    func value(_ p: ProcessStat) -> Double { metric == .memory ? Double(p.memory) : p.cpu }

    var sortedGroups: [GroupStat] {
        (latest?.groups ?? []).sorted { value($0) > value($1) }
    }

    func color(for key: String) -> Color? {
        if key == ChartModel.otherKey { return Palette.other }
        return chart.series.first { $0.key == key }?.color
    }

    // MARK: Chart building

    private func frameValues(_ f: Frame) -> [String: Double] {
        switch metric {
        case .memory: return f.memory.mapValues { Double($0) / 1_073_741_824 }  // chart in GB
        case .cpu: return f.cpu
        }
    }

    private func rebuildChart() {
        guard let last = frames.last else { chart = ChartModel(); return }
        let start = last.date.addingTimeInterval(-Double(window.rawValue))
        let visible = frames.filter { $0.date >= start }
        let valueFrames = visible.map { ($0.date, frameValues($0)) }

        // Rank by average over the visible window so the chart doesn't reshuffle on every spike.
        var sums: [String: Double] = [:]
        for (_, values) in valueFrames { for (k, v) in values { sums[k, default: 0] += v } }
        let top = sums.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(Self.maxSeries).map(\.key)

        // Keep each app's color while it stays in the top set: color follows the app, not its rank.
        var assigned = (slots[metric] ?? [:]).filter { top.contains($0.key) }
        var free = Array(0..<Self.maxSeries).filter { !assigned.values.contains($0) }
        for key in top where assigned[key] == nil { assigned[key] = free.removeFirst() }
        slots[metric] = assigned

        var series = top.map { ChartSeries(key: $0, name: names[$0] ?? $0, color: Palette.series[assigned[$0]!]) }
        series.append(ChartSeries(key: ChartModel.otherKey, name: "Everything else", color: Palette.other))

        // At most ~150 points per series keeps Swift Charts cheap.
        let stride = max(1, valueFrames.count / 150)
        var points: [LayerPoint] = []
        var chartFrames: [ChartFrame] = []
        var yMax = 0.0
        for i in Swift.stride(from: valueFrames.count - 1, through: 0, by: -stride).reversed() {
            let (date, values) = valueFrames[i]
            let total = values.values.reduce(0, +)
            var row: [String: Double] = [:]
            var base = 0.0
            for s in series {
                let v = s.key == ChartModel.otherKey ? max(0, total - base) : (values[s.key] ?? 0)
                row[s.key] = v
                points.append(LayerPoint(date: date, key: s.key, low: base, high: base + v))
                base += v
            }
            yMax = max(yMax, base)
            chartFrames.append(ChartFrame(date: date, values: row))
        }

        var model = ChartModel()
        model.series = series
        model.points = points
        model.frames = chartFrames
        // Until there's a full window of history, span what we have rather than leaving the left empty.
        model.domain = max(start, visible.first?.date ?? start)...last.date
        model.yMax = max(yMax * 1.05, metric == .memory ? 1 : 10)
        chart = model
    }
}

enum Palette {
    // Categorical slots, light and dark steps of the same hues; order chosen for colorblind separation.
    static let series: [Color] = [
        dynamic(light: 0x2a78d6, dark: 0x3987e5),  // blue
        dynamic(light: 0xeb6834, dark: 0xd95926),  // orange
        dynamic(light: 0x1baf7a, dark: 0x199e70),  // aqua
        dynamic(light: 0xeda100, dark: 0xc98500),  // yellow
        dynamic(light: 0xe87ba4, dark: 0xd55181),  // magenta
        dynamic(light: 0x008300, dark: 0x0ca30c),  // green
        dynamic(light: 0x6250d6, dark: 0x9085e9),  // violet
    ]
    static let other = dynamic(light: 0xc3c2b7, dark: 0x4a4a46)
    static let good = Color(hex: 0x0ca30c)
    static let warning = Color(hex: 0xfab219)
    static let critical = Color(hex: 0xd03b3b)
    // Memory composition (an ordered set, so one hue light-to-dark rather than series colors).
    static let memApp = dynamic(light: 0x256abf, dark: 0x5598e7)
    static let memWired = dynamic(light: 0x5598e7, dark: 0x2a78d6)
    static let memCompressed = dynamic(light: 0x9ec5f4, dark: 0x184f95)
    static let track = dynamic(light: 0xe1e0d9, dark: 0x383835)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

enum Format {
    static func bytes(_ b: Double) -> String {
        let gb = b / 1_073_741_824
        if gb >= 10 { return String(format: "%.1f GB", gb) }
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = b / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", b / 1024)
    }

    static func percent(_ p: Double) -> String {
        p < 10 && p > 0 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    static func metric(_ v: Double, _ m: Metric) -> String {
        m == .memory ? bytes(v) : percent(v)
    }

    /// Chart values are GB for memory and percent for CPU.
    static func chartValue(_ v: Double, _ m: Metric) -> String {
        m == .memory ? bytes(v * 1_073_741_824) : percent(v)
    }

    static func axis(_ v: Double, _ m: Metric) -> String {
        if v == 0 { return "0" }
        let n = v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return m == .memory ? "\(n) GB" : "\(n)%"
    }
}
