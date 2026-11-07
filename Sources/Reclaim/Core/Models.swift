import Foundation

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One node of the scanned disk tree. Small files and tiny folders are rolled up into
/// `rolledUpSize` so a whole-disk scan stays light on memory.
final class FileNode: Identifiable, @unchecked Sendable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    let name: String
    let path: String
    let isDirectory: Bool
    var size: Int64
    let modified: Date?
    var children: [FileNode] = []
    var rolledUpSize: Int64 = 0
    var rolledUpCount: Int = 0
    var fileCount: Int = 0
    weak var parent: FileNode?

    init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    var ext: String { (name as NSString).pathExtension.lowercased() }

    func walk(_ visit: (FileNode) -> Bool) {
        guard visit(self) else { return }
        for child in children { child.walk(visit) }
    }

    func node(at target: String) -> FileNode? {
        if target == path { return self }
        let prefix = path == "/" ? "/" : path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        for child in children {
            if let found = child.node(at: target) { return found }
        }
        return nil
    }

    func ageInDays(now: Date = Date()) -> Int? {
        guard let modified else { return nil }
        return Calendar.current.dateComponents([.day], from: modified, to: now).day
    }
}

struct VolumeInfo: Equatable {
    var total: Int64
    var available: Int64
    var availableIncludingPurgeable: Int64

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableIncludingPurgeable - available) }

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

enum Risk: String, Sendable {
    case safe, review, careful

    var label: String {
        switch self {
        case .safe: "Safe to remove"
        case .review: "Review first"
        case .careful: "Be careful"
        }
    }
}
