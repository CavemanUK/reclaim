import Foundation

// Frees local disk space for iCloud-managed files by evicting the downloaded copy while iCloud keeps the
// original. Unlike trashing, nothing goes to the Trash; the action is reversible by re-downloading,
// which `ActionLog` records so the Undo screen can offer it.

/// "Keep in iCloud only": remove the local copy of a file that iCloud already holds, the way Finder's
/// Remove Download does. Nothing is deleted anywhere; opening the file downloads it again.
enum CloudEvict {
    /// What iCloud and the local disk currently hold for one item.
    struct Status: Sendable {
        let inCloud: Bool        // the item is managed by iCloud (iCloud Drive, or synced Desktop/Documents)
        let uploaded: Bool       // iCloud has the full content, so evicting is safe
        let downloaded: Bool     // a local copy currently exists
        var canEvict: Bool { inCloud && uploaded && downloaded }

        /// Why this item cannot be evicted right now, in plain English, or nil when it can. The approval sheet and
        /// the preview both use this, so they always agree.
        var refusal: String? {
            if !inCloud { return "Not in iCloud." }
            if !uploaded { return "Still uploading to iCloud." }
            if !downloaded { return "Already in iCloud only." }
            return nil
        }
    }

    /// Resource keys needed to answer `status(of:)` and to walk a folder.
    static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey,
    ]

    /// Reports whether `path` is in iCloud and whether evicting it is possible right now.
    static func status(of path: String) -> Status {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else {
            return Status(inCloud: false, uploaded: false, downloaded: false)
        }
        if v.isDirectory == true {
            // A folder is evictable if anything inside still has a local copy; uploaded is checked per file at run time.
            return Status(inCloud: true, uploaded: true, downloaded: hasLocalContent(url))
        }
        let downloaded = v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded
        return Status(inCloud: true, uploaded: v.ubiquitousItemIsUploaded ?? false, downloaded: downloaded)
    }

    /// Whether any file inside `dir` has a local copy. Gives up after 5000 entries and assumes yes, to keep
    /// the check quick on very large folders.
    private static func hasLocalContent(_ dir: URL) -> Bool {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return false }
        var n = 0
        for case let u as URL in en {
            n += 1
            if n > 5000 { return true }
            if let v = try? u.resourceValues(forKeys: keys), v.isDirectory != true,
                v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded
            {
                return true
            }
        }
        return false
    }

    /// Bytes currently occupied locally by an item (0 after eviction).
    static func localBytes(of path: String) -> Int64 { AppInventory.allocatedSize(of: path) }

    /// Evicts one item. Folders are walked and each uploaded file evicted; files not yet uploaded are left alone.
    /// The result is the bytes freed, the number of files skipped because iCloud had not finished uploading
    /// them, and the first error encountered. A file is only ever evicted once `ubiquitousItemIsUploaded` is true,
    /// so iCloud always holds the full content.
    static func evict(_ path: String) -> (freed: Int64, skipped: Int, error: String?) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let before = localBytes(of: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return (0, 0, "File no longer exists.") }
        var skipped = 0
        var firstError: String?
        if isDir.boolValue {
            guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
                return (0, 0, "Couldn't look inside the folder.")
            }
            for case let u as URL in en {
                guard let v = try? u.resourceValues(forKeys: keys), v.isDirectory != true, v.isUbiquitousItem == true else { continue }
                guard v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded else { continue }
                guard v.ubiquitousItemIsUploaded == true else { skipped += 1; continue }
                do { try fm.evictUbiquitousItem(at: u) } catch { firstError = firstError ?? error.localizedDescription }
            }
        } else {
            let s = status(of: path)
            guard s.inCloud else { return (0, 0, "This item isn't in iCloud.") }
            guard s.uploaded else { return (0, 1, "iCloud hasn't finished uploading it yet. Try again later.") }
            guard s.downloaded else { return (0, 0, "Already kept in iCloud only.") }
            do { try fm.evictUbiquitousItem(at: url) } catch { return (0, 0, error.localizedDescription) }
        }
        let after = localBytes(of: path)
        actionLogger.info("evicted \(path, privacy: .public): \(before) -> \(after) bytes local")
        return (max(0, before - after), skipped, firstError)
    }

    /// Asks iCloud to bring the local copy back. Returns when the request is accepted, not when the download finishes.
    static func download(_ path: String) -> String? {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
