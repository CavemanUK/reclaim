// Space over time: remembers each whole-disk scan and the drive's free space, and compares them.
//
// Three layers, all plain value types so they are easy to test:
//   • `ScanRecord`      one scan, reduced to the numbers needed to compare it with another.
//   • `ScanComparison`  the difference between two records (what grew, what shrank).
//   • `ScanHistoryStore` the on-disk JSON file that keeps records and free-space points.
// Everything stays on this Mac, in ~/Library/Application Support/Reclaim/trend.json.

import Foundation

// MARK: - Records

/// One whole-disk scan, kept small: drive totals, bytes per category, and the biggest folders.
///
/// Only whole-disk scans are recorded. A scan of a single folder says nothing about how the drive changed,
/// so mixing them in would make the comparisons meaningless.
struct ScanRecord: Codable, Identifiable, Equatable, Sendable {
    /// A large folder seen in the scan. The scanner only reports folders of 100 MB or more.
    struct Folder: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        /// `SpaceCategory.rawValue`. Stored as text so old files keep loading if categories are renamed.
        let category: String
    }

    let id: UUID
    let date: Date
    /// Capacity of the APFS container, in bytes.
    let total: Int64
    /// Free space in the container when the scan finished.
    let free: Int64
    /// Bytes the Data volume says it uses.
    let dataUsed: Int64
    /// Bytes the scan could see as files. `dataUsed - scannedBytes` is the "hidden" gap.
    let scannedBytes: Int64
    let purgeable: Int64
    /// The part of the gap that is neither purgeable nor visible (snapshots, system-only folders).
    let hidden: Int64
    let snapshotCount: Int
    /// Bytes per category, keyed by `SpaceCategory.rawValue`.
    let categories: [String: Int64]
    /// The biggest folders, largest first, capped by `ScanRecord.init(report:maxFolders:)`.
    let folders: [Folder]

    /// Bytes in use across the whole container (everything that isn't free).
    var used: Int64 { max(0, total - free) }
}

extension ScanRecord {
    /// Folders smaller than this are not recorded by the scanner, so a folder missing from a record was
    /// either smaller than this or not a "meaningful" folder in that scan. Used to word comparisons honestly.
    static let folderFloor: Int64 = 100 << 20

    /// Builds a record from a finished whole-disk report.
    /// - Parameter maxFolders: how many of the largest folders to keep. Forty is enough to explain most
    ///   growth while keeping the history file small.
    init(report: SpaceReport, date: Date = Date(), maxFolders: Int = 40) {
        var categories: [String: Int64] = [:]
        var folders: [Folder] = []
        for total in report.categories {
            categories[total.category.rawValue] = total.bytes
            folders += total.contributors.map { Folder(path: $0.path, size: $0.size, category: total.category.rawValue) }
        }
        self.init(
            id: UUID(), date: date, total: report.container.ceiling, free: report.container.free,
            dataUsed: report.dataUsed, scannedBytes: report.scannedBytes, purgeable: report.purgeable,
            hidden: report.unexplainedRemainder, snapshotCount: report.snapshots.count, categories: categories,
            folders: Array(folders.sorted { $0.size > $1.size }.prefix(maxFolders)))
    }
}

/// A lightweight free-space reading, taken between scans so the chart has a timeline even if the user
/// only scans occasionally.
struct DrivePoint: Codable, Equatable, Sendable {
    let date: Date
    let total: Int64
    let free: Int64
}

// MARK: - Comparison

/// How one category's total changed between two scans.
struct CategoryChange: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let before: Int64
    let after: Int64
    var change: Int64 { after - before }
}

/// How one large folder changed between two scans.
///
/// `before` or `after` is nil when the folder was not in that scan's list of large folders, which means it
/// was under `ScanRecord.folderFloor` (new, or shrunk away) rather than literally absent. The change is then
/// an estimate, so the UI marks it.
struct FolderChange: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let category: String
    let before: Int64?
    let after: Int64?
    var change: Int64 { (after ?? 0) - (before ?? 0) }
    var isApproximate: Bool { before == nil || after == nil }
}

/// The difference between an older and a newer scan.
struct ScanComparison: Sendable {
    let older: ScanRecord
    let newer: ScanRecord
    /// Category changes, biggest movement first. Movements under 1 MB are dropped as noise.
    let categories: [CategoryChange]
    /// Large-folder changes, biggest movement first.
    let folders: [FolderChange]

    /// Time between the two scans, in days.
    var days: Double { max(0, newer.date.timeIntervalSince(older.date)) / 86_400 }
    /// Positive means more space is now in use.
    var usedChange: Int64 { newer.used - older.used }
    var freeChange: Int64 { newer.free - older.free }
    var grewFolders: [FolderChange] { folders.filter { $0.change > 0 } }
    var shrankFolders: [FolderChange] { folders.filter { $0.change < 0 } }
    /// The category that grew the most, if any grew.
    var biggestGrowth: CategoryChange? { categories.filter { $0.change > 0 }.max { $0.change < $1.change } }

    init(older: ScanRecord, newer: ScanRecord) {
        self.older = older
        self.newer = newer

        // Categories: union of both scans, so a category that appeared or vanished still shows up.
        let names = Set(older.categories.keys).union(newer.categories.keys)
        categories = names
            .map { CategoryChange(name: $0, before: older.categories[$0] ?? 0, after: newer.categories[$0] ?? 0) }
            .filter { abs($0.change) >= 1 << 20 }
            .sorted { abs($0.change) > abs($1.change) }

        // Folders: matched by path.
        var before: [String: ScanRecord.Folder] = [:]
        for f in older.folders { before[f.path] = f }
        var after: [String: ScanRecord.Folder] = [:]
        for f in newer.folders { after[f.path] = f }
        let paths = Set(before.keys).union(after.keys)
        folders = paths
            .map { path in
                FolderChange(
                    path: path, category: (after[path] ?? before[path])?.category ?? "", before: before[path]?.size,
                    after: after[path]?.size)
            }
            .filter { abs($0.change) >= 1 << 20 }
            .sorted { abs($0.change) > abs($1.change) }
    }
}

/// Which earlier scan to compare the latest one against.
enum TrendBaseline: String, CaseIterable, Identifiable, Sendable {
    case previous = "Previous scan"
    case weekAgo = "About a week ago"
    case first = "First scan"

    var id: String { rawValue }

    /// Picks the baseline from `scans` (oldest first) for `latest`. Returns nil if there is nothing earlier.
    func choose(for latest: ScanRecord, in scans: [ScanRecord]) -> ScanRecord? {
        let earlier = scans.filter { $0.date < latest.date }
        switch self {
        case .previous:
            return earlier.max { $0.date < $1.date }
        case .first:
            return earlier.min { $0.date < $1.date }
        case .weekAgo:
            let target = latest.date.addingTimeInterval(-7 * 86_400)
            return earlier.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
        }
    }
}

/// Bytes Reclaim itself freed between two moments, from the action log.
///
/// Counts items trashed, deleted for good, kept in iCloud only, or deleted from Photos. Items later put back
/// (`.restored`) are not counted, because that space was returned to the Mac.
func freedByReclaim(_ history: [HistoryEntry], from start: Date, to end: Date) -> Int64 {
    history
        .filter { $0.date > start && $0.date <= end }
        .filter { [.trashed, .deleted, .evicted, .photosRecentlyDeleted].contains($0.status) }
        .reduce(0) { $0 + $1.size }
}

// MARK: - Storage

/// Saves scan records and free-space points to a JSON file and keeps them within sensible limits.
///
/// Thread-safe: the app model calls it from the main actor and from background tasks.
final class ScanHistoryStore: @unchecked Sendable {
    /// The most scans kept. Each record is a few kilobytes, so this stays well under a megabyte.
    static let maxScans = 150
    /// Free-space points older than this are thinned to one per day.
    static let fullDetailDays = 45
    static let maxDrivePoints = 3000
    /// A new free-space point is taken at most this often, unless free space moved a lot.
    static let driveInterval: TimeInterval = 6 * 3600
    static let driveJump: Int64 = 512 << 20

    private struct FileContents: Codable {
        var scans: [ScanRecord] = []
        var drive: [DrivePoint] = []
    }

    private let lock = NSLock()
    private var contents = FileContents()
    private let fileURL: URL

    /// Default location is the app's Application Support folder; tests pass a temporary file.
    init(fileURL: URL? = nil) {
        self.fileURL =
            fileURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reclaim", isDirectory: true).appendingPathComponent("trend.json")
        load()
    }

    /// Whole-disk scans, oldest first.
    var scans: [ScanRecord] { lock.withLock { contents.scans.sorted { $0.date < $1.date } } }
    /// Free-space points, oldest first.
    var drive: [DrivePoint] { lock.withLock { contents.drive.sorted { $0.date < $1.date } } }

    /// Adds a scan record. A second scan within a minute of the previous one replaces it, so pressing Scan
    /// twice in a row doesn't clutter the history.
    func record(_ scan: ScanRecord) {
        lock.withLock {
            if let last = contents.scans.max(by: { $0.date < $1.date }), scan.date.timeIntervalSince(last.date) < 60 {
                contents.scans.removeAll { $0.id == last.id }
            }
            contents.scans.append(scan)
            if contents.scans.count > Self.maxScans {
                contents.scans = Array(contents.scans.sorted { $0.date < $1.date }.suffix(Self.maxScans))
            }
        }
        save()
    }

    /// Whether a new free-space point is worth storing, given the last one.
    static func shouldRecordDrive(last: DrivePoint?, free: Int64, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last.date) >= driveInterval || abs(free - last.free) >= driveJump
    }

    /// Records the drive's free space if it is time to (see `shouldRecordDrive`). Returns true if it stored one.
    @discardableResult
    func recordDrive(total: Int64, free: Int64, now: Date = Date()) -> Bool {
        let stored: Bool = lock.withLock {
            let last = contents.drive.max { $0.date < $1.date }
            guard total > 0, Self.shouldRecordDrive(last: last, free: free, now: now) else { return false }
            contents.drive.append(DrivePoint(date: now, total: total, free: free))
            contents.drive = Self.thinned(contents.drive, now: now)
            return true
        }
        if stored { save() }
        return stored
    }

    /// Keeps full detail for recent points and one point per day for older ones, then caps the total.
    static func thinned(_ points: [DrivePoint], now: Date) -> [DrivePoint] {
        let cutoff = now.addingTimeInterval(-Double(fullDetailDays) * 86_400)
        let calendar = Calendar.current
        var lastPerDay: [Date: DrivePoint] = [:]
        var recent: [DrivePoint] = []
        for p in points.sorted(by: { $0.date < $1.date }) {
            if p.date >= cutoff {
                recent.append(p)
            } else {
                lastPerDay[calendar.startOfDay(for: p.date)] = p
            }
        }
        let kept = lastPerDay.values.sorted { $0.date < $1.date } + recent
        return Array(kept.suffix(maxDrivePoints))
    }

    /// Forgets everything. Used by the "Clear history" button.
    func clear() {
        lock.withLock { contents = FileContents() }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        contents = (try? decoder.decode(FileContents.self, from: data)) ?? FileContents()
    }

    private func save() {
        let snapshot = lock.withLock { contents }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            actionLogger.error("could not save trend history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
