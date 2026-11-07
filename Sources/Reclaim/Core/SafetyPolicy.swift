import Foundation

// The single gatekeeper that decides whether a path may be moved to the Trash. Every trash request
// (ActionLog.trash, the Insight/Space Map selection state, the uninstall flow) asks `SafetyPolicy` first,
// so these rules hold regardless of what the UI or the user's selection says.

/// The outcome of a safety check: either the path may be trashed, or it is refused with a reason
/// that is safe to show to the user.
enum TrashVerdict: Equatable, Sendable {
    /// The path may be moved to the Trash.
    case allowed
    /// The path is protected; the associated value explains why, in user-facing wording.
    case denied(String)

    /// Convenience for call sites that only need a yes/no answer.
    var isAllowed: Bool { self == .allowed }
}

/// Hard guard rails. Even with user approval, Reclaim refuses to touch locations where removal
/// can break the system, an app, a backup, or a library the user manages elsewhere (Photos, Music…).
/// Reclaim only ever moves things to the Trash, never straight-deletes.
///
/// The check is cautious by design. Outside the home folder (and the contents of external drives) the answer is
/// always "denied"; inside them, specific protected locations are refused and `~/Library` is an allow-list of
/// cache, log, developer and device-backup folders only.
struct SafetyPolicy: Sendable {
    // MARK: - Properties and rule tables

    /// The user's home folder with symlinks resolved, so comparisons against resolved paths are reliable.
    let home: String

    /// - Parameter home: The home folder to protect. Injectable so tests can use a temporary directory.
    init(home: String = NSHomeDirectory()) {
        self.home = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
    }

    /// Top-level entries in the home folder that hold credentials or shell/tool configuration.
    private static let sensitiveDotDirs: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".kube", ".config", ".docker", ".zshrc", ".zprofile", ".bash_profile", ".gitconfig",
    ]

    /// Bundles that an app manages as a database. Deleting pieces from inside breaks the app's catalogue.
    private static let managedLibrarySuffixes = [
        ".photoslibrary", ".aplibrary", ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle",
    ]

    /// The only parts of `~/Library` that may be trashed. `minComponents` counts path components from `Library`
    /// (e.g. `Library/Caches/com.example.app` has 3), so the container folder itself cannot be chosen, only
    /// entries inside it. Everything else in `~/Library` is denied.
    private static let libraryAllowed: [(prefix: String, minComponents: Int)] = [
        ("Library/Caches/", 3),
        ("Library/Logs/", 3),
        ("Library/Developer/", 4),
        ("Library/Application Support/MobileSync/Backup/", 5),
    ]

    /// A real bundle has a Contents folder (a cache directory that merely ends in ".app" does not).
    private static func isAppBundle(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/Contents")
    }

    /// Missing paths are treated as folders, the safer assumption.
    private static func isDirectoryOrMissing(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return true }
        return isDir.boolValue
    }

    /// Folders in ~/Library whose matching entries may go when uninstalling an app.
    private static let uninstallFolders = [
        "Library/Caches", "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Logs",
        "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies",
        "Library/Application Scripts", "Library/LaunchAgents", "Library/Preferences", "Library/Preferences/ByHost",
    ]

    // MARK: - Verdicts

    /// Verdict while uninstalling `scope`'s app: the app bundle itself and its own leftovers are allowed,
    /// everything else follows the normal rules.
    ///
    /// - Important: This is deliberately narrower than "anything the app owns": a leftover is only allowed when
    /// `LeftoverMatch` ties it to this app's bundle identifier or name, and only inside `uninstallFolders`.
    func verdict(forPath raw: String, uninstalling scope: UninstallScope) -> TrashVerdict {
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        let appPath = URL(fileURLWithPath: scope.appPath).standardizedFileURL.path
        if path == appPath {
            if path.hasPrefix("/System/") || AppInventory.isRestricted(path) { return .denied("Part of macOS.") }
            if path == Bundle.main.bundlePath { return .denied("That's Reclaim itself.") }
            let inAppsFolder = AppInventory.appFolders.contains { path.hasPrefix($0 + "/") && !path.dropFirst($0.count + 1).contains("/") }
            return inAppsFolder ? .allowed : .denied("Only apps in the Applications folders can be uninstalled here.")
        }
        for rel in Self.uninstallFolders {
            let dir = home + "/" + rel + "/"
            guard path.hasPrefix(dir) else { continue }
            let rel = String(path.dropFirst(dir.count))
            if LeftoverMatch.matchesRelative(rel, bundleID: scope.bundleID, appName: scope.appName, others: scope.otherBundleIDs) { return .allowed }
        }
        return verdict(forPath: raw)
    }

    /// Decides whether `raw` may be moved to the Trash under the normal (non-uninstall) rules.
    ///
    /// Anything outside the user's home folder and the contents of external drives is denied outright. Inside
    /// those areas a list of protected locations is checked (managed libraries, Time Machine data, the Trash,
    /// app bundles, `.git`, credentials, and the top level of the home folder or a drive), and `~/Library` is
    /// an allow-list rather than a deny-list. Nothing here deletes anything: an allowed path is only ever
    /// moved to the Trash, where it can be restored.
    func verdict(forPath raw: String) -> TrashVerdict {
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        // Resolve symlinks on the parent only, so the item keeps its own name: a symlink is judged as the link
        // itself, not as whatever it points at.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = parent.appendingPathComponent(url.lastPathComponent).path
        let components = path.split(separator: "/").map(String.init)

        // Check every component, not just the last, so anything nested inside a protected container is also refused.
        for (index, part) in components.enumerated() {
            let lower = part.lowercased()
            if Self.managedLibrarySuffixes.contains(where: { lower.hasSuffix($0) }) {
                return .denied("Part of a library managed by an Apple app (Photos, Music, iMovie…). Manage it inside that app.")
            }
            if part == "Backups.backupdb" || lower.hasSuffix(".backupbundle") || lower.hasSuffix(".sparsebundle") {
                return .denied("Time Machine backup data. Manage backups in Time Machine settings.")
            }
            if part == ".Trash" || part == ".Trashes" {
                return .denied("Already in the Trash. Empty the Trash in Finder to free this space.")
            }
            if lower.hasSuffix(".app"), Self.isAppBundle("/" + components[0...index].joined(separator: "/")) {
                return .denied("Application bundles are not touched by Reclaim.")
            }
            if part == ".git" {
                return .denied("Git data is not touched by Reclaim.")
            }
        }

        // Locations under the home folder: deny-list with an allow-list for Library.
        if path.hasPrefix(home + "/") {
            let rel = String(path.dropFirst(home.count + 1))
            let parts = rel.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return .denied("Your home folder is protected.") }
            if parts.count == 1, Self.isDirectoryOrMissing(path) {
                return .denied("Top-level folders in your home folder are protected. Open the folder and choose what's inside.")
            }
            if Self.sensitiveDotDirs.contains(parts[0]) {
                return .denied("Credentials and configuration are protected.")
            }
            if parts[0] == "Library" {
                let ok = Self.libraryAllowed.contains { rel.hasPrefix($0.prefix) && parts.count >= $0.minComponents }
                return ok ? .allowed : .denied("This part of Library holds app or system data and is protected.")
            }
            return .allowed
        }

        if path.hasPrefix("/Volumes/") {
            // components: ["Volumes", "<drive>", ...]
            if components.count < 3 { return .denied("Whole external volumes are protected.") }
            if components.count == 3, Self.isDirectoryOrMissing(path) {
                return .denied("Top-level folders on external drives are protected. Open the folder and choose what's inside.")
            }
            return .allowed
        }
        return .denied("Outside your home folder. Reclaim does not modify system locations.")
    }
}
