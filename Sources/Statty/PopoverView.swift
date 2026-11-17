import AppKit
import Charts
import SwiftUI

struct PopoverView: View {
    @Bindable var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $monitor.metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Picker("", selection: $monitor.window) {
                    ForEach(TimeWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            if let snap = monitor.latest {
                if monitor.metric == .memory {
                    MemorySummary(memory: snap.memory)
                } else {
                    CPUSummary(cpu: snap.cpu)
                }
            }

            UsageChart(monitor: monitor)

            AppList(monitor: monitor)

            Divider()
            HStack {
                Text("Samples every 2s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 460)
    }
}

// MARK: - Summaries

struct MemorySummary: View {
    let memory: SystemMemory
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.bytes(Double(memory.used)))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("used of \(Format.bytes(Double(memory.total)))")
                    .foregroundStyle(.secondary)
                Spacer()
                PressureBadge(level: memory.pressureLevel, percent: memory.pressurePercent)
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) { MemoryHelp() }
            }
            SegmentBar(segments: [
                (Double(memory.app), Palette.memApp),
                (Double(memory.wired), Palette.memWired),
                (Double(memory.compressed), Palette.memCompressed),
                (Double(memory.free), Palette.track),
            ])
            HStack(spacing: 12) {
                LegendItem(color: Palette.memApp, label: "App", value: Format.bytes(Double(memory.app)))
                LegendItem(color: Palette.memWired, label: "Wired", value: Format.bytes(Double(memory.wired)))
                LegendItem(color: Palette.memCompressed, label: "Compressed", value: Format.bytes(Double(memory.compressed)))
                LegendItem(color: Palette.track, label: "Free", value: Format.bytes(Double(memory.free)))
            }
            if memory.swapUsed > 0 {
                Text("Swap: \(Format.bytes(Double(memory.swapUsed))) of memory was moved to disk earlier to free up RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MemoryHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            help("App", "Memory apps are actively using.")
            help("Wired", "Memory macOS has locked in place (kernel, graphics). It can't be compressed or swapped.")
            help("Compressed", "Memory macOS squeezed to make room. Normal and cheap; it's how a Mac avoids swapping.")
            help("Free", "Unused, or cache macOS can drop instantly. Low free memory alone is fine.")
            help("Pressure", "The number that matters: how hard macOS is working to find memory. Yellow or red means apps are being slowed down.")
            help("Per-app numbers", "Match Activity Monitor's Memory column. They count compressed memory at full size, so they can add up to more than Used.")
        }
        .padding(14)
        .frame(width: 320)
    }

    private func help(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PressureBadge: View {
    let level: Int
    let percent: Int

    var body: some View {
        let (label, icon, color): (String, String, Color) = switch level {
        case 4: ("Critical", "exclamationmark.octagon.fill", Palette.critical)
        case 2: ("Elevated", "exclamationmark.triangle.fill", Palette.warning)
        default: ("Normal", "checkmark.circle.fill", Palette.good)
        }
        Label {
            Text("Pressure \(label)").font(.caption.weight(.medium))
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .help("Memory pressure \(percent)%")
    }
}

struct CPUSummary: View {
    let cpu: SystemCPU

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent((cpu.user + cpu.system) * 100))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("of all \(cpu.cores) cores busy")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            SegmentBar(segments: [
                (cpu.user, Palette.memApp),
                (cpu.system, Palette.memCompressed),
                (max(0, 1 - cpu.user - cpu.system), Palette.track),
            ])
            HStack(spacing: 12) {
                LegendItem(color: Palette.memApp, label: "Apps", value: Format.percent(cpu.user * 100))
                LegendItem(color: Palette.memCompressed, label: "System", value: Format.percent(cpu.system * 100))
                LegendItem(color: Palette.track, label: "Idle", value: Format.percent(max(0, 1 - cpu.user - cpu.system) * 100))
            }
            Text("Per-app CPU below uses Activity Monitor's scale: 100% = one full core, so the max is \(cpu.cores * 100)%.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SegmentBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.0 }, 1e-9)
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(seg.1)
                        .frame(width: max(0, (geo.size.width - gaps) * seg.0 / total))
                }
            }
        }
        .frame(height: 10)
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - Chart

struct UsageChart: View {
    let monitor: Monitor
    @State private var hoverDate: Date?

    var body: some View {
        let model = monitor.chart
        let metric = monitor.metric
        let surface = Color(nsColor: .windowBackgroundColor)
        let selected = hoverDate.flatMap { model.nearestFrame(to: $0) }

        VStack(alignment: .leading, spacing: 6) {
            Text(metric == .memory ? "Memory by app" : "CPU by app")
                .font(.headline)
            if model.points.isEmpty {
                Text("Collecting samples…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart {
                    ForEach(model.points) { p in
                        AreaMark(
                            x: .value("Time", p.date),
                            yStart: .value("Low", p.low),
                            yEnd: .value("High", p.high),
                            series: .value("App", p.key)
                        )
                        .foregroundStyle(monitor.color(for: p.key) ?? .gray)
                    }
                    // A thin surface-colored edge separates stacked layers.
                    ForEach(model.points) { p in
                        LineMark(
                            x: .value("Time", p.date),
                            y: .value("High", p.high),
                            series: .value("Edge", p.key)
                        )
                        .foregroundStyle(surface)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.date))
                            .foregroundStyle(.primary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 0,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                HoverCard(frame: selected, series: model.series, metric: metric)
                            }
                    }
                }
                .chartXScale(domain: model.domain)
                .chartYScale(domain: 0...model.yMax)
                .chartXSelection(value: $hoverDate)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(Format.axis(v, metric)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        if model.domain.upperBound.timeIntervalSince(model.domain.lowerBound) < 240 {
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                        } else {
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                }
                .frame(height: 170)
            }
        }
    }
}

struct HoverCard: View {
    let frame: ChartFrame
    let series: [ChartSeries]
    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(frame.date, format: .dateTime.hour().minute().second())
                .font(.caption.weight(.semibold))
            ForEach(series.reversed()) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                    Text(s.name).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Format.chartValue(frame.values[s.key] ?? 0, metric)).monospacedDigit()
                }
                .font(.caption)
            }
            Divider()
            HStack {
                Text("Total")
                Spacer()
                Text(Format.chartValue(frame.values.values.reduce(0, +), metric)).monospacedDigit()
            }
            .font(.caption.weight(.medium))
        }
        .padding(8)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

// MARK: - App list

struct AppList: View {
    @Bindable var monitor: Monitor

    var body: some View {
        let groups = Array(monitor.sortedGroups.prefix(40))
        let metric = monitor.metric
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { g in
                    AppRow(group: g, metric: metric, color: monitor.color(for: g.id),
                           isExpanded: monitor.expanded.contains(g.id)) {
                        if monitor.expanded.contains(g.id) { monitor.expanded.remove(g.id) } else { monitor.expanded.insert(g.id) }
                    }
                    if monitor.expanded.contains(g.id) {
                        let procs = g.processes.sorted { monitor.value($0) > monitor.value($1) }
                        ForEach(procs.prefix(25)) { p in ProcessRow(process: p, metric: metric) }
                        if procs.count > 25 {
                            Text("and \(procs.count - 25) more")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 52)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .frame(height: 300)
    }
}

struct AppRow: View {
    let group: GroupStat
    let metric: Metric
    let color: Color?
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color ?? .clear)
                    .frame(width: 4, height: 22)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                GroupIcon(meta: group.meta)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.meta.name).lineLimit(1)
                    Text(group.processes.count == 1 ? "1 process" : "\(group.processes.count) processes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.metric(metric == .memory ? Double(group.memory) : group.cpu, metric))
                        .monospacedDigit()
                    Text(metric == .memory ? "\(Format.percent(group.cpu)) CPU" : Format.bytes(Double(group.memory)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ProcessRow: View {
    let process: ProcessStat
    let metric: Metric

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).font(.callout).lineLimit(1)
                if let desc = KnownProcesses.describe(process.name) {
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(Format.metric(metric == .memory ? Double(process.memory) : process.cpu, metric))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 52)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .help("\(process.path.isEmpty ? process.name : process.path)  (pid \(process.pid))")
    }
}

struct GroupIcon: View {
    let meta: GroupMeta

    var body: some View {
        Group {
            if let path = meta.bundlePath {
                Image(nsImage: IconCache.icon(for: path)).resizable()
            } else {
                Image(systemName: meta.kind == .system ? "apple.logo" : "terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}
