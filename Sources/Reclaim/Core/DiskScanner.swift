import Foundation
import os

// Walks the file system and builds the `FileNode` tree that the Space Map, Overview and Suggestions are
// all derived from. It only reads: it never modifies, moves or deletes anything.

/// A point-in-time copy of the scanner's progress, polled by the UI while a scan runs.
struct ScanSnapshot: Sendable, Equatable {
    var files: Int = 0
    var bytes: Int64 = 0
    var currentPath: String = ""
}

/// Read-only recursive scanner. Measures *allocated* size (what actually occupies the disk),
/// ignores symlinks, and never writes anything.
///
/// Shared mutable progress lives behind `state`'s lock; the directory walk itself runs on background threads.
final class DiskScanner: @unchecked Sendable {
    /// Tuning knobs and exclusions for a scan.
    struct Options: Sendable {
        /// Files smaller than this (1 MiB) are not kept as nodes; their bytes are rolled into the parent.
        var minFileNodeSize: Int64 = 1 << 20
        /// Folders smaller than this (256 KiB) are likewise rolled into their parent. Keeps memory low on a whole-disk scan.
        var minDirNodeSize: Int64 = 256 << 10
        /// Folders never entered: other mounts, the VM swap area and similar, which are not part of this Mac's own storage.
        var skipPaths: Set<String> = [
            "/Volumes", "/System/Volumes", "/dev", "/private/var/vm", "/cores",
        ]

        /// Whole-disk mode: only the Data volume. The sealed macOS volume (/System, /bin, /sbin, most of /usr)
        /// is read-only, unremovable, and reported separately from APFS.
        ///
        /// The `/.nofollow`, `/.resolve` and `/.vol` entries are special system paths rather than real folders, and
        /// `/home` and `/Network` are automounter points.
        static var wholeDisk: Options {
            var o = Options()
            o.skipPaths.formUnion([
                "/System", "/bin", "/sbin", "/usr/bin", "/usr/lib", "/usr/libexec", "/usr/sbin", "/usr/share",
                "/usr/standalone", "/home", "/Network", "/.vol", "/.nofollow", "/.resolve",
            ])
            return o
        }
    }

    /// Progress and results shared between the scan threads and the UI.
    private struct State {
        var files = 0
        var bytes: Int64 = 0
        var current = ""
        var cancelled = false
        var unreadable: [String] = []
    }

    private let options: Options
    /// Only descend into folders on these devices, so mounted disks, disk images and network shares
    /// are never mistaken for part of this Mac's drive.
    private var allowedDevices: Set<dev_t> = []
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(options: Options = Options()) {
        self.options = options
    }

    /// Thread-safe view of the current progress.
    func snapshot() -> ScanSnapshot {
        state.withLock { ScanSnapshot(files: $0.files, bytes: $0.bytes, currentPath: $0.current) }
    }

    /// Folders that could not be listed, usually because Full Disk Access has not been granted.
    var unreadablePaths: [String] { state.withLock { $0.unreadable } }
    private var isCancelled: Bool { state.withLock { $0.cancelled } }
    var cancelledFlag: Bool { isCancelled }
    /// Asks the scan to stop; already-running directory reads finish but no new ones start.
    func cancel() { state.withLock { $0.cancelled = true } }

    /// The device number (`st_dev`) of a path, using `lstat` so symlinks are not followed.
    private static func device(of path: String) -> dev_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }

    /// Scans `url` and returns the root of the tree.
    func scan(root url: URL) async -> FileNode {
        // Scanning "/" means the user's data: on a modern Mac that lives on the Data volume, which is firmlinked
        // into "/", so its device number is the one to allow.
        let basis = url.path == "/" ? "/System/Volumes/Data" : url.path
        if let dev = Self.device(of: basis) { allowedDevices = [dev] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.scanDirectory(url: url, depth: 0, modified: nil))
            }
        }
    }

    /// Resource keys fetched in one call per entry, which is much faster than separate lookups.
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey,
    ]

    /// Recursively measures one folder. Small items are folded into the parent's `rolledUpSize` and the rest
    /// become `children`, sorted largest first.
    private func scanDirectory(url: URL, depth: Int, modified: Date?) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        let node = FileNode(name: name, path: url.path, isDirectory: true, size: 0, modified: modified)
        if isCancelled { return node }

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Self.keys, options: [])
        } catch {
            state.withLock { $0.unreadable.append(url.path) }
            return node
        }

        let keySet = Set(Self.keys)
        var subdirs: [(URL, Date?)] = []
        var kids: [FileNode] = []
        var total: Int64 = 0
        var fileTotal: Int64 = 0
        var count = 0
        var smallBytes: Int64 = 0
        var smallCount = 0

        for entry in entries {
            guard let v = try? entry.resourceValues(forKeys: keySet) else { continue }
            // Symlinks are skipped so nothing is counted twice and the walk cannot loop.
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                var normalized = entry.path
                while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
                if options.skipPaths.contains(normalized) { continue }
                // Stay on the allowed device so mounted disks, disk images and network shares are not scanned as part of this Mac.
                if let dev = Self.device(of: entry.path), !allowedDevices.isEmpty, !allowedDevices.contains(dev) { continue }
                subdirs.append((entry, v.contentModificationDate))
            } else {
                // Allocated size is what the file really occupies (0 for iCloud placeholders, which is correct).
                // Network shares often can't report it, so fall back to the logical size rather than 0.
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
                total += size
                fileTotal += size
                count += 1
                if size >= options.minFileNodeSize {
                    let f = FileNode(
                        name: entry.lastPathComponent, path: entry.path, isDirectory: false, size: size,
                        modified: v.contentModificationDate)
                    f.fileCount = 1
                    f.parent = node
                    kids.append(f)
                } else {
                    smallBytes += size
                    smallCount += 1
                }
            }
        }

        let localCount = count, localBytes = fileTotal
        state.withLock {
            $0.files += localCount
            $0.bytes += localBytes
            $0.current = url.path
        }

        var results = [FileNode?](repeating: nil, count: subdirs.count)
        // Only the top two levels fan out across threads; below that, work is already spread widely enough and
        // further parallelism would just add overhead.
        if depth < 2 && subdirs.count > 1 {
            results.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let out = buffer
                DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                    out[i] = self.scanDirectory(url: subdirs[i].0, depth: depth + 1, modified: subdirs[i].1)
                }
            }
        } else {
            for (i, sub) in subdirs.enumerated() {
                results[i] = scanDirectory(url: sub.0, depth: depth + 1, modified: sub.1)
            }
        }

        for case let sub? in results {
            total += sub.size
            count += sub.fileCount
            if sub.size >= options.minDirNodeSize {
                sub.parent = node
                kids.append(sub)
            } else {
                smallBytes += sub.size
                smallCount += sub.fileCount
            }
        }

        kids.sort { $0.size > $1.size }
        node.children = kids
        node.size = total
        node.fileCount = count
        node.rolledUpSize = smallBytes
        node.rolledUpCount = smallCount
        return node
    }
}
