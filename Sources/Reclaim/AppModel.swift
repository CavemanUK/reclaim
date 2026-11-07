import AppKit
import Observation
import Photos
import SwiftUI

struct TrashRequest: Identifiable {
    enum Kind { case files, photosLibrary, cloudEvict }

    struct Entry: Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let size: Int64
        let blockedReason: String?
    }

    let id = UUID()
    let kind: Kind
    let reason: String
    let entries: [Entry]
    /// Set when this request uninstalls an app, which relaxes the safety rules for exactly that app's files.
    var uninstalling: UninstallScope? = nil

    var allowed: [Entry] { entries.filter { $0.blockedReason == nil } }
    var blocked: [Entry] { entries.filter { $0.blockedReason != nil } }
    var totalBytes: Int64 { allowed.reduce(0) { $0 + $1.size } }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case map = "Space Map"
    case suggestions = "Suggestions"
    case duplicates = "Duplicates"
    case photos = "Similar photos"
    case clearouts = "Photo clear-outs"
    case apps = "Uninstall apps"
    case history = "History"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "My Mac"
        case .map: "What's big"
        case .suggestions: "Clean up"
        case .duplicates: "Duplicates"
        case .photos: "Similar photos"
        case .clearouts: "Photo clear-outs"
        case .apps: "Uninstall apps"
        case .history: "Undo"
        }
    }
    var color: Color {
        switch self {
        case .overview: .blue
        case .map: .purple
        case .suggestions: .yellow
        case .duplicates: .indigo
        case .photos: .pink
        case .clearouts: .teal
        case .apps: .orange
        case .history: .gray
        }
    }
    var icon: String {
        switch self {
        case .overview: "chart.pie"
        case .map: "square.grid.3x3.fill"
        case .suggestions: "lightbulb"
        case .duplicates: "square.on.square"
        case .photos: "photo.stack"
        case .clearouts: "camera.viewfinder"
        case .apps: "app.badge.checkmark"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum ScanTarget: Hashable, Identifiable {
    case disk
    case home
    case folder(URL)

    var id: String {
        switch self {
        case .disk: "disk"
        case .home: "home"
        case .folder(let url): url.path
        }
    }

    var title: String {
        switch self {
        case .disk: "This Mac"
        case .home: "Home folder"
        case .folder(let url): url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
    }

    var icon: String {
        switch self {
        case .disk: "desktopcomputer"
        case .home: "house"
        case .folder(let url): url.path.hasPrefix("/Volumes/") && url.pathComponents.count <= 3 ? "externaldrive" : "folder"
        }
    }

    func url(home: String) -> URL {
        switch self {
        case .disk: URL(fileURLWithPath: "/")
        case .home: URL(fileURLWithPath: home)
        case .folder(let url): url
        }
    }
}

@MainActor @Observable
final class AppModel {
    var selection: SidebarItem? = .overview

    // Drive facts (available before any scan)
    var container: APFSContainerInfo?
    var snapshots: [LocalSnapshot] = []
    var volume = VolumeInfo.current()
    var fullDiskAccess = true

    // Scan
    var target: ScanTarget = .disk
    var scannedTarget: ScanTarget?
    var externalVolumes: [URL] = []
    var customFolders: [URL] = []
    var isScanning = false
    var progress = ScanSnapshot()
    var scanSeconds: Double = 0
    var root: FileNode?
    var report: SpaceReport?
    var insights: [Insight] = []
    var insightSelection = Set<String>()

    // Duplicates
    enum DupState { case idle, working, done }
    var dupFolders: [URL] = {
        let home = NSHomeDirectory()
        return ["Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"]
            .map { URL(fileURLWithPath: home + "/" + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()
    var dupMinSize: Int64 = 1 << 20
    var dupState: DupState = .idle
    var dupProgress = DupProgress()
    var dupCompare: DupGroup?
    var dupGroups: [DupGroup] = []
    var dupSelection = Set<String>()
    private var dupFinder: DuplicateFinder?

    // Similar photos
    enum PhotoSourceKind: String, CaseIterable, Identifiable {
        case folders = "Folders"
        case library = "Photos library"
        var id: String { rawValue }
    }
    var photoSourceKind: PhotoSourceKind = .folders
    var photoAuth: PHAuthorizationStatus = LibrarySource.authorization
    var photoFolders: [URL] = {
        let home = NSHomeDirectory()
        return ["Pictures", "Downloads", "Desktop"].map { URL(fileURLWithPath: home + "/" + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()
    var photoStrictness: Strictness = .balanced
    var photoState: DupState = .idle
    var photoProgress = PhotoProgress()
    var photoGroups: [SimilarGroup] = []
    var photoSelection = Set<String>()
    var photoCompare: SimilarGroup?
    private var photoFinder: SimilarPhotoFinder?

    // Photo clear-outs (library only)
    var clearoutState: DupState = .idle
    var clearoutProgress = ClearoutProgress()
    var clearouts: [ClearoutPhoto] = []
    var clearoutSelection = Set<String>()
    private var clearoutFinder: PhotoClearoutFinder?

    // Uninstall apps
    var appsState: DupState = .idle
    var apps: [InstalledApp] = []
    var selectedApp: InstalledApp?
    var leftovers: [Leftover] = []
    var leftoversLoading = false
    /// Paths (app bundle and leftovers) marked for removal for the selected app.
    var uninstallSelection = Set<String>()
    private var appsCancel: CancelFlag?
    private var leftoverCancel: CancelFlag?

    /// Every other installed app's identifier: the uninstall matcher must never claim a sibling product's files.
    private func otherBundleIDs(than app: InstalledApp) -> Set<String> {
        Set(apps.filter { $0.path != app.path }.compactMap(\.bundleID))
    }

    // AI report
    var aiReport: String?
    var aiReportSource: ReportSource?
    var aiReportWriting = false

    func writeReport() {
        guard !aiReportWriting else { return }
        aiReportWriting = true
        let facts = ReportFacts.build(
            volume: volume, report: report, insights: insights, apps: apps,
            duplicateBytes: dupGroups.reduce(0) { $0 + $1.reclaimable },
            similarBytes: photoGroups.reduce(0) { $0 + $1.reclaimable },
            clearoutCount: clearouts.count, home: home)
        Task {
            let result = await AIReport.write(facts: facts)
            aiReport = result.text
            aiReportSource = result.source
            aiReportWriting = false
        }
    }

    // Homebrew commands (run only after the user confirms in the sheet)
    enum CommandState { case confirming, running, finished(Int32) }
    var brewRequest: BrewCommand?
    var brewState: CommandState = .confirming
    var brewOutput = ""
    var brewAvailable: Bool { CommandRunner.brewPath() != nil }

    func requestBrew(_ command: BrewCommand) {
        brewOutput = ""
        brewState = .confirming
        brewRequest = command
    }

    func runBrew() {
        guard let command = brewRequest, case .confirming = brewState else { return }
        brewState = .running
        actionLogger.info("running \(command.display, privacy: .public)")
        Task {
            let status = await CommandRunner.runBrew(command.arguments) { text in
                Task { @MainActor in self.brewOutput += text }
            }
            brewState = .finished(status ?? 127)
            if status == nil { brewOutput += "Homebrew isn't installed at /opt/homebrew or /usr/local.\n" }
            volume = VolumeInfo.current()
            if command.arguments.first == "uninstall" { loadApps() }
        }
    }

    func dismissBrew() {
        if case .running = brewState { return }
        brewRequest = nil
    }

    // Actions
    var trashRequest: TrashRequest?
    var history: [HistoryEntry] = []
    var toast: Toast?

    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        let undoIDs: [UUID]
        var isProblem = false
        /// Offer a button that opens the macOS privacy settings Reclaim may need.
        var offersSettings = false
        /// Offer a button that opens the Photos app (where Recently Deleted lives).
        var opensPhotos = false
    }

    func showToast(_ text: String, undo: [UUID] = [], problem: Bool = false, settings: Bool = false, photos: Bool = false) {
        toast = Toast(text: text, undoIDs: undo, isProblem: problem, offersSettings: settings, opensPhotos: photos)
    }

    /// Puts back everything from a toast's Undo button.
    func undo(_ ids: [UUID]) {
        let log = self.log
        toast = nil
        let evicted = Set(history.filter { $0.status == .evicted }.map(\.id))
        Task {
            let results = await runBlocking { ids.map { evicted.contains($0) ? log.redownload($0) : log.restore($0) } }
            history = log.entries
            let failed = results.compactMap { $0 }
            volume = VolumeInfo.current()
            showToast(failed.isEmpty ? "Put back \(ids.count) item\(ids.count == 1 ? "" : "s")." : failed[0])
        }
    }

    let home = NSHomeDirectory()
    let log = ActionLog()
    private var scanner: DiskScanner?
    private var scanTask: Task<Void, Never>?

    init() {
        customFolders = (UserDefaults.standard.stringArray(forKey: "customFolders") ?? []).map { URL(fileURLWithPath: $0) }
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            }
        }
        // Permissions change in System Settings while Reclaim is open; re-check whenever we come to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPhotoAuth() }
        }
        history = log.entries
        refreshHistory()
        refreshSystemInfo()
    }

    /// Re-reads the undo record after checking it against the file system (the user may have emptied
    /// or restored from the Trash in Finder since).
    func refreshHistory() {
        let log = self.log
        Task {
            history = await runBlocking {
                log.reconcile()
                return log.entries
            }
        }
    }

    func refreshVolumes() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        externalVolumes = urls.filter { url in
            url.path.hasPrefix("/Volumes/") && url.resolvingSymlinksInPath().path != "/"
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Look here"
        panel.message = "Choose a folder or drive for Reclaim to look through. It only reads sizes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !customFolders.contains(url) && !externalVolumes.contains(url) {
            customFolders.append(url)
            UserDefaults.standard.set(customFolders.map(\.path), forKey: "customFolders")
        }
        target = .folder(url)
        selection = .overview
    }

    func removeCustomFolder(_ url: URL) {
        customFolders.removeAll { $0 == url }
        UserDefaults.standard.set(customFolders.map(\.path), forKey: "customFolders")
        if target == .folder(url) { target = .disk }
    }

    func refreshSystemInfo() {
        Task {
            let (c, s) = await runBlocking { (SystemInfo.apfsContainer(), SystemInfo.localSnapshots()) }
            container = c
            snapshots = s
            volume = VolumeInfo.current()
            fullDiskAccess = await runBlocking { SystemInfo.hasFullDiskAccess() }
        }
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        root = nil
        report = nil
        insights = []
        insightSelection = []
        aiReport = nil
        aiReportSource = nil
        progress = ScanSnapshot()
        let wholeDisk = target == .disk
        let scanTarget = target
        let url = target.url(home: home)
        let scanner = DiskScanner(options: wholeDisk ? .wholeDisk : DiskScanner.Options())
        self.scanner = scanner
        let started = Date()
        let home = self.home

        scanTask = Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    self.progress = scanner.snapshot()
                    self.scanSeconds = Date().timeIntervalSince(started)
                }
            }
            async let system = runBlocking { (SystemInfo.apfsContainer(), SystemInfo.localSnapshots()) }
            let node = await scanner.scan(root: url)
            let (c, s) = await system
            poller.cancel()

            container = c ?? container
            snapshots = s
            volume = VolumeInfo.current()
            scanSeconds = Date().timeIntervalSince(started)
            fullDiskAccess = await runBlocking { SystemInfo.hasFullDiskAccess() }
            progress = scanner.snapshot()

            if !scanner.isCancelledPublic {
                let cats = await runBlocking { SpaceClassifier.breakdown(root: node, home: home) }
                let found = await runBlocking { InsightEngine(home: home).generate(from: node) }
                let fallback = APFSContainerInfo(ceiling: volume.total, free: volume.available, volumes: [])
                root = node
                scannedTarget = scanTarget
                insights = found
                report = SpaceReport(
                    container: container ?? fallback, snapshots: snapshots, categories: cats,
                    scannedBytes: node.size, unreadable: scanner.unreadablePaths, purgeable: volume.purgeable,
                    scannedWholeDisk: wholeDisk)
            }
            isScanning = false
        }
    }

    func cancelScan() { scanner?.cancel() }

    // MARK: Duplicates

    func findDuplicates() {
        guard dupState != .working else { return }
        dupState = .working
        dupGroups = []
        dupSelection = []
        dupProgress = DupProgress()
        let finder = DuplicateFinder()
        dupFinder = finder
        let folders = dupFolders
        let minSize = dupMinSize
        Task {
            let groups = await finder.find(roots: folders, minSize: minSize) { p in
                Task { @MainActor in self.dupProgress = p }
            }
            dupGroups = groups
            dupState = .done
        }
    }

    func cancelDuplicates() { dupFinder?.cancel() }

    func addDupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for duplicate files."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !dupFolders.contains(url) { dupFolders.append(url) }
    }

    // MARK: Similar photos

    func findPhotos() {
        guard photoState != .working else { return }
        photoState = .working
        photoGroups = []
        photoSelection = []
        photoProgress = PhotoProgress()
        let finder = SimilarPhotoFinder()
        photoFinder = finder
        let source: any PhotoSource = photoSourceKind == .library ? LibrarySource() : FileSource(roots: photoFolders)
        let level = photoStrictness
        Task {
            let groups = await finder.find(source: source, strictness: level) { p in
                Task { @MainActor in self.photoProgress = p }
            }
            photoGroups = groups
            photoState = .done
        }
    }

    func cancelPhotos() { photoFinder?.cancel() }

    func requestPhotoAccess() {
        Task { photoAuth = await LibrarySource.requestAccess() }
    }

    func refreshPhotoAuth() { photoAuth = LibrarySource.authorization }

    var canSearchLibrary: Bool { photoAuth == .authorized || photoAuth == .limited }

    func openPhotosPrivacySettings() { openPrivacyPane("Privacy_Photos") }

    // MARK: Uninstall apps

    func loadApps() {
        guard appsState != .working else { return }
        appsState = .working
        let flag = CancelFlag()
        appsCancel = flag
        Task {
            apps = await runBlocking { AppInventory.installedApps(cancel: flag) }
            appsState = .done
            if let sel = selectedApp, !apps.contains(sel) { selectedApp = nil; leftovers = []; uninstallSelection = [] }
        }
    }

    func cancelApps() { appsCancel?.cancel() }

    func isRunning(_ app: InstalledApp) -> Bool { AppInventory.isRunning(app) }

    func inspect(_ app: InstalledApp) {
        selectedApp = app
        leftovers = []
        uninstallSelection = [app.path]
        leftoversLoading = true
        leftoverCancel?.cancel()
        let flag = CancelFlag()
        leftoverCancel = flag
        let others = otherBundleIDs(than: app)
        Task {
            let found = await runBlocking { AppLeftoverFinder.find(for: app, others: others, cancel: flag) }
            guard !flag.isCancelled else { return }
            guard selectedApp == app else { return }
            leftovers = found
            // Everything removable starts selected; the user unticks what to keep. Admin-only files can't be.
            uninstallSelection = Set([app.path] + found.filter { !$0.needsAdmin }.map(\.path))
            leftoversLoading = false
        }
    }

    var uninstallBytes: Int64 {
        guard let app = selectedApp else { return 0 }
        var total: Int64 = uninstallSelection.contains(app.path) ? app.size : 0
        for l in leftovers where uninstallSelection.contains(l.path) { total += l.size }
        return total
    }

    func requestUninstall() {
        guard let app = selectedApp else { return }
        var entries: [TrashRequest.Entry] = []
        if uninstallSelection.contains(app.path) {
            entries.append(TrashRequest.Entry(path: app.path, name: app.name + ".app", size: app.size, blockedReason: nil))
        }
        let scope = UninstallScope(appPath: app.path, bundleID: app.bundleID, appName: app.name, otherBundleIDs: otherBundleIDs(than: app))
        let policy = SafetyPolicy()
        for l in leftovers where uninstallSelection.contains(l.path) {
            var blocked: String?
            if case .denied(let why) = policy.verdict(forPath: l.path, uninstalling: scope) { blocked = why }
            entries.append(TrashRequest.Entry(path: l.path, name: l.name, size: l.size, blockedReason: blocked))
        }
        guard !entries.isEmpty else { return }
        trashRequest = TrashRequest(kind: .files, reason: "Uninstall \(app.name)", entries: entries, uninstalling: scope)
    }

    // MARK: Photo clear-outs

    func findClearouts() {
        guard clearoutState != .working else { return }
        clearoutState = .working
        clearouts = []
        clearoutSelection = []
        clearoutProgress = ClearoutProgress()
        let finder = PhotoClearoutFinder()
        clearoutFinder = finder
        Task {
            let found = await finder.find { p in
                Task { @MainActor in self.clearoutProgress = p }
            }
            clearouts = found
            clearoutState = .done
        }
    }

    func cancelClearouts() { clearoutFinder?.cancel() }

    func clearouts(of kind: ClearoutKind) -> [ClearoutPhoto] { clearouts.filter { $0.kind == kind } }

    func selectClearouts(_ kind: ClearoutKind, olderThanDays days: Int? = nil) {
        let now = Date()
        for c in clearouts(of: kind) where canTrash(c.photo.path) {
            if let days, let age = c.ageInDays(now: now), age < days { continue }
            if days != nil, c.ageInDays(now: now) == nil { continue }
            clearoutSelection.insert(c.photo.path)
        }
    }

    func clearClearoutSelection(_ kind: ClearoutKind) {
        for c in clearouts(of: kind) { clearoutSelection.remove(c.photo.path) }
    }

    /// Builds the approval sheet for photos chosen on the Similar photos screen (files or library assets).
    func requestPhotoRemoval(_ photos: [PhotoInfo], reason: String) {
        if photos.allSatisfy(\.isAsset) {
            let entries = photos.map { TrashRequest.Entry(path: $0.path, name: $0.name, size: $0.size, blockedReason: nil) }
            trashRequest = TrashRequest(kind: .photosLibrary, reason: reason, entries: entries)
        } else {
            requestTrash(photos.filter { !$0.isAsset }.map { ($0.path, $0.size) }, reason: reason)
        }
    }

    private func deleteFromPhotos(_ request: TrashRequest) {
        let ids = request.allowed.compactMap { PhotoInfo.assetID(fromKey: $0.path) }
        let log = self.log
        Task {
            do {
                try await LibrarySource.delete(assetIDs: ids)
            } catch let error as PHPhotosError where error.code == .userCancelled {
                showToast("Cancelled in Photos. Nothing was deleted.")
                return
            } catch {
                actionLogger.error("photos delete failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                showToast("Photos couldn't delete them: \(error.localizedDescription)", problem: true)
                return
            }
            let items = request.allowed.map { (key: $0.path, name: $0.name, size: $0.size) }
            _ = await runBlocking { log.recordPhotosDeletion(items, reason: request.reason) }
            history = log.entries
            let moved = Set(request.allowed.map(\.path))
            photoSelection.subtract(moved)
            photoGroups = Self.prune(photoGroups, removing: moved)
            clearoutSelection.subtract(moved)
            clearouts.removeAll { moved.contains($0.photo.path) }
            let bytes = request.allowed.reduce(Int64(0)) { $0 + $1.size }
            showToast(
                "Moved \(moved.count) photo\(moved.count == 1 ? "" : "s") (\(ByteFormat.string(bytes))) to Recently Deleted in Photos. They can be recovered there for about 30 days; the space comes back when Photos clears them.",
                photos: true)
        }
    }

    private static func prune(_ groups: [SimilarGroup], removing moved: Set<String>) -> [SimilarGroup] {
        groups.compactMap { g in
            let left = g.photos.filter { !moved.contains($0.path) }
            guard left.count > 1 else { return nil }
            var copy = SimilarGroup(
                photos: left, suggestedKeep: left.contains { $0.path == g.suggestedKeep } ? g.suggestedKeep : left[0].path,
                reasons: g.reasons, looseness: g.looseness)
            if copy.suggestedKeep != g.suggestedKeep { copy.reasons = [] }
            return copy
        }
    }

    func addPhotoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for similar photos."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !photoFolders.contains(url) { photoFolders.append(url) }
    }

    func selectPhotoExtras() {
        var picked = Set<String>()
        for g in photoGroups {
            for p in g.photos where p.path != g.suggestedKeep && canTrash(p.path) { picked.insert(p.path) }
        }
        photoSelection = picked
    }

    /// Marks every photo in one set except the suggested best.
    func selectPhotoExtras(in group: SimilarGroup) {
        for p in group.photos where p.path != group.suggestedKeep && canTrash(p.path) { photoSelection.insert(p.path) }
    }

    func clearPhotoSelection(in group: SimilarGroup) {
        for p in group.photos { photoSelection.remove(p.path) }
    }

    func setPhoto(_ photo: PhotoInfo, in group: SimilarGroup, selected: Bool) {
        if selected {
            let kept = group.photos.filter { $0.path != photo.path && !photoSelection.contains($0.path) }.count
            guard kept >= 1 else { return }
            photoSelection.insert(photo.path)
        } else {
            photoSelection.remove(photo.path)
        }
    }

    func canTrash(_ path: String) -> Bool {
        if path.hasPrefix(PhotoItem.assetPrefix) { return photoAuth == .authorized }
        return SafetyPolicy().verdict(forPath: path).isAllowed
    }

    /// Marks every copy except the suggested one in each group. Always leaves one copy per group.
    func selectDuplicateExtras() {
        var picked = Set<String>()
        for g in dupGroups {
            for f in g.files where f.path != g.suggestedKeep && canTrash(f.path) { picked.insert(f.path) }
        }
        dupSelection = picked
    }

    func setDuplicate(_ file: DupFile, in group: DupGroup, selected: Bool) {
        if selected {
            let stillKept = group.files.filter { $0.path != file.path && !dupSelection.contains($0.path) }.count
            guard stillKept >= 1 else { return }
            dupSelection.insert(file.path)
        } else {
            dupSelection.remove(file.path)
        }
    }

    // MARK: Safe actions

    func requestTrash(_ items: [(path: String, size: Int64)], reason: String) {
        let policy = SafetyPolicy()
        let entries = items.map { item -> TrashRequest.Entry in
            let name = (item.path as NSString).lastPathComponent
            var blocked: String?
            if case .denied(let why) = policy.verdict(forPath: item.path) { blocked = why }
            return TrashRequest.Entry(path: item.path, name: name, size: item.size, blockedReason: blocked)
        }
        trashRequest = TrashRequest(kind: .files, reason: reason, entries: entries)
    }

    /// Builds the approval sheet for "keep in iCloud only". Only items confirmed to be in iCloud are offered.
    func requestEvict(_ items: [(path: String, size: Int64)], reason: String) {
        let entries = items.map { item -> TrashRequest.Entry in
            let s = CloudEvict.status(of: item.path)
            let blocked: String? = !s.inCloud ? "Not in iCloud." : (!s.uploaded ? "Still uploading to iCloud." : (!s.downloaded ? "Already in iCloud only." : nil))
            return TrashRequest.Entry(path: item.path, name: (item.path as NSString).lastPathComponent, size: item.size, blockedReason: blocked)
        }
        trashRequest = TrashRequest(kind: .cloudEvict, reason: reason, entries: entries)
    }

    private func performEvict(_ request: TrashRequest) {
        let items = request.allowed.map { (path: $0.path, size: $0.size) }
        guard !items.isEmpty else { return }
        let log = self.log
        let reason = request.reason
        Task {
            let result = await runBlocking { log.evict(items, reason: reason) }
            history = log.entries
            let done = Set(result.done.map(\.originalPath))
            insights = insights.compactMap { insight in
                guard insight.action == .evict else { return insight }
                let remaining = insight.items.filter { !done.contains($0.path) }
                guard !remaining.isEmpty else { return nil }
                var copy = insight
                copy = Insight(id: insight.id, title: insight.title, summary: insight.summary, icon: insight.icon,
                               category: insight.category, risk: insight.risk, items: remaining,
                               totalBytes: remaining.reduce(0) { $0 + $1.size }, command: insight.command, advice: insight.advice,
                               partial: insight.partial, action: .evict)
                return copy
            }
            insightSelection.subtract(done)
            volume = VolumeInfo.current()
            if result.done.isEmpty {
                showToast("Nothing changed. \(result.failed.first?.message ?? "")", problem: true)
            } else {
                var text = result.freed > 0
                    ? "Freed \(ByteFormat.string(result.freed)) on this Mac. \(done.count) item\(done.count == 1 ? " is" : "s are") now in iCloud only and will download when opened."
                    : "Asked iCloud to keep \(done.count) item\(done.count == 1 ? "" : "s") in iCloud only. It removes the local copies when it's not busy syncing, usually within a minute."
                if let f = result.failed.first { text += " \(f.message)" }
                showToast(text, undo: result.done.map(\.id), problem: !result.failed.isEmpty)
            }
        }
    }

    func redownload(_ entry: HistoryEntry) {
        let log = self.log
        Task {
            let error = await runBlocking { log.redownload(entry.id) }
            history = log.entries
            showToast(error ?? "Downloading \((entry.originalPath as NSString).lastPathComponent) from iCloud again.")
        }
    }

    func confirmTrash(_ request: TrashRequest) {
        trashRequest = nil
        if request.kind == .photosLibrary {
            deleteFromPhotos(request)
            return
        }
        if request.kind == .cloudEvict {
            performEvict(request)
            return
        }
        let items = request.allowed.map { (path: $0.path, size: $0.size) }
        guard !items.isEmpty else { return }
        let log = self.log
        let reason = request.reason
        let scope = request.uninstalling
        Task {
            let result = await runBlocking { log.trash(items, reason: reason, uninstalling: scope) }
            history = log.entries
            let moved = Set(result.done.map(\.originalPath))
            if let scope {
                leftovers.removeAll { moved.contains($0.path) }
                uninstallSelection.subtract(moved)
                if moved.contains(scope.appPath) {
                    apps.removeAll { $0.path == scope.appPath }
                    selectedApp = nil
                    leftovers = []
                    uninstallSelection = []
                }
            }
            insights = insights.compactMap { insight in
                let remaining = insight.items.filter { !moved.contains($0.path) }
                guard !remaining.isEmpty else { return nil }
                return Insight(
                    id: insight.id, title: insight.title, summary: insight.summary, icon: insight.icon,
                    category: insight.category, risk: insight.risk, items: remaining,
                    totalBytes: remaining.reduce(0) { $0 + $1.size }, command: insight.command, advice: insight.advice,
                    partial: insight.partial)
            }
            insightSelection.subtract(moved)
            dupSelection.subtract(moved)
            photoSelection.subtract(moved)
            photoGroups = Self.prune(photoGroups, removing: moved)
            dupGroups = dupGroups.compactMap { g in
                let left = g.files.filter { !moved.contains($0.path) }
                guard left.count > 1 else { return nil }
                return DupGroup(files: left, suggestedKeep: left.contains { $0.path == g.suggestedKeep } ? g.suggestedKeep : left[0].path)
            }
            let freed = result.done.reduce(Int64(0)) { $0 + $1.size }
            if result.done.isEmpty {
                if let first = result.failed.first, first.isPermission {
                    let name = (first.path as NSString).lastPathComponent
                    showToast(
                        "macOS blocked Reclaim from moving “\(name)”. In Privacy & Security, check both Full Disk Access and Files and Folders. If Reclaim was updated recently, remove it from Full Disk Access and add it again, then restart Reclaim.",
                        problem: true, settings: true)
                } else {
                    showToast("Nothing was moved. \(result.failed.first?.message ?? "Unknown reason.")", problem: true)
                }
            } else {
                var text = "Moved \(result.done.count) item\(result.done.count == 1 ? "" : "s") (\(ByteFormat.string(freed))) to the Trash. The space comes back when the Trash is emptied."
                if !result.failed.isEmpty { text += " \(result.failed.count) could not be moved: \(result.failed[0].message)" }
                showToast(text, undo: result.done.map(\.id), problem: !result.failed.isEmpty)
            }
            volume = VolumeInfo.current()
        }
    }

    func restore(_ entry: HistoryEntry) {
        let log = self.log
        Task {
            let error = await runBlocking { log.restore(entry.id) }
            history = log.entries
            showToast(error ?? "Put back \((entry.originalPath as NSString).lastPathComponent).")
        }
    }

    func purge(_ ids: Set<UUID>) {
        let log = self.log
        Task {
            let result = await runBlocking { log.purge(ids) }
            history = log.entries
            volume = VolumeInfo.current()
            showToast("Freed \(ByteFormat.string(result.freed)) for good."
                + (result.failures.isEmpty ? "" : " \(result.failures.count) item(s) failed."))
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFullDiskAccessSettings() { openPrivacyPane("Privacy_AllFiles") }
    func openFilesAndFoldersSettings() { openPrivacyPane("Privacy_FilesAndFolders") }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a fresh copy of the app and quits this one (needed after granting Full Disk Access).
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension DiskScanner {
    var isCancelledPublic: Bool { cancelledFlag }
}

extension PhotoInfo {
    static func assetID(fromKey key: String) -> String? {
        key.hasPrefix(PhotoItem.assetPrefix) ? String(key.dropFirst(PhotoItem.assetPrefix.count)) : nil
    }
}
