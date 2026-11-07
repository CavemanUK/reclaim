import Foundation

// Describes where the disk space has gone. `SpaceClassifier` assigns every scanned byte to one `SpaceCategory`,
// and `SpaceReport` combines that with APFS and snapshot figures so the Overview can also account for space the
// file scan cannot see.

/// A plain-language bucket for disk usage, such as "Caches & logs" or "Developer tools".
enum SpaceCategory: String, CaseIterable, Identifiable, Sendable {
    case apps = "Applications"
    case yourFiles = "Your files"
    case photos = "Photos libraries"
    case mailMessages = "Mail & Messages"
    case appData = "App data"
    case caches = "Caches & logs"
    case developer = "Developer tools"
    case ai = "Local AI models"
    case backups = "Device backups"
    case tools = "Homebrew & unix tools"
    case systemSupport = "System support files"
    case otherUsers = "Other user accounts"
    case trash = "Trash"
    case other = "Other folders in your home"

    var id: String { rawValue }

    /// SF Symbol name for the category.
    var icon: String {
        switch self {
        case .apps: "app.dashed"
        case .yourFiles: "folder"
        case .photos: "photo.on.rectangle"
        case .mailMessages: "envelope"
        case .appData: "square.stack.3d.up"
        case .caches: "memorychip"
        case .developer: "hammer"
        case .ai: "sparkles"
        case .backups: "iphone.gen3"
        case .tools: "terminal"
        case .systemSupport: "gearshape"
        case .otherUsers: "person.2"
        case .trash: "trash"
        case .other: "house"
        }
    }

    /// What this is, in plain language.
    var explanation: String {
        switch self {
        case .apps: "Apps installed in /Applications (and ~/Applications)."
        case .yourFiles: "Desktop, Documents, Downloads, Movies, Music and Pictures. Your own stuff."
        case .photos: "Photos libraries. Their size is managed inside the Photos app."
        case .mailMessages: "Mail messages and attachments, and Messages attachments, kept on this Mac."
        case .appData: "Settings and data your apps keep in ~/Library (Application Support, Containers, and so on). Part of this is usually app caches that never get cleaned."
        case .caches: "Temporary files apps and macOS rebuild when needed. This includes ~/Library/Caches, logs, and the per-user temp area in /private/var/folders."
        case .developer: "Xcode, simulators, Docker, and package caches such as npm, Cargo and Gradle, plus node_modules folders."
        case .ai: "Models downloaded by Ollama for running AI locally."
        case .backups: "Local iPhone and iPad backups made through Finder."
        case .tools: "Homebrew and other command-line software in /opt and /usr/local."
        case .systemSupport: "Shared libraries and system data outside macOS itself: /Library, /private (databases, logs, caches, swap helpers) and so on."
        case .otherUsers: "Home folders of other accounts on this Mac."
        case .trash: "Items in your Trash. They still use space until you empty it."
        case .other: "Hidden folders and loose files in your home folder, such as .npm, .cache or .ollama if not listed separately."
        }
    }

    /// Advice on how the user can free space in this category.
    var howToReduce: String {
        switch self {
        case .apps: "Delete apps you don't use by dragging them to the Trash from Applications."
        case .yourFiles: "Use Space Map to see your largest files and folders, then move or delete what you don't need."
        case .photos: "Use Photos > Settings > iCloud > Optimise Mac Storage, and delete unwanted photos inside Photos."
        case .mailMessages: "Use Mail's Download Attachments setting, and remove old attachments from Messages > Details > Files."
        case .appData: "Look at the biggest items below. Many apps (browsers, chat apps, editors) have a Clear Cache option in their own settings."
        case .caches: "Mostly safe to clear. Check the Suggestions page, which lists the largest cache folders and lets you move them to the Trash."
        case .developer: "See Suggestions for stale node_modules, Xcode build data and simulators."
        case .ai: "Run `ollama list`, then `ollama rm <model>` for models you don't use."
        case .backups: "Move backups to an external drive, or rely on iCloud backup and delete local ones."
        case .tools: "Run `brew cleanup -s` and `brew autoremove`. Uninstall formulas you no longer use."
        case .systemSupport: "Mostly managed by macOS. Reclaim lists any large items so you can see what they are."
        case .otherUsers: "Delete unused accounts in System Settings > Users & Groups."
        case .trash: "Open the Trash in Finder, check it, and empty it."
        case .other: "Open the biggest items below to see what they are."
        }
    }
}

/// One large folder that makes up part of a category's total.
struct Contributor: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
}

/// A category with its byte total and its largest contributing folders.
struct CategoryTotal: Identifiable, Sendable {
    var id: SpaceCategory { category }
    let category: SpaceCategory
    let bytes: Int64
    let contributors: [Contributor]
}

/// One honest picture of the whole drive: every APFS volume in the container, what the scan found
/// on the Data volume by category, and the part that couldn't be attributed to a file.
struct SpaceReport: Sendable {
    let container: APFSContainerInfo
    let snapshots: [LocalSnapshot]
    let categories: [CategoryTotal]
    /// Total bytes the file scan counted.
    let scannedBytes: Int64
    /// Folders the scan could not open, so their contents are missing from the figures.
    let unreadable: [String]
    /// Space macOS reports it can reclaim by itself.
    let purgeable: Int64
    /// False when only a folder was scanned; the gap figures only make sense for a whole-disk scan.
    let scannedWholeDisk: Bool

    /// Bytes the Data volume reports using.
    var dataUsed: Int64 { container.dataVolume?.inUse ?? 0 }
    /// Space the Data volume says it uses but that the file scan could not find as files.
    var unexplained: Int64 { max(0, dataUsed - scannedBytes) }
    /// Part of the gap macOS will hand back by itself (caches, iCloud downloads it can evict).
    var purgeableInGap: Int64 { min(purgeable, unexplained) }
    /// What is left after purgeable space: local snapshots and anything in folders this app can't read.
    var unexplainedRemainder: Int64 { max(0, unexplained - purgeableInGap) }
    /// Negative gap: scan counted more than the volume reports (cloned files / hard links).
    var overCount: Int64 { max(0, scannedBytes - dataUsed) }
    /// Bytes used by the other volumes in the container (macOS itself, VM, Preboot, Recovery).
    var otherVolumesBytes: Int64 {
        container.volumes.filter { !$0.roles.contains("Data") }.reduce(0) { $0 + $1.inUse }
    }
}

/// Rules for sorting paths into categories.
enum SpaceClassifier {
    /// The category for one path. Rules are checked in order and the first match wins, so the more specific
    /// locations (Photos libraries, Trash, Ollama, device backups) come before the broad ones (`/Library`, home).
    static func category(forPath path: String, home: String) -> SpaceCategory {
        func has(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }

        if path.contains(".photoslibrary") { return .photos }
        if has(home + "/.Trash") { return .trash }
        if has(home + "/.ollama") { return .ai }
        if has(home + "/Library/Application Support/MobileSync") { return .backups }
        if has(home + "/Library/Mail") || has(home + "/Library/Messages") { return .mailMessages }
        if path.contains("/Library/Caches") || path.contains("/Library/Logs") || has("/private/var/folders")
            || has("/private/var/log")
        {
            return .caches
        }
        if has(home + "/Library/Developer") || has(home + "/Library/Containers/com.docker.docker")
            || path.contains("/node_modules") || path.contains("/.npm") || path.contains("/.cargo")
            || path.contains("/.rustup") || path.contains("/.gradle") || path.contains("/.android")
            || has(home + "/.docker") || path.contains("/.pnpm-store")
        {
            return .developer
        }
        if has("/Applications") || has(home + "/Applications") { return .apps }
        if has("/opt") || has("/usr/local") { return .tools }
        for folder in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"] where has(home + "/" + folder) {
            return .yourFiles
        }
        if has(home + "/Library") { return .appData }
        if has("/Users/Shared") { return .yourFiles }
        if has("/Users") && !has(home) { return .otherUsers }
        if has(home) { return .other }
        return .systemSupport
    }

    /// Attributes every byte in the scanned tree to exactly one category.
    ///
    /// Each node contributes only its own bytes (its size minus its children's), so a folder is never counted
    /// together with what is inside it. Folders of at least 100 MB are recorded as "contributors" for display,
    /// unless they merely wrap a single dominant child of the same category; the contributors of a category are
    /// the 12 largest.
    static func breakdown(root: FileNode, home: String) -> [CategoryTotal] {
        var totals: [SpaceCategory: Int64] = [:]
        var found: [SpaceCategory: [Contributor]] = [:]

        func visit(_ node: FileNode) {
            let cat = category(forPath: node.path, home: home)
            let childSum = node.children.reduce(Int64(0)) { $0 + $1.size }
            totals[cat, default: 0] += max(0, node.size - childSum)

            // A "contributor" is a meaningful folder: big, and not just a wrapper around one dominant child.
            let dominant = node.children.first.map { Double($0.size) >= Double(node.size) * 0.6 } ?? false
            let sameCategoryChild = node.children.first.map {
                category(forPath: $0.path, home: home) == cat
            } ?? false
            if node.size >= 100 << 20, !(dominant && sameCategoryChild) {
                let own = node.size
                if node.children.allSatisfy({ category(forPath: $0.path, home: home) == cat }) || node.children.isEmpty {
                    found[cat, default: []].append(Contributor(path: node.path, size: own))
                    for child in node.children { totalsOnly(child) }
                    return
                }
            }
            for child in node.children { visit(child) }
        }

        // Adds sizes for a subtree without recording more contributors.
        func totalsOnly(_ node: FileNode) {
            let cat = category(forPath: node.path, home: home)
            let childSum = node.children.reduce(Int64(0)) { $0 + $1.size }
            totals[cat, default: 0] += max(0, node.size - childSum)
            for child in node.children { totalsOnly(child) }
        }

        visit(root)
        return SpaceCategory.allCases.compactMap { cat in
            guard let bytes = totals[cat], bytes > 0 else { return nil }
            let top = (found[cat] ?? []).sorted { $0.size > $1.size }.prefix(12)
            return CategoryTotal(category: cat, bytes: bytes, contributors: Array(top))
        }.sorted { $0.bytes > $1.bytes }
    }
}
