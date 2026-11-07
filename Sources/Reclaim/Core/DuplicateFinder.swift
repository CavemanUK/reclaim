import CryptoKit
import Foundation

// Finds exact duplicate files (identical bytes) under chosen folders. It narrows candidates cheaply, by size
// and then a partial hash, before paying for a full SHA-256, and never modifies anything. The Duplicates screen
// shows the groups and sends the user's selection to `ActionLog` for trashing.

/// One file that is a candidate duplicate.
struct DupFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date?
    let created: Date?
    var name: String { (path as NSString).lastPathComponent }
}

/// Progress report for the Duplicates screen's progress panel.
///
/// `stage` is 1 (listing files), 2 (grouping by size), 3 (partial hashes) or 4 (full hashes); the other fields
/// are filled in as they become known.
struct DupProgress: Sendable {
    var stage: Int = 1
    var done: Int = 0
    var total: Int = 0
    var filesFound: Int = 0
    var candidates: Int = 0
    var suspects: Int = 0
    var candidateBytes: Int64 = 0
    var currentPath: String = ""
    /// Number of iCloud cloud-only files left out because reading them would download them.
    var skippedCloud: Int = 0
}

/// A set of files with identical content.
struct DupGroup: Identifiable, Sendable {
    let id = UUID()
    let files: [DupFile]
    /// Path of the copy the app recommends keeping (the best `keepScore`); the others are offered for trashing.
    let suggestedKeep: String
    var fileSize: Int64 { files.first?.size ?? 0 }
    /// Space freed by trashing all but one copy.
    var reclaimable: Int64 { fileSize * Int64(files.count - 1) }
}

/// Finds byte-for-byte identical files: size, then a quick partial hash, then a full SHA-256.
/// Read-only. Skips hidden folders, packages (apps, Photos libraries), node_modules and git data.
final class DuplicateFinder: @unchecked Sendable {
    let cancelFlag = CancelFlag()

    /// Folder names whose contents are generated or managed by tools, so duplicates inside them are not offered.
    static let skipDirectoryNames: Set<String> = ["node_modules", ".git", "Pods", ".build", "DerivedData"]

    func cancel() { cancelFlag.cancel() }

    /// Runs the four-stage search and returns groups sorted by how much space they would free.
    ///
    /// Each stage only keeps what could still be a duplicate: files must share a size, then a hash of their
    /// first and last 16 KB, and finally a hash of the whole file. That avoids reading most large files in full.
    /// Returns an empty array if cancelled.
    func find(
        roots: [URL], minSize: Int64, progress: @escaping @Sendable (DupProgress) -> Void
    ) async -> [DupGroup] {
        let flag = cancelFlag
        progress(DupProgress(stage: 1))
        let (files, seen, skipped) = await runBlocking { Self.enumerate(roots: roots, minSize: minSize, cancel: flag, progress: progress) }
        if flag.isCancelled { return [] }
        // Re-wraps `progress` so every later report also carries the number of cloud-only files skipped during enumeration.
        let progress: @Sendable (DupProgress) -> Void = { p in
            var q = p
            q.skippedCloud = skipped
            progress(q)
        }

        // Stage 2: only files that share a size with another file can be identical.
        var bySize: [Int64: [DupFile]] = [:]
        for f in files { bySize[f.size, default: []].append(f) }
        let sameSize = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        let sameSizeBytes = sameSize.reduce(Int64(0)) { $0 + $1.size }
        progress(DupProgress(stage: 2, filesFound: seen, candidates: sameSize.count, candidateBytes: sameSizeBytes))

        // Stage 3: partial hash (first and last 16 KB).
        let partial = await concurrentMap(sameSize, cancel: flag, onProgress: { n in
            if n % 25 == 0 || n == sameSize.count {
                progress(DupProgress(stage: 3, done: n, total: sameSize.count, filesFound: seen,
                                     candidates: sameSize.count, candidateBytes: sameSizeBytes))
            }
        }) { file in Self.partialHash(path: file.path, size: file.size) }
        if flag.isCancelled { return [] }

        var byPartial: [String: [DupFile]] = [:]
        for (file, hash) in zip(sameSize, partial) {
            guard let hash, let hash else { continue }
            byPartial["\(file.size)-\(hash)", default: []].append(file)
        }
        let suspects = byPartial.values.filter { $0.count > 1 }.flatMap { $0 }
        let suspectBytes = suspects.reduce(Int64(0)) { $0 + $1.size }

        // Stage 4: full hash.
        progress(DupProgress(stage: 4, total: suspects.count, filesFound: seen, candidates: sameSize.count,
                             suspects: suspects.count, candidateBytes: suspectBytes))
        let full = await concurrentMap(suspects, cancel: flag, onProgress: { n in
            // Throttled: one main-thread update per few files, not per file.
            if n % 10 == 0 || n == suspects.count {
                progress(DupProgress(stage: 4, done: n, total: suspects.count, filesFound: seen,
                                     candidates: sameSize.count, suspects: suspects.count, candidateBytes: suspectBytes))
            }
        }) { file in Self.fullHash(path: file.path, cancel: flag) }
        if flag.isCancelled { return [] }

        var byFull: [String: [DupFile]] = [:]
        for (file, hash) in zip(suspects, full) {
            guard let hash, let hash else { continue }
            byFull[hash, default: []].append(file)
        }

        let groups = byFull.values.filter { $0.count > 1 }.map { files -> DupGroup in
            let sorted = files.sorted { Self.lexLess(Self.keepScore($0), Self.keepScore($1)) }
            return DupGroup(files: sorted, suggestedKeep: sorted[0].path)
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    // MARK: - Steps

    /// Lists regular files of at least `minSize` bytes under `roots`.
    ///
    /// Cloud-only files are skipped because reading them would make macOS download them. Files that are the same
    /// hard-linked inode are listed once, since deleting one link would not free any space.
    private static func enumerate(
        roots: [URL], minSize: Int64, cancel: CancelFlag, progress: @Sendable (DupProgress) -> Void
    ) -> (files: [DupFile], seen: Int, skipped: Int) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .fileResourceIdentifierKey,
        ]
        let keySet = Set(keys)
        var seenPaths = Set<String>()
        var seenIdentity = Set<NSObject>()
        var result: [DupFile] = []
        var seen = 0
        var skipped = 0

        for root in roots {
            guard
                let en = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants, .skipsHiddenFiles])
            else { continue }
            for case let url as URL in en {
                if cancel.isCancelled { return ([], seen, skipped) }
                guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                if v.isDirectory == true {
                    if skipDirectoryNames.contains(url.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                if Imaging.isCloudOnly(path: url.path) { skipped += 1; continue }
                seen += 1
                if seen % 400 == 0 {
                    progress(DupProgress(stage: 1, filesFound: seen, currentPath: url.deletingLastPathComponent().path))
                }
                guard let size = v.fileSize, Int64(size) >= max(minSize, 1) else { continue }
                guard seenPaths.insert(url.path).inserted else { continue }
                // Hard links are one copy on disk; deleting one frees nothing.
                if let id = v.fileResourceIdentifier as? NSObject, !seenIdentity.insert(id).inserted { continue }
                result.append(DupFile(
                    path: url.path, size: Int64(size), modified: v.contentModificationDate, created: v.creationDate))
            }
        }
        return (result, seen, skipped)
    }

    /// A cheap fingerprint from the first and last 16 KB. Files of 32 KB or less contribute only their first 16 KB,
    /// which is fine because candidates are confirmed with `fullHash` afterwards.
    private static func partialHash(path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 16 * 1024
        do {
            if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
            if size > Int64(chunk * 2) {
                try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
                if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the whole file, read in 1 MiB chunks so memory stays flat. Returns nil if cancelled or unreadable.
    static func fullHash(path: String, cancel: CancelFlag) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                if cancel.isCancelled { return nil }
                hasher.update(data: data)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lexicographic comparison of two score arrays (used to order `keepScore` results).
    static func lexLess(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return lhs.count < rhs.count
    }

    /// Lower is a better copy to keep: avoid Downloads/Trash/"copy" names, prefer the oldest original, shortest path.
    ///
    /// The result is `[penalty, creation date, path length]`, compared in that order by `lexLess`.
    static func keepScore(_ f: DupFile) -> [Double] {
        var penalty = 0.0
        let lower = f.path.lowercased()
        if lower.contains("/downloads/") { penalty += 2 }
        if lower.contains("/.trash/") { penalty += 5 }
        let name = f.name.lowercased()
        if name.contains(" copy") || name.range(of: #"\(\d+\)"#, options: .regularExpression) != nil
            || name.range(of: #" \d\.[a-z0-9]+$"#, options: .regularExpression) != nil
        {
            penalty += 3
        }
        let created = f.created?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
        return [penalty, created, Double(f.path.count)]
    }
}
