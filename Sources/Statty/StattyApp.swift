import AppKit
import SwiftUI

@main
struct StattyApp: App {
    private let monitor = Monitor.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Monitor.shared.start()
        SnapshotMode.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            Image(systemName: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}
