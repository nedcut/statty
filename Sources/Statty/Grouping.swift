import Foundation

enum GroupKind: Hashable {
    case app        // a .app bundle and everything it spawned
    case system     // macOS itself: daemons, agents, kernel
    case standalone // a command-line program not owned by any app
}

struct GroupMeta: Hashable {
    let key: String
    let name: String
    let kind: GroupKind
    let bundlePath: String?
}

/// Decides which "app" a process belongs to.
///
/// macOS tracks a *responsible* process for every process: the app that launched it, directly or through
/// XPC. All of a browser's content and GPU helpers are responsible to the browser, so we group by that
/// first, then fall back to the process's own location on disk.
final class GroupResolver {
    static let systemKey = "system:macos"
    private static let systemMeta = GroupMeta(key: systemKey, name: "macOS", kind: .system, bundlePath: nil)
    private var appMetas: [String: GroupMeta] = [:]

    func resolve(pid: pid_t, path: String, responsiblePath: String) -> GroupMeta {
        if !responsiblePath.isEmpty, let meta = classify(responsiblePath), meta.kind == .app { return meta }
        if let meta = classify(path) { return meta }
        if pid == 0 || path.isEmpty || Self.isSystemPath(path) { return Self.systemMeta }
        if !responsiblePath.isEmpty {
            if Self.isSystemPath(responsiblePath) { return Self.systemMeta }
            return standalone(responsiblePath)
        }
        return standalone(path)
    }

    private func classify(_ path: String) -> GroupMeta? {
        guard let bundle = Self.outermostApp(path) else { return nil }
        // Apps buried in /System/Library (Dock, Control Center, framework helpers) are part of macOS.
        if bundle.hasPrefix("/System/Library/") && bundle != "/System/Library/CoreServices/Finder.app" {
            return Self.systemMeta
        }
        if let meta = appMetas[bundle] { return meta }
        let name = FileManager.default.displayName(atPath: bundle)
            .replacingOccurrences(of: ".app", with: "")
        let meta = GroupMeta(key: "app:" + bundle, name: name, kind: .app, bundlePath: bundle)
        appMetas[bundle] = meta
        return meta
    }

    private func standalone(_ path: String) -> GroupMeta {
        GroupMeta(key: "proc:" + path, name: (path as NSString).lastPathComponent, kind: .standalone, bundlePath: nil)
    }

    static func outermostApp(_ path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        if path.hasSuffix(".app") { return path }
        return nil
    }

    static func isSystemPath(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") { return false }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/", "/Library/Developer/CommandLineTools/"]
            .contains { path.hasPrefix($0) }
    }
}

/// Plain-English descriptions for macOS processes people commonly wonder about.
enum KnownProcesses {
    static func describe(_ name: String) -> String? {
        if let d = table[name] { return d }
        if name.hasPrefix("com.apple.WebKit.WebContent") { return "A web page or web view being displayed" }
        if name.hasPrefix("com.apple.WebKit.GPU") { return "Draws web content on the graphics card" }
        if name.hasPrefix("com.apple.WebKit.Networking") { return "Loads web content over the network" }
        if name.hasPrefix("mdworker") { return "Spotlight: reads files to index their contents" }
        if name.hasSuffix("Isolated Web Content") || name.hasSuffix("Web Content") { return "A browser tab (or group of tabs)" }
        if name.hasSuffix("GPU Helper") || name.hasSuffix("GPU Process") { return "Draws the app's content on the graphics card" }
        if name.hasSuffix("Helper (Renderer)") { return "Renders one window or web view of the app" }
        if name.hasSuffix("Helper (GPU)") { return "Draws the app's content on the graphics card" }
        if name.hasSuffix("Helper (Plugin)") { return "Runs an app extension or plugin" }
        return nil
    }

    private static let table: [String: String] = [
        "kernel_task": "The macOS kernel. Also absorbs CPU on purpose to cool the Mac when it is hot",
        "WindowServer": "Draws every window and the menu bar on screen",
        "launchd": "Starts and supervises every other process",
        "mds": "Spotlight: manages the search index",
        "mds_stores": "Spotlight: stores and queries the search index",
        "mdworker_shared": "Spotlight: reads files to index their contents",
        "corespotlightd": "Spotlight: indexes content from apps",
        "photoanalysisd": "Photos: analyzes your library for faces, scenes and memories",
        "mediaanalysisd": "Analyzes photos and videos (Live Text, Visual Look Up)",
        "cloudd": "iCloud: syncs data with Apple's servers",
        "bird": "iCloud Drive: syncs files",
        "fileproviderd": "Syncs cloud-storage folders (iCloud Drive, Dropbox, ...)",
        "backupd": "Time Machine backup",
        "coreaudiod": "Handles all audio input and output",
        "bluetoothd": "Bluetooth connections",
        "airportd": "Wi-Fi connections",
        "configd": "Network configuration",
        "mDNSResponder": "Resolves domain names (DNS) and finds devices on the network",
        "softwareupdated": "Checks for and installs macOS updates",
        "syspolicyd": "Gatekeeper: checks that apps are safe to open",
        "XprotectService": "XProtect: Apple's built-in malware scanner",
        "trustd": "Verifies security certificates",
        "securityd": "Keychain and security services",
        "logd": "Writes the system log",
        "opendirectoryd": "User accounts and directory services",
        "distnoted": "Delivers notifications between processes",
        "cfprefsd": "Reads and writes app preferences",
        "Dock": "The Dock, Launchpad and Mission Control",
        "SystemUIServer": "Menu bar items owned by macOS",
        "ControlCenter": "Control Center and its menu bar items",
        "NotificationCenter": "Notifications and widgets",
        "Finder": "The Finder and desktop",
        "loginwindow": "Your login session",
        "powerd": "Power management, sleep and wake",
        "thermalmonitord": "Watches temperatures and throttles to keep the Mac cool",
        "symptomsd": "Monitors network health",
        "nsurlsessiond": "Background downloads for apps",
        "sharingd": "AirDrop, Handoff and sharing",
        "rapportd": "Connects to your other Apple devices",
        "remoted": "Talks to connected Apple devices",
        "UserEventAgent": "Reacts to system events for plugins",
        "hidd": "Keyboard, mouse and trackpad input",
        "coreduetd": "Learns usage patterns to schedule background work",
        "dasd": "Schedules background tasks for good battery life",
        "triald": "Apple's feature-experiment service",
        "spindump": "Records diagnostics when an app hangs",
        "ReportCrash": "Writes crash reports",
        "amfid": "Verifies app code signatures",
        "sandboxd": "Enforces app sandbox rules",
        "tccd": "Privacy permissions (camera, microphone, files)",
        "locationd": "Location services",
        "siriactionsd": "Siri and Shortcuts actions",
        "suggestd": "Siri Suggestions",
        "knowledge-agent": "Siri knowledge and suggestions",
        "biomed": "Collects on-device usage signals for Siri and suggestions",
        "intelligenceplatformd": "Apple Intelligence on-device processing",
        "modelmanagerd": "Apple Intelligence model management",
        "fseventsd": "Tracks file system changes for apps and backups",
        "diskarbitrationd": "Mounts and manages disks",
        "notifyd": "System notification broker",
        "usernoted": "Delivers user notifications",
        "lsd": "LaunchServices: knows which app opens which file",
        "iconservicesagent": "Loads and caches app icons",
        "WindowManager": "Stage Manager and window tiling",
        "corebrightnessd": "Display brightness and Night Shift",
        "PerfPowerServices": "Collects battery and energy usage statistics",
        "replayd": "Screen recording and screen sharing capture",
        "mdbulkimport": "Spotlight: imports files in bulk for indexing",
        "Control Center": "Control Center and its menu bar items",
        "Notification Center": "Notifications and widgets",
        "Spotlight": "Spotlight search window",
        "AirPlayXPCHelper": "AirPlay streaming",
        "audioaccessoryd": "AirPods and audio accessory connections",
        "VTDecoderXPCService": "Hardware video decoding for an app",
        "VTEncoderXPCService": "Hardware video encoding for an app",
    ]
}
