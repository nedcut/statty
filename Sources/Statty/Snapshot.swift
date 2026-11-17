import AppKit
import SwiftUI

/// Debug mode: `Statty --snapshot out.png [seconds]` samples for a while, renders the popover to a PNG,
/// prints the top groups, and exits. Used to check output without clicking the menu bar.
@MainActor
enum SnapshotMode {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let seconds = i + 2 < args.count ? Double(args[i + 2]) ?? 12 : 12
        let metric: Metric = args.contains("--cpu") ? .cpu : .memory
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let monitor = Monitor.shared
            monitor.metric = metric
            if let e = args.firstIndex(of: "--expand"), e + 1 < args.count,
               let g = monitor.sortedGroups.first(where: { $0.meta.name == args[e + 1] }) {
                monitor.expanded.insert(g.id)
                for p in g.processes.sorted(by: { monitor.value($0) > monitor.value($1) }).prefix(12) {
                    print("   ", p.name, Format.bytes(Double(p.memory)), Format.percent(p.cpu), p.path)
                }
            }
            for g in monitor.sortedGroups.prefix(15) {
                print(String(format: "%-34@ %5d procs  %10@  %6.1f%% CPU", g.meta.name as NSString,
                             g.processes.count, Format.bytes(Double(g.memory)) as NSString, g.cpu))
            }
            let appearance = NSAppearance(named: args.contains("--light") ? .aqua : .darkAqua)
            NSApp.appearance = appearance
            let host = NSHostingView(rootView: PopoverView(monitor: monitor))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            window.level = .floating
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let id = window.windowNumber
                _ = runTool("/usr/sbin/screencapture", ["-x", "-o", "-l\(id)", out.path])
                print("wrote \(out.path)")
                exit(0)
            }
        }
    }
}
