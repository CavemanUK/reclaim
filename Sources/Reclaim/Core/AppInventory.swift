import AppKit
import CoreServices
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    let size: Int64
    let lastUsed: Date?
    let installed: Date?
    let fromAppStore: Bool
    let isApple: Bool
    /// Homebrew cask token when the app was installed by Homebrew.
    let caskToken: String?

    var displayVendor: String {
        guard let id = bundleID?.split(separator: ".") , id.count >= 2 else { return "" }
        return id[1].capitalized
    }
}

enum LeftoverKind: String, CaseIterable, Sendable {
    case cache = "Caches"
    case preferences = "Preferences"
    case savedState = "Saved window state"
    case logs = "Logs"
    case supportData = "App data"
    case container = "Sandbox container"
    case groupContainer = "Shared container"
    case webData = "Web data & cookies"
    case launchAgent = "Background agent"
    case system = "System-level files"

    var explanation: String {
        switch self {
        case .cache: "Temporary files the app can rebuild."
        case .preferences: "The app's settings."
        case .savedState: "Which windows were open last time."
        case .logs: "Diagnostic logs."
        case .supportData: "Everything the app saved for itself. For some apps this includes your documents or history, so check the size."
        case .container: "A sandboxed app's private home: settings, caches and often its data."
        case .groupContainer: "Data shared between an app and its helpers or extensions."
        case .webData: "Website storage and cookies the app kept."
        case .launchAgent: "Starts something in the background at login. Removing it stops that."
        case .system: "Installed for all users. Needs an administrator, so Reclaim lists it but can't remove it."
        }
    }

    var icon: String {
        switch self {
        case .cache: "memorychip"
        case .preferences: "slider.horizontal.3"
        case .savedState: "macwindow"
        case .logs: "doc.text"
        case .supportData: "square.stack.3d.up"
        case .container: "shippingbox"
        case .groupContainer: "shippingbox.and.arrow.backward"
        case .webData: "globe"
        case .launchAgent: "bolt.badge.clock"
        case .system: "lock.shield"
        }
    }
}

struct Leftover: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let kind: LeftoverKind
    let size: Int64
    let needsAdmin: Bool
    /// macOS wouldn't let Reclaim look inside (Full Disk Access is off), so the size is a guess of zero.
    var sizeUnknown: Bool = false

    var name: String { (path as NSString).lastPathComponent }
    /// Large app data probably includes things the user made; worth a second look before removing.
    var mayHoldUserData: Bool { (kind == .supportData || kind == .container) && size > 200 << 20 }
}

/// Describes one app being uninstalled, so the safety policy can allow exactly its files and nothing else.
struct UninstallScope: Sendable {
    let appPath: String
    let bundleID: String?
    let appName: String
    /// Bundle identifiers of every other installed app, so a sibling product (Chrome Canary next to Chrome)
    /// is never mistaken for a helper of the one being removed.
    var otherBundleIDs: Set<String> = []
}

/// Shared matching rules: which folder/file names belong to a given app.
enum LeftoverMatch {
    /// App names too generic to match on name alone (they would catch Apple's own data).
    static let genericNames: Set<String> = [
        "music", "photos", "mail", "notes", "safari", "messages", "calendar", "contacts", "reminders", "maps", "news",
        "stocks", "weather", "books", "podcasts", "tv", "home", "shortcuts", "preview", "automator", "dictionary", "chess",
        "stickies", "fonts", "keychain", "finder", "terminal", "console", "system", "library", "apple", "app", "default",
    ]

    /// True when `name` is, or belongs to, another installed app whose identifier extends this one's
    /// (com.google.Chrome.canary is a separate product, not a helper of com.google.Chrome).
    static func belongsToSibling(_ name: String, bundleID: String?, others: Set<String>) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        let lower = name.lowercased()
        for other in others {
            let o = other.lowercased()
            guard o != id, o.hasPrefix(id + ".") || o.hasPrefix(id + "-") else { continue }
            if lower == o || lower.hasPrefix(o + ".") || lower.hasPrefix(o + "-") || lower.hasSuffix("." + o) || lower == "group." + o {
                return true
            }
        }
        return false
    }

    static func matches(name rawName: String, bundleID: String?, appName: String, others: Set<String> = []) -> Bool {
        let name = rawName.lowercased()
        if belongsToSibling(name, bundleID: bundleID, others: others) { return false }
        if let id = bundleID?.lowercased(), !id.isEmpty {
            if name == id || name.hasPrefix(id + ".") || name == "group." + id || name.hasSuffix("." + id) { return true }
            if name.hasPrefix(id + "-") { return true }   // e.g. com.vendor.app-helper
        }
        let app = appName.lowercased().trimmingCharacters(in: .whitespaces)
        guard app.count >= 4, !genericNames.contains(app) else { return false }
        let compact = app.replacingOccurrences(of: " ", with: "")
        return name == app || name == compact
    }

    /// The vendor folder some companies nest their apps' data under (Google/Chrome, Microsoft/Teams…):
    /// the second part of the bundle identifier, e.g. "google" for com.google.Chrome.
    static func vendorFolder(bundleID: String?) -> String? {
        guard let parts = bundleID?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
        let vendor = String(parts[1])
        return vendor.count >= 3 ? vendor : nil
    }

    /// Inside a vendor folder, which names belong to the app: "Chrome" for "Google Chrome", or the bundle's last part.
    static func matchesInsideVendor(name rawName: String, bundleID: String?, appName: String) -> Bool {
        guard let vendor = vendorFolder(bundleID: bundleID) else { return false }
        let name = rawName.lowercased()
        var app = appName.lowercased()
        if app.hasPrefix(vendor + " ") { app = String(app.dropFirst(vendor.count + 1)) }
        let last = bundleID?.lowercased().split(separator: ".").last.map(String.init) ?? ""
        guard app.count >= 3, !genericNames.contains(app) else { return name == last && last.count >= 3 }
        return name == app || name == app.replacingOccurrences(of: " ", with: "") || (name == last && last.count >= 3)
    }

    /// Matches a one- or two-level relative path inside a Library spot ("com.x.y" or "Google/Chrome").
    static func matchesRelative(_ rel: String, bundleID: String?, appName: String, others: Set<String> = []) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        func stem(_ n: String) -> String {
            let base = n.hasSuffix(".plist") ? String(n.dropLast(6)) : n
            return base.hasSuffix(".savedState") ? String(base.dropLast(11)) : base
        }
        switch parts.count {
        case 1:
            return matches(name: stem(parts[0]), bundleID: bundleID, appName: appName, others: others)
                || matches(name: parts[0], bundleID: bundleID, appName: appName, others: others)
        case 2:
            guard let vendor = vendorFolder(bundleID: bundleID), parts[0].lowercased() == vendor else { return false }
            return matchesInsideVendor(name: stem(parts[1]), bundleID: bundleID, appName: appName)
        default:
            return false
        }
    }
}

enum AppInventory {
    static let appFolders = ["/Applications", NSHomeDirectory() + "/Applications"]

    /// Apps the user could uninstall. Blocking; call off the main thread.
    static func installedApps(cancel: CancelFlag) -> [InstalledApp] {
        let fm = FileManager.default
        let casks = homebrewCasks()
        var apps: [InstalledApp] = []
        for folder in appFolders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                if cancel.isCancelled { return apps }
                let path = folder + "/" + name
                guard let bundle = Bundle(path: path) else { continue }
                if path == Bundle.main.bundlePath { continue }
                // System-protected bundles (Safari and friends) can't be removed by anyone; listing them would only
                // invite trashing their data. Leave them out entirely.
                if isRestricted(path) { continue }
                let info = bundle.infoDictionary ?? [:]
                let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? String(name.dropLast(4))
                let bundleID = bundle.bundleIdentifier
                let size = allocatedSize(of: path, cancel: cancel)
                let meta = spotlight(path)
                let attrs = try? fm.attributesOfItem(atPath: path)
                apps.append(InstalledApp(
                    path: path, name: display, bundleID: bundleID,
                    version: info["CFBundleShortVersionString"] as? String, size: size,
                    lastUsed: meta.lastUsed, installed: attrs?[.creationDate] as? Date,
                    fromAppStore: fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
                    isApple: bundleID?.hasPrefix("com.apple.") ?? false,
                    caskToken: casks[name.lowercased()]))
            }
        }
        return apps.sorted { $0.size > $1.size }
    }

    /// SIP's "restricted" flag: set on bundles macOS owns, which no user or admin can delete.
    static func isRestricted(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & 0x0008_0000) != 0   // SF_RESTRICTED
    }

    private static func spotlight(_ path: String) -> (lastUsed: Date?, Void) {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return (nil, ()) }
        let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        return (used, ())
    }

    /// Total allocated bytes under a path (follows no symlinks).
    static func allocatedSize(of path: String, cancel: CancelFlag? = nil) -> Int64 {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
        }
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let u as URL in en {
            n += 1
            if n % 2000 == 0, cancel?.isCancelled == true { return total }
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }

    /// App file name (lowercased) → cask token, for apps Homebrew installed.
    static func homebrewCasks() -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        for root in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            guard let tokens = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for token in tokens where !token.hasPrefix(".") {
                guard let versions = try? fm.contentsOfDirectory(atPath: root + "/" + token) else { continue }
                for v in versions where !v.hasPrefix(".") {
                    guard let files = try? fm.contentsOfDirectory(atPath: root + "/" + token + "/" + v) else { continue }
                    for f in files where f.hasSuffix(".app") { out[f.lowercased()] = token }
                }
            }
        }
        return out
    }

    static func isRunning(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { running in
            if let id = app.bundleID, running.bundleIdentifier == id { return true }
            return running.bundleURL?.path == app.path
        }
    }
}

/// Finds files an app left around the user's Library, plus system-level ones Reclaim can only point at.
enum AppLeftoverFinder {
    private static let userSpots: [(rel: String, kind: LeftoverKind)] = [
        ("Library/Caches", .cache),
        ("Library/Application Support", .supportData),
        ("Library/Containers", .container),
        ("Library/Group Containers", .groupContainer),
        ("Library/Logs", .logs),
        ("Library/Saved Application State", .savedState),
        ("Library/HTTPStorages", .webData),
        ("Library/WebKit", .webData),
        ("Library/Cookies", .webData),
        ("Library/Application Scripts", .supportData),
        ("Library/LaunchAgents", .launchAgent),
        ("Library/Preferences", .preferences),
        ("Library/Preferences/ByHost", .preferences),
    ]

    private static let systemSpots: [String] = [
        "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Preferences", "/Library/Caches", "/Library/Logs",
    ]

    static func find(for app: InstalledApp, others: Set<String> = [], home: String = NSHomeDirectory(), cancel: CancelFlag? = nil) -> [Leftover] {
        var out: [Leftover] = []
        let fm = FileManager.default
        let vendor = LeftoverMatch.vendorFolder(bundleID: app.bundleID)
        func leftover(_ path: String, kind: LeftoverKind, admin: Bool) -> Leftover {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            let unreadable = isDir.boolValue && (try? fm.contentsOfDirectory(atPath: path)) == nil
            return Leftover(
                path: path, kind: kind, size: unreadable ? 0 : AppInventory.allocatedSize(of: path, cancel: cancel),
                needsAdmin: admin, sizeUnknown: unreadable)
        }
        func scan(_ dir: String, kind: LeftoverKind, admin: Bool) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                if LeftoverMatch.matchesRelative(name, bundleID: app.bundleID, appName: app.name, others: others) {
                    out.append(leftover(dir + "/" + name, kind: kind, admin: admin))
                } else if let vendor, name.lowercased() == vendor,
                    let inner = try? fm.contentsOfDirectory(atPath: dir + "/" + name)
                {
                    // Vendor folder (Google, Microsoft…): only this app's entry inside it, never the whole folder.
                    for sub in inner where LeftoverMatch.matchesRelative(name + "/" + sub, bundleID: app.bundleID, appName: app.name, others: others) {
                        out.append(leftover(dir + "/" + name + "/" + sub, kind: kind, admin: admin))
                    }
                }
            }
        }
        for spot in userSpots { scan(home + "/" + spot.rel, kind: spot.kind, admin: false) }
        for dir in systemSpots { scan(dir, kind: .system, admin: true) }
        // De-duplicate nested matches (a container inside a matched folder, for instance).
        let sorted = out.sorted { $0.path.count < $1.path.count }
        var kept: [Leftover] = []
        for l in sorted where !kept.contains(where: { l.path.hasPrefix($0.path + "/") }) { kept.append(l) }
        return kept.sorted { $0.size > $1.size }
    }
}

/// Asks Finder to move an item to the Trash. Finder can elevate with the user's admin password when macOS
/// requires it for an app in /Applications. Needs the user's one-time Automation permission.
enum FinderTrash {
    static func trash(_ path: String) -> (trashPath: String?, error: String?) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "Finder"
                set theItem to POSIX file "\(escaped)" as alias
                set trashed to delete theItem
                return POSIX path of (trashed as alias)
            end tell
            """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (nil, "Couldn't prepare the Finder request.") }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Finder refused."
            return (nil, message)
        }
        return (result.stringValue, nil)
    }
}
