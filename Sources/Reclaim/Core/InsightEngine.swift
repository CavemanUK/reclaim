import Foundation

// Turns the scanned `FileNode` tree into the clean-up suggestion cards on the Suggestions and Overview screens.
// Most suggestions come from a fixed table of known locations (`InsightEngine.spots`); a few are found by
// searching the tree (generated folders, old installers, biggest files, iCloud copies). It only reads the tree
// and asks `SafetyPolicy` which items may be trashed; it never touches the file system itself.

/// One file or folder offered within a suggestion.
struct InsightItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
    /// Extra detail shown beside the item, such as how long ago it was last changed.
    let note: String?
    /// True when the user may select this item for "Move to Trash" (passes the safety policy).
    let trashable: Bool
    /// True when the item is in iCloud with a local copy that can be removed without deleting anything.
    var evictable: Bool = false
}

/// The grouping used to colour and filter suggestions.
enum InsightCategory: String, CaseIterable, Sendable {
    case caches = "Caches & logs"
    case developer = "Developer"
    case backups = "Backups"
    case downloads = "Downloads"
    case media = "Large files"
    case apps = "Apps & data"
}

/// One suggestion card: what it is, how risky, which items belong to it and what can be done about it.
struct Insight: Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let category: InsightCategory
    let risk: Risk
    /// The individual files or folders behind the suggestion.
    let items: [InsightItem]
    /// Combined size of `items`, whether or not they can be acted on.
    let totalBytes: Int64
    /// A command the user may choose to run themselves. Reclaim never runs it.
    ///
    /// Reclaim runs it only when it is an allow-listed Homebrew command (see `BrewCommand`) and the user
    /// approves; any other command is shown as text for the user to copy.
    let command: String?
    /// Plain-language advice for things Reclaim can't (or shouldn't) do itself.
    let advice: String?
    /// True when `totalBytes` is the size of a whole folder but the suggested action only removes part of it,
    /// so the number is an upper bound rather than a promise.
    var partial: Bool = false
    enum Action: Sendable { case trash, evict }
    /// What selecting items on this card leads to: the Trash, or "keep in iCloud only".
    var action: Action = .trash

    /// Items the safety policy allows to be moved to the Trash.
    var trashableItems: [InsightItem] { items.filter(\.trashable) }
    /// Items the card's `action` can apply to.
    var actionableItems: [InsightItem] { action == .evict ? items.filter(\.evictable) : trashableItems }
    /// What the user could plausibly get back by acting on this suggestion. "Your biggest files" are the
    /// user's own videos and disk images, so they are listed for review but never promised as savings.
    var potentialBytes: Int64 {
        switch risk {
        case .careful: 0
        case .review: category == .media ? 0 : actionableItems.reduce(0) { $0 + $1.size }
        case .safe: actionableItems.reduce(0) { $0 + $1.size }
        }
    }
}

/// Turns a scanned tree into plain-language suggestions. Pure analysis, no side effects.
struct InsightEngine {
    let home: String
    /// Used to decide, per item, whether it may be offered for trashing.
    let policy: SafetyPolicy

    init(home: String = NSHomeDirectory()) {
        self.home = home
        self.policy = SafetyPolicy(home: home)
    }

    /// How a known location becomes items: `children` offers each large child as a separate item that can be
    /// trashed; `whole` shows the location as one item for information only (it is never offered for trashing).
    private enum Mode { case children, whole }

    /// A known location, with the wording and thresholds for its suggestion card.
    private struct Spot {
        /// Path relative to the home folder, or an absolute path if it starts with "/".
        let rel: String
        let id: String
        let title: String
        let summary: String
        let icon: String
        let category: InsightCategory
        let risk: Risk
        let mode: Mode
        var command: String? = nil
        var advice: String? = nil
        /// In `children` mode, smaller children are ignored.
        var minChild: Int64 = 50 << 20
        /// The location is ignored unless it is at least this large.
        var minTotal: Int64 = 100 << 20
        var partial: Bool = false
    }

    /// The table of known locations. Ordering does not matter; results are sorted by size.
    private var spots: [Spot] {
        [
            Spot(rel: "Library/Caches", id: "caches", title: "App caches",
                 summary: "Temporary data apps keep to run faster. They rebuild it automatically, so the first launch afterwards may be a little slower.",
                 icon: "internaldrive", category: .caches, risk: .review, mode: .children),
            Spot(rel: "Library/Logs", id: "logs", title: "Log files",
                 summary: "Diagnostic logs from apps and the system. Rarely needed unless you are debugging something.",
                 icon: "doc.text", category: .caches, risk: .safe, mode: .children, minChild: 10 << 20, minTotal: 50 << 20),
            Spot(rel: "Library/Developer/Xcode/DerivedData", id: "deriveddata", title: "Xcode build data",
                 summary: "Intermediate build products. Xcode regenerates them on the next build.",
                 icon: "hammer", category: .developer, risk: .safe, mode: .children),
            Spot(rel: "Library/Developer/Xcode/iOS DeviceSupport", id: "devicesupport", title: "Xcode device support files",
                 summary: "Symbols Xcode copied from devices you connected. They download again when you reconnect the device.",
                 icon: "iphone", category: .developer, risk: .safe, mode: .children),
            Spot(rel: "Library/Developer/Xcode/Archives", id: "archives", title: "Xcode archives",
                 summary: "App builds you archived. Keep any you may need for crash symbolication or App Store re-submission.",
                 icon: "archivebox", category: .developer, risk: .review, mode: .children),
            Spot(rel: "Library/Developer/CoreSimulator", id: "simulators", title: "iOS Simulators",
                 summary: "Simulator runtimes and device data. Removing unavailable ones is safe and can free many gigabytes.",
                 icon: "ipad.and.iphone", category: .developer, risk: .review, mode: .whole,
                 command: "xcrun simctl delete unavailable", partial: true),
            Spot(rel: "Library/Application Support/MobileSync/Backup", id: "iosbackups", title: "iPhone and iPad backups",
                 summary: "Local device backups. These can be huge. If you want to keep them, move them to an external drive or rely on iCloud backup instead.",
                 icon: "iphone.gen3", category: .backups, risk: .careful, mode: .children, minChild: 100 << 20),
            Spot(rel: "Library/Containers/com.docker.docker", id: "docker", title: "Docker data",
                 summary: "Docker's disk image grows and rarely shrinks by itself.",
                 icon: "shippingbox", category: .developer, risk: .review, mode: .whole,
                 command: "docker system prune", partial: true),
            Spot(rel: ".Trash", id: "trash", title: "Trash",
                 summary: "Items in the Trash still take up space.",
                 icon: "trash", category: .apps, risk: .review, mode: .whole,
                 advice: "Open the Trash in Finder, check what is there, then choose Empty. Reclaim leaves this to you.",
                 minTotal: 50 << 20),
            Spot(rel: ".npm", id: "npmcache", title: "npm cache",
                 summary: "Downloaded packages kept for offline installs. npm downloads again whatever it needs.",
                 icon: "shippingbox", category: .developer, risk: .safe, mode: .children, minChild: 20 << 20),
            Spot(rel: "Library/Caches/Homebrew", id: "brewcache", title: "Homebrew downloads",
                 summary: "Old installers and bottles Homebrew keeps after installing. Homebrew's own cleanup removes them and any outdated versions of installed packages.",
                 icon: "mug", category: .developer, risk: .safe, mode: .whole,
                 command: "brew cleanup -s", minTotal: 50 << 20),
            Spot(rel: "/opt/homebrew/Cellar", id: "brewautoremove", title: "Homebrew packages nothing needs any more",
                 summary: "Packages that were installed only as dependencies of something you've since removed. Only Homebrew can tell which ones, and how much they take, so run it to find out. The figure shown is everything Homebrew has installed.",
                 icon: "mug", category: .developer, risk: .safe, mode: .whole,
                 command: "brew autoremove", minTotal: 200 << 20, partial: true),
            Spot(rel: ".gradle", id: "gradle", title: "Gradle caches",
                 summary: "Cached dependencies and downloaded Gradle versions for Android and JVM builds. Gradle downloads again whatever a build needs.",
                 icon: "gearshape.2", category: .developer, risk: .safe, mode: .children, minChild: 20 << 20),
            Spot(rel: ".cargo/registry", id: "cargo", title: "Rust package cache",
                 summary: "Downloaded crates and their sources. Cargo downloads again whatever a build needs.",
                 icon: "gearshape.2", category: .developer, risk: .safe, mode: .children, minChild: 20 << 20),
            Spot(rel: ".ollama/models", id: "ollama", title: "Local AI models (Ollama)",
                 summary: "Models you downloaded for local AI. Each one can be several gigabytes.",
                 icon: "sparkles", category: .apps, risk: .review, mode: .whole,
                 command: "ollama list   # then: ollama rm <model-name>", minTotal: 500 << 20, partial: true),
            Spot(rel: "Library/Messages", id: "messages", title: "Messages attachments",
                 summary: "Photos, videos and files received in Messages.",
                 icon: "message", category: .apps, risk: .careful, mode: .whole,
                 advice: "Open Messages, choose a conversation, then Details > Photos / Files to delete attachments there. Reclaim does not touch this data.",
                 minTotal: 500 << 20),
            Spot(rel: "Library/Caches/CloudKit", id: "icloudcache", title: "iCloud sync cache",
                 summary: "Copies of files iCloud Drive and other iCloud apps downloaded and kept handy. macOS downloads anything you open again, so this is safe to clear. It can grow to many gigabytes and is counted as “System Data” by macOS.",
                 icon: "icloud", category: .caches, risk: .review, mode: .children, minChild: 100 << 20, minTotal: 300 << 20),
            Spot(rel: "Library/Metadata/CoreSpotlight", id: "spotlightindex", title: "Spotlight & Apple Intelligence index",
                 summary: "The index that makes search and Siri suggestions work. macOS rebuilds it if removed, which takes a while and uses the Mac heavily meanwhile.",
                 icon: "magnifyingglass.circle", category: .apps, risk: .careful, mode: .whole,
                 command: "sudo mdutil -E /   # erase and rebuild the index", minTotal: 1 << 30),
            Spot(rel: "Library/Android", id: "androidsdk", title: "Android SDK and NDK",
                 summary: "Android build tools installed by Android Studio. Only needed if you build Android apps.",
                 icon: "hammer", category: .developer, risk: .review, mode: .whole,
                 advice: "Remove unneeded parts in Android Studio › SDK Manager, or if you no longer build for Android, move ~/Library/Android to the Trash in Finder.",
                 minTotal: 500 << 20),
            Spot(rel: "Library/Application Support/com.apple.wallpaper/aerials", id: "aerials", title: "Downloaded aerial wallpapers",
                 summary: "Video wallpapers and screen savers macOS downloaded. Each one is hundreds of megabytes.",
                 icon: "photo.tv", category: .apps, risk: .review, mode: .whole,
                 advice: "System Settings › Wallpaper: hover a downloaded aerial and click Delete.", minTotal: 300 << 20),
            Spot(rel: "Library/Application Support/Google/Chrome", id: "chromedata", title: "Chrome browsing data",
                 summary: "Chrome's profile: history, cache, extensions, site data.",
                 icon: "globe", category: .apps, risk: .careful, mode: .whole,
                 advice: "In Chrome: Settings › Privacy and security › Delete browsing data (cached images and files is the safe choice).",
                 minTotal: 500 << 20),
            Spot(rel: "Library/Containers/com.apple.Safari", id: "safaridata", title: "Safari website data",
                 summary: "Websites' stored data and caches. Clearing it logs you out of sites.",
                 icon: "safari", category: .apps, risk: .careful, mode: .whole,
                 advice: "Safari › Settings › Privacy › Manage Website Data › Remove All.", minTotal: 500 << 20),
            Spot(rel: "/private/var/folders", id: "varfolders", title: "Temporary files of running apps",
                 summary: "Scratch space apps use while running (Chrome keeps copies of itself here during updates). macOS clears it on restart.",
                 icon: "clock.arrow.circlepath", category: .caches, risk: .review, mode: .whole,
                 advice: "Restart your Mac. Anything still here afterwards is in use.", minTotal: 1 << 30),
            Spot(rel: "/private/var/db/diagnostics", id: "syslogs", title: "System logs",
                 summary: "macOS's own activity logs. It trims them on a schedule; they're only useful when troubleshooting.",
                 icon: "doc.text.magnifyingglass", category: .caches, risk: .careful, mode: .whole,
                 command: "sudo log erase --all   # removes all stored system logs", minTotal: 1 << 30),
            Spot(rel: "Library/Mail", id: "mail", title: "Mail downloads",
                 summary: "Mail messages and attachments stored on this Mac.",
                 icon: "envelope", category: .apps, risk: .careful, mode: .whole,
                 advice: "In Mail, use Mailbox > Erase Junk Mail / Deleted Items, or Settings > Accounts > Download Attachments > None.",
                 minTotal: 500 << 20),
        ]
    }

    /// Builds all suggestions for a scan, largest first.
    func generate(from root: FileNode, now: Date = Date()) -> [Insight] {
        var out: [Insight] = []

        for spot in spots {
            let spotPath = spot.rel.hasPrefix("/") ? spot.rel : home + "/" + spot.rel
            guard let node = root.node(at: spotPath), node.size >= spot.minTotal else { continue }
            var items: [InsightItem]
            switch spot.mode {
            case .children:
                items = node.children
                    .filter { $0.size >= spot.minChild }
                    .map { makeItem($0, canTrash: true, now: now) }
            case .whole:
                items = [makeItem(node, canTrash: false, now: now)]
            }
            guard !items.isEmpty else { continue }
            out.append(Insight(
                id: spot.id, title: spot.title, summary: spot.summary, icon: spot.icon, category: spot.category,
                risk: spot.risk, items: items, totalBytes: items.reduce(0) { $0 + $1.size },
                command: spot.command, advice: spot.advice, partial: spot.partial))
        }

        if let i = cloudLocalCopies(root, now: now) { out.append(i) }
        if let i = generatedFolders(root, now: now) { out.append(i) }
        if let i = oldInstallers(root, now: now) { out.append(i) }
        if let i = largestFiles(root, now: now) { out.append(i) }
        if let i = photosLibraries(root) { out.append(i) }

        return out.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// `canTrash` is false for locations that are listed for information only; otherwise the safety policy decides.
    private func makeItem(_ node: FileNode, canTrash: Bool, now: Date) -> InsightItem {
        var note: String?
        if let days = node.ageInDays(now: now), days > 30 { note = "Last changed \(days) days ago" }
        return InsightItem(
            path: node.path, name: node.name, size: node.size, note: note,
            trashable: canTrash && policy.verdict(forPath: node.path).isAllowed)
    }

    /// Large items that live in iCloud and also take space here. Their local copy can go; iCloud keeps the file.
    private func cloudLocalCopies(_ root: FileNode, now: Date) -> Insight? {
        var candidates: [FileNode] = []
        if let drive = root.node(at: home + "/Library/Mobile Documents/com~apple~CloudDocs") {
            candidates += drive.children.filter { $0.size >= 50 << 20 }
        }
        for folder in ["Desktop", "Documents"] {
            guard let node = root.node(at: home + "/" + folder) else { continue }
            candidates += node.children.filter { $0.size >= 100 << 20 }
        }
        // Capped so checking each candidate's iCloud status stays quick.
        let items = candidates.prefix(60).compactMap { node -> InsightItem? in
            guard CloudEvict.status(of: node.path).canEvict else { return nil }
            var note = "In iCloud; local copy can go"
            if let days = node.ageInDays(now: now), days > 30 { note += " · last changed \(days) days ago" }
            return InsightItem(path: node.path, name: node.name, size: node.size, note: note, trashable: false, evictable: true)
        }
        .sorted { $0.size > $1.size }
        guard !items.isEmpty, items.reduce(0, { $0 + $1.size }) >= 100 << 20 else { return nil }
        return Insight(
            id: "icloudlocal", title: "Keep in iCloud only",
            summary: "These files are safely in iCloud and also take space on this Mac. Reclaim can remove the local copy without deleting anything: the file stays in iCloud and downloads again the moment you open it (needs internet).",
            icon: "icloud.and.arrow.up", category: .downloads, risk: .safe, items: items,
            totalBytes: items.reduce(0) { $0 + $1.size }, command: nil,
            advice: "Best for things you rarely open. To do this for everything automatically, turn on Optimise Mac Storage in System Settings › Apple Account › iCloud › iCloud Drive.",
            action: .evict)
    }

    /// Large rebuildable folders (`node_modules`, virtual environments and so on) found anywhere in the tree.
    /// Folders directly in the home folder are excluded, and the walk does not descend into a match.
    private func generatedFolders(_ root: FileNode, now: Date) -> Insight? {
        let names: Set<String> = [
            "node_modules", ".venv", "venv", ".build", "Pods", ".next", ".nuxt", ".gradle", ".tox", "__pycache__",
        ]
        var found: [FileNode] = []
        root.walk { node in
            guard node.isDirectory else { return true }
            if names.contains(node.name), node.size >= 50 << 20, node.parent?.path != home {
                found.append(node)
                return false
            }
            return true
        }
        let items = found.sorted { $0.size > $1.size }.prefix(40).map { node -> InsightItem in
            var note = "Rebuilt by your package manager"
            if let days = node.parent?.ageInDays(now: now), days > 60 {
                note = "Project untouched for \(days) days"
            }
            return InsightItem(
                path: node.path, name: node.parent.map { "\($0.name)/\(node.name)" } ?? node.name,
                size: node.size, note: note, trashable: policy.verdict(forPath: node.path).isAllowed)
        }
        guard !items.isEmpty else { return nil }
        return Insight(
            id: "generated", title: "Project dependencies you can reinstall",
            summary: "Folders like node_modules and virtual environments are recreated by npm, pip or your build tool. Old projects are the best candidates.",
            icon: "folder.badge.gearshape", category: .developer, risk: .safe, items: Array(items),
            totalBytes: items.reduce(0) { $0 + $1.size }, command: nil,
            advice: "After removing one, run npm install, pip install -r requirements.txt, or your build command when you next need that project.")
    }

    /// Installer and archive files in Downloads that are at least 30 days old.
    private func oldInstallers(_ root: FileNode, now: Date) -> Insight? {
        guard let downloads = root.node(at: home + "/Downloads") else { return nil }
        let exts: Set<String> = ["dmg", "pkg", "iso", "zip", "xip", "tar", "gz", "7z", "rar"]
        let items = downloads.children
            .filter { !$0.isDirectory && exts.contains($0.ext) && ($0.ageInDays(now: now) ?? 0) >= 30 }
            .map { makeItem($0, canTrash: true, now: now) }
        guard !items.isEmpty, items.reduce(0, { $0 + $1.size }) >= 100 << 20 else { return nil }
        return Insight(
            id: "installers", title: "Old installers and archives in Downloads",
            summary: "Disk images, installers and zip files you downloaded over a month ago. Usually the app is already installed.",
            icon: "arrow.down.circle", category: .downloads, risk: .review, items: items,
            totalBytes: items.reduce(0) { $0 + $1.size }, command: nil, advice: nil)
    }

    /// The 20 largest individual files over 500 MB, excluding locations that other cards already cover.
    /// These are listed so the user can see them, but `Insight.potentialBytes` never counts them as savings.
    private func largestFiles(_ root: FileNode, now: Date) -> Insight? {
        let skip = [".ollama/models", "com.docker.docker", ".photoslibrary", "CoreSimulator", "Mobile Documents", "/Library/Mail"]
        var found: [FileNode] = []
        root.walk { node in
            if !node.isDirectory {
                if node.size >= 500 << 20, !skip.contains(where: { node.path.contains($0) }) { found.append(node) }
                return false
            }
            return true
        }
        let items = found.sorted { $0.size > $1.size }.prefix(20).map { makeItem($0, canTrash: true, now: now) }
        guard !items.isEmpty else { return nil }
        return Insight(
            id: "largest", title: "Your biggest files",
            summary: "Single files over 500 MB. Videos, disk images and VM files are common. Consider moving the ones you rarely open to an external drive or cloud storage.",
            icon: "film", category: .media, risk: .review, items: items,
            totalBytes: items.reduce(0) { $0 + $1.size }, command: nil, advice: nil)
    }

    /// Large Photos libraries, shown for information only: they are managed by the Photos app.
    private func photosLibraries(_ root: FileNode) -> Insight? {
        var libs: [FileNode] = []
        root.walk { node in
            if node.isDirectory, node.name.hasSuffix(".photoslibrary") { libs.append(node); return false }
            return true
        }
        let items = libs.filter { $0.size >= 1 << 30 }.map {
            InsightItem(path: $0.path, name: $0.name, size: $0.size, note: nil, trashable: false)
        }
        guard !items.isEmpty else { return nil }
        return Insight(
            id: "photoslib", title: "Photos library",
            summary: "Your Photos library is large. It is managed by the Photos app, so Reclaim never modifies it.",
            icon: "photo.on.rectangle", category: .media, risk: .careful, items: items,
            totalBytes: items.reduce(0) { $0 + $1.size }, command: nil,
            advice: "If you use iCloud Photos, open Photos > Settings > iCloud and choose Optimise Mac Storage. Delete unwanted photos inside Photos, then empty Recently Deleted.")
    }
}
