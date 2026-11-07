import Foundation

// Plain data types shared across the app: byte formatting, the scanned file tree (`FileNode`), volume capacity,
// and the risk levels used to label clean-up suggestions.

/// Formats byte counts the way Finder does (decimal units, "GB" not "GiB").
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One node of the scanned disk tree. Small files and tiny folders are rolled up into
/// `rolledUpSize` so a whole-disk scan stays light on memory.
///
/// Declared `@unchecked Sendable`: nodes are mutable, so safety relies on each node being filled in by one scan
/// before it is shared.
final class FileNode: Identifiable, @unchecked Sendable {
    /// Identity is the object itself; nodes are never copied.
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    let name: String
    let path: String
    let isDirectory: Bool
    /// Total size in bytes. For a directory this includes all descendants, rolled-up ones included.
    var size: Int64
    /// Last modification time, when the scanner could read it.
    let modified: Date?
    /// Retained children, largest first. Files and folders below the scanner's size thresholds are absent
    /// and counted in `rolledUpSize` instead.
    var children: [FileNode] = []
    /// Bytes belonging to small children that were left out of `children` to save memory.
    var rolledUpSize: Int64 = 0
    /// Number of files inside the items counted in `rolledUpSize`.
    var rolledUpCount: Int = 0
    /// Number of files (not folders) beneath this node, rolled-up ones included.
    var fileCount: Int = 0
    /// Weak so the parent/child pair does not form a retain cycle.
    weak var parent: FileNode?

    init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// Lower-cased file extension, empty if there is none.
    var ext: String { (name as NSString).pathExtension.lowercased() }

    /// Depth-first traversal. Return `false` from `visit` to skip that node's children.
    func walk(_ visit: (FileNode) -> Bool) {
        guard visit(self) else { return }
        for child in children { child.walk(visit) }
    }

    /// Finds the descendant (or self) with the given absolute path, or nil if it is not in the tree.
    func node(at target: String) -> FileNode? {
        if target == path { return self }
        let prefix = path == "/" ? "/" : path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        for child in children {
            if let found = child.node(at: target) { return found }
        }
        return nil
    }

    /// Whole days since the node was last modified, or nil if the date is unknown.
    func ageInDays(now: Date = Date()) -> Int? {
        guard let modified else { return nil }
        return Calendar.current.dateComponents([.day], from: modified, to: now).day
    }
}

/// Capacity figures for the volume that holds the user's home folder.
struct VolumeInfo: Equatable {
    /// Capacity of the volume in bytes.
    var total: Int64
    /// Free space immediately available, excluding anything macOS could reclaim.
    var available: Int64
    /// Free space if macOS purged everything it considers disposable (the "important usage" figure).
    var availableIncludingPurgeable: Int64

    /// Bytes in use, as reported by `total - available`.
    var used: Int64 { max(0, total - available) }
    /// Space macOS says it can reclaim by itself, the difference between the two available figures.
    var purgeable: Int64 { max(0, availableIncludingPurgeable - available) }

    /// Reads the current figures from the volume containing `NSHomeDirectory()`.
    static func current() -> VolumeInfo {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let v = try? url.resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let avail = Int64(v?.volumeAvailableCapacity ?? 0)
        let important = v?.volumeAvailableCapacityForImportantUsage ?? avail
        return VolumeInfo(total: total, available: avail, availableIncludingPurgeable: important)
    }
}

/// How cautious the user should be about a suggestion. Drives the badge text and colour in the UI.
enum Risk: String, Sendable {
    /// Ordered from least to most cautious; the Suggestions screen groups cards by these levels.
    case safe, review, careful

    /// Short badge text for the risk level.
    var label: String {
        switch self {
        case .safe: "Safe to remove"
        case .review: "Review first"
        case .careful: "Be careful"
        }
    }
}
