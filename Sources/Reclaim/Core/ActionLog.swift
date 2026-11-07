import AppKit
import Foundation
import os

// The only file in the app that changes the user's files. It moves approved items to the Trash (after a
// `SafetyPolicy` check), evicts iCloud copies, records every action in a JSON history so it can be undone,
// and can restore items or empty the ones Reclaim itself trashed.

/// Shared logger for everything that touches the file system, so actions can be audited in Console.app.
let actionLogger = Logger(subsystem: "app.reclaim.mac", category: "actions")

// MARK: - History record
/// One recorded action, persisted in `history.json` so the Undo screen survives restarts.
struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    /// Where an entry currently stands. Entries start as `trashed`, `evicted` or `photosRecentlyDeleted`
    /// and move to `restored` or `deleted` as the user (or Finder) acts later.
    enum Status: String, Codable, Sendable {
        /// `trashed`: in the Trash and restorable. `restored`: back in place. `deleted`: gone from the Trash,
        /// either purged by Reclaim or emptied in Finder.
        case trashed, restored, deleted
        /// Deleted through the Photos app: recoverable from Photos › Recently Deleted for about 30 days.
        case photosRecentlyDeleted
        /// Local copy removed; the item is intact in iCloud and downloads again when opened.
        case evicted
    }

    var id: UUID
    var date: Date
    /// Where the item lived before. For Photos entries this is the item's key rather than a file path.
    var originalPath: String
    /// Where macOS put the item in the Trash, when known. Needed to restore it later.
    var trashPath: String?
    /// Bytes freed, or expected to be freed, by the action.
    var size: Int64
    /// Short explanation shown in the history list, e.g. the suggestion that led to the action.
    var reason: String
    var status: Status
}

// MARK: - Failures
/// An item that could not be trashed or evicted, with a message suitable for showing to the user.
struct TrashFailure: Sendable {
    let path: String
    let message: String
    /// macOS refused access (TCC / file permissions), as opposed to "file vanished" or a policy block.
    let isPermission: Bool

    init(path: String, message: String, isPermission: Bool = false) {
        self.path = path
        self.message = message
        self.isPermission = isPermission
    }

    /// Builds a failure from a thrown error, looking through underlying errors to see whether the cause
    /// was a permission problem (which unlocks the fallback paths in `ActionLog.trash`).
    static func from(_ error: Error, path: String) -> TrashFailure {
        let ns = error as NSError
        var permission = false
        var cursor: NSError? = ns
        while let e = cursor {
            if e.domain == NSCocoaErrorDomain,
                e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError
            {
                permission = true
            }
            if e.domain == NSPOSIXErrorDomain, e.code == Int(EPERM) || e.code == Int(EACCES) { permission = true }
            cursor = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        actionLogger.error(
            "trash failed for \(path, privacy: .public): \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public) underlying=\(String(describing: ns.userInfo[NSUnderlyingErrorKey]), privacy: .public)"
        )
        return TrashFailure(path: path, message: ns.localizedDescription, isPermission: permission)
    }
}

/// The only place that changes the file system. Everything goes through the Trash first and is
/// recorded so it can be undone. Permanent deletion is limited to items Reclaim itself trashed.
///
/// All mutable state is guarded by `lock`, and `save()` writes a snapshot taken under the lock.
final class ActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [HistoryEntry] = []
    /// Location of `history.json`, in Application Support unless a test supplies another.
    private let fileURL: URL
    /// Consulted before every trash operation; nothing is trashed without an `.allowed` verdict.
    private let policy: SafetyPolicy
    /// Where a trashed item may legitimately live: the main Trash, the iCloud Trash (Desktop and Documents sync
    /// to iCloud), or an external drive's own Trash.
    private let trashRoots: [String]

    /// - Parameters:
    ///   - fileURL: Overrides the history location; used by tests.
    ///   - policy: The safety policy to enforce.
    init(fileURL: URL? = nil, policy: SafetyPolicy = SafetyPolicy()) {
        let base =
            fileURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reclaim", isDirectory: true).appendingPathComponent("history.json")
        self.fileURL = base
        self.policy = policy
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        self.trashRoots = [home + "/.Trash/", home + "/Library/Mobile Documents/.Trash/"]
        load()
    }

    /// All recorded actions, newest first.
    var entries: [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return store.sorted { $0.date > $1.date }
    }

    /// Brings the record in line with what the user may have done in Finder since: emptied the Trash
    /// (entry becomes `deleted`) or dragged the item back out (entry becomes `restored`).
    /// Without this the Undo screen keeps promising space that was already freed.
    func reconcile() {
        let fm = FileManager.default
        lock.lock()
        var changed = false
        for i in store.indices where store[i].status == .trashed {
            let entry = store[i]
            if fm.fileExists(atPath: entry.originalPath) {
                store[i].status = .restored
                changed = true
            } else if let t = entry.trashPath, !fm.fileExists(atPath: t) {
                store[i].status = .deleted
                changed = true
            }
        }
        lock.unlock()
        if changed { save() }
    }

    // MARK: - Photos and iCloud

    /// Records photos that Photos itself has just moved to Recently Deleted. Reclaim cannot put these back;
    /// the Photos app can, for about 30 days.
    func recordPhotosDeletion(_ items: [(key: String, name: String, size: Int64)], reason: String) -> [HistoryEntry] {
        let entries = items.map {
            HistoryEntry(
                id: UUID(), date: Date(), originalPath: $0.key, trashPath: nil, size: $0.size,
                reason: "\(reason) · \($0.name)", status: .photosRecentlyDeleted)
        }
        lock.lock()
        store.append(contentsOf: entries)
        lock.unlock()
        save()
        for e in entries { actionLogger.info("photos deleted \(e.originalPath, privacy: .public)") }
        return entries
    }

    /// Removes local copies of iCloud items. Records each so Undo can ask iCloud for them again.
    func evict(_ items: [(path: String, size: Int64)], reason: String) -> (done: [HistoryEntry], freed: Int64, failed: [TrashFailure]) {
        var done: [HistoryEntry] = []
        var failed: [TrashFailure] = []
        var freed: Int64 = 0
        for item in items {
            let result = CloudEvict.evict(item.path)
            if let error = result.error, result.freed == 0 {
                failed.append(TrashFailure(path: item.path, message: error))
                continue
            }
            // iCloud removes local copies in its own time (instantly when idle, later when it is busy syncing),
            // so record the request with the expected saving; the Undo screen reconciles the real figure.
            freed += result.freed
            done.append(HistoryEntry(
                id: UUID(), date: Date(), originalPath: item.path, trashPath: nil,
                size: result.freed > 0 ? result.freed : item.size, reason: reason, status: .evicted))
            if result.skipped > 0 {
                failed.append(TrashFailure(path: item.path, message: "\(result.skipped) file\(result.skipped == 1 ? " hasn't" : "s haven't") finished uploading to iCloud yet and \(result.skipped == 1 ? "was" : "were") left alone."))
            }
        }
        lock.lock()
        store.append(contentsOf: done)
        lock.unlock()
        save()
        return (done, freed, failed)
    }

    /// Asks iCloud to download an evicted item again.
    func redownload(_ id: UUID) -> String? {
        lock.lock()
        guard let index = store.firstIndex(where: { $0.id == id }), store[index].status == .evicted else {
            lock.unlock()
            return "Nothing to download."
        }
        let entry = store[index]
        lock.unlock()
        if let error = CloudEvict.download(entry.originalPath) { return error }
        lock.lock()
        store[index].status = .restored
        lock.unlock()
        save()
        return nil
    }

    // MARK: - Trashing and restoring

    /// Moves each item to the Trash and records it. Never deletes outright.
    ///
    /// Every path is checked against `SafetyPolicy` first (with the narrower uninstall rules when `scope` is
    /// given); denied or missing items are reported in `failed` and left alone. If the normal Trash call is refused
    /// for permission reasons, fallbacks are tried in turn (a file-coordinated move, then the system recycle
    /// call, then Finder for the app bundle itself). Each fallback still ends with the item in the Trash.
    func trash(
        _ items: [(path: String, size: Int64)], reason: String, uninstalling scope: UninstallScope? = nil
    ) -> (done: [HistoryEntry], failed: [TrashFailure]) {
        var done: [HistoryEntry] = []
        var failed: [TrashFailure] = []
        let fm = FileManager.default
        for item in items {
            if let refusal = preflight(item.path, uninstalling: scope) {
                failed.append(refusal)
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            do {
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                let trashPath = (result as URL?)?.path
                actionLogger.info("trashed \(item.path, privacy: .public) -> \(trashPath ?? "?", privacy: .public)")
                done.append(HistoryEntry(
                    id: UUID(), date: Date(), originalPath: item.path, trashPath: trashPath,
                    size: item.size, reason: reason, status: .trashed))
            } catch {
                // Only permission-type failures trigger the fallbacks below; other errors are reported as they are.
                let first = TrashFailure.from(error, path: item.path)
                // Second attempt: a coordinated move into ~/.Trash. Plain trashItem is refused (error 513) for
                // iCloud-synced files another app created; the coordinated move is accepted and is just as recoverable.
                if first.isPermission {
                    let trashDir = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
                    let destination = Self.uniqueURL(trashDir.appendingPathComponent(url.lastPathComponent))
                    let attempt = Self.coordinatedMove(from: url, to: destination)
                    if let moved = attempt.url {
                        actionLogger.info("coordinated move \(item.path, privacy: .public) -> \(moved.path, privacy: .public)")
                        done.append(HistoryEntry(
                            id: UUID(), date: Date(), originalPath: item.path, trashPath: moved.path,
                            size: item.size, reason: reason, status: .trashed))
                        continue
                    }
                    actionLogger.error("coordinated move failed for \(item.path, privacy: .public): \(String(describing: attempt.error), privacy: .public)")
                }
                // Third attempt through the system's own recycle path. It needs the main thread to deliver
                // its answer, so it can only be used when we are not already on the main thread.
                if !Thread.isMainThread, let moved = Self.recycle(url) {
                    actionLogger.info("recycled \(item.path, privacy: .public) -> \(moved.path, privacy: .public)")
                    done.append(HistoryEntry(
                        id: UUID(), date: Date(), originalPath: item.path, trashPath: moved.path,
                        size: item.size, reason: reason, status: .trashed))
                } else if let scope, item.path == scope.appPath, first.isPermission {
                    // Apps in /Applications often need an administrator. Finder can ask for that; Reclaim can't.
                    let viaFinder = FinderTrash.trash(item.path)
                    if viaFinder.error == nil, !fm.fileExists(atPath: item.path) {
                        actionLogger.info("Finder trashed \(item.path, privacy: .public)")
                        done.append(HistoryEntry(
                            id: UUID(), date: Date(), originalPath: item.path, trashPath: viaFinder.trashPath,
                            size: item.size, reason: reason, status: .trashed))
                    } else {
                        failed.append(TrashFailure(
                            path: item.path,
                            message: "macOS needs an administrator to remove this app. Drag it to the Trash in Finder; its leftovers have been handled.",
                            isPermission: true))
                    }
                } else {
                    failed.append(first)
                }
            }
        }
        lock.lock()
        store.append(contentsOf: done)
        lock.unlock()
        save()
        return (done, failed)
    }

    /// The checks that happen before anything is moved: the safety policy, then whether the item still exists.
    /// Returns why the item must be left alone, or nil when it may go ahead.
    func preflight(_ path: String, uninstalling scope: UninstallScope? = nil) -> TrashFailure? {
        let verdict = scope.map { policy.verdict(forPath: path, uninstalling: $0) } ?? policy.verdict(forPath: path)
        if case .denied(let why) = verdict { return TrashFailure(path: path, message: why) }
        guard FileManager.default.fileExists(atPath: path) else {
            return TrashFailure(path: path, message: "File no longer exists.")
        }
        return nil
    }

    /// A destination that doesn't exist yet: "name.ext", then "name 2.ext", "name 3.ext"…
    static func uniqueURL(_ url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        guard exists(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Moves `source` to `destination` under file coordination. This is what gets past the error 513 that a plain
    /// `trashItem` hits on iCloud-synced Desktop and Documents files that another app created: macOS refuses the
    /// uncoordinated move, but accepts the coordinated one. Returns the final URL, or the error.
    static func coordinatedMove(from source: URL, to destination: URL) -> (url: URL?, error: Error?) {
        var coordinationError: NSError?
        var moved: URL?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { src, dst in
            do {
                try FileManager.default.moveItem(at: src, to: dst)
                moved = dst
            } catch {
                failure = error
            }
        }
        return (moved, failure ?? coordinationError)
    }

    /// Asks macOS to recycle a file. Blocks until done. The completion arrives on the main thread,
    /// so this must never be called from it.
    private static func recycle(_ url: URL) -> URL? {
        precondition(!Thread.isMainThread, "recycle would deadlock on the main thread")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var moved: URL?
        NSWorkspace.shared.recycle([url]) { map, error in
            moved = map[url]
            if let error { actionLogger.error("recycle failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)") }
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            actionLogger.error("recycle timed out for \(url.path, privacy: .public)")
            return nil
        }
        return moved
    }

    /// Moves a trashed item back to its original location and marks it `restored`. Returns an error message,
    /// or nil on success.
    func restore(_ id: UUID) -> String? {
        lock.lock()
        guard let index = store.firstIndex(where: { $0.id == id }), store[index].status == .trashed else {
            lock.unlock()
            return "Nothing to restore."
        }
        let entry = store[index]
        lock.unlock()
        guard let trashPath = entry.trashPath else {
            return "Reclaim doesn't know where macOS put this item. Look for it in the Trash in Finder."
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: trashPath) else {
            reconcile()
            return "The item is no longer in the Trash."
        }
        guard !fm.fileExists(atPath: entry.originalPath) else { return "Something already exists at the original location." }
        do {
            try fm.createDirectory(
                at: URL(fileURLWithPath: entry.originalPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(atPath: trashPath, toPath: entry.originalPath)
            } catch {
                // Same reason as trashing: iCloud-synced locations may need the move to be coordinated.
                let retry = Self.coordinatedMove(from: URL(fileURLWithPath: trashPath), to: URL(fileURLWithPath: entry.originalPath))
                if retry.url == nil { throw retry.error ?? error }
            }
        } catch {
            actionLogger.error("restore failed for \(entry.originalPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
        lock.lock()
        store[index].status = .restored
        lock.unlock()
        save()
        return nil
    }

    // MARK: - Purging

    /// True when `path` is inside a location Reclaim recognises as a Trash.
    func isInsideTrash(_ path: String) -> Bool {
        guard !path.contains("/../") else { return false }
        if trashRoots.contains(where: { path.hasPrefix($0) }) { return true }
        return path.hasPrefix("/Volumes/") && path.contains("/.Trashes/")
    }

    /// Permanently deletes items Reclaim previously moved to the Trash. Anything else in the Trash is untouched.
    ///
    /// This is the only place a file is removed outright, and it refuses any path that is not inside a recognised
    /// Trash. It runs only when the user chooses to delete items from the Undo screen.
    func purge(_ ids: Set<UUID>) -> (freed: Int64, failures: [TrashFailure]) {
        var freed: Int64 = 0
        var failures: [TrashFailure] = []
        let fm = FileManager.default
        lock.lock()
        let targets = store.enumerated().filter { ids.contains($0.element.id) && $0.element.status == .trashed }
        lock.unlock()

        for (index, entry) in targets {
            guard let path = entry.trashPath, isInsideTrash(path) else {
                failures.append(TrashFailure(path: entry.originalPath, message: "Not located in your Trash."))
                continue
            }
            do {
                if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
                lock.lock(); store[index].status = .deleted; lock.unlock()
                freed += entry.size
                actionLogger.info("purged \(path, privacy: .public)")
            } catch {
                failures.append(TrashFailure.from(error, path: entry.originalPath))
            }
        }
        save()
        return (freed, failures)
    }

    // MARK: - Persistence

    /// Reads the history file; a missing or unreadable file simply starts an empty history.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        store = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Writes the history atomically so a crash mid-write cannot corrupt it.
    private func save() {
        lock.lock()
        let snapshot = store
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            actionLogger.error("could not save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
