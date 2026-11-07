// The application's single model object, `AppModel`, plus the small value types its screens share
// (`SidebarItem`, `ScanTarget`, `TrashRequest`). Every screen reads state from here and calls its methods;
// in the app, a user's approval reaches Core's `ActionLog` only through here. See docs/ARCHITECTURE.md.

import AppKit
import Observation
import Photos
import SwiftUI

/// A pending request to remove or change items, shown in a confirmation sheet before anything happens.
///
/// Nothing is touched until `AppModel.confirmTrash(_:)` receives it. Entries that `SafetyPolicy` (or the iCloud
/// checks) refuse stay in the request with a reason, so the sheet can list them separately as items Reclaim won't touch.
struct TrashRequest: Identifiable {
    /// What approving the request does. The three paths have different safety checks, wording and undo behaviour,
    /// so `AppModel.confirmTrash(_:)` routes on this.
    /// - `files`: move to the Trash through `ActionLog`.
    /// - `photosLibrary`: delete Photos assets through PhotoKit (they go to Recently Deleted).
    /// - `cloudEvict`: remove only the local copy of iCloud files ("keep in iCloud only").
    enum Kind { case files, photosLibrary, cloudEvict }

    /// One item in a request. `path` is a file path, or for a library photo an asset key starting with
    /// `PhotoItem.assetPrefix`. A non-nil `blockedReason` means Reclaim will not touch it.
    struct Entry: Identifiable {
        /// The path identifies the entry; a request never lists the same path twice.
        var id: String { path }
        let path: String
        let name: String
        let size: Int64
        /// Why the item is refused, in plain English for the sheet; nil when it may go ahead.
        let blockedReason: String?
    }

    /// Gives each request its own identity so `.sheet(item:)` presents a fresh sheet for every request.
    let id = UUID()
    let kind: Kind
    let reason: String
    let entries: [Entry]
    /// Set when this request uninstalls an app, which relaxes the safety rules for exactly that app's files.
    var uninstalling: UninstallScope? = nil

    /// The entries that will actually be acted on. Only these are ever passed to `ActionLog`.
    var allowed: [Entry] { entries.filter { $0.blockedReason == nil } }
    /// The entries Reclaim refuses, listed in the sheet with their reasons.
    var blocked: [Entry] { entries.filter { $0.blockedReason != nil } }
    /// Size of the allowed entries only. A size of 0 can mean "unknown" for library photos.
    var totalBytes: Int64 { allowed.reduce(0) { $0 + $1.size } }
}

/// The screens in the sidebar. The raw value is a stable identifier; `title` is what the user reads.
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case map = "Space Map"
    case overTime = "Over time"
    case suggestions = "Suggestions"
    case duplicates = "Duplicates"
    case photos = "Similar photos"
    case clearouts = "Photo clear-outs"
    case apps = "Uninstall apps"
    case history = "History"

    var id: String { rawValue }
    /// The label shown in the sidebar and used as the screen's title.
    var title: String {
        switch self {
        case .overview: "My Mac"
        case .map: "What's big"
        case .overTime: "Over time"
        case .suggestions: "Clean up"
        case .duplicates: "Duplicates"
        case .photos: "Similar photos"
        case .clearouts: "Photo clear-outs"
        case .apps: "Uninstall apps"
        case .history: "Undo"
        }
    }
    /// The tint of the sidebar icon and, on some screens, the header tile.
    var color: Color {
        switch self {
        case .overview: .blue
        case .map: .purple
        case .overTime: .mint
        case .suggestions: .yellow
        case .duplicates: .indigo
        case .photos: .pink
        case .clearouts: .teal
        case .apps: .orange
        case .history: .gray
        }
    }
    /// The SF Symbol name for the sidebar row.
    var icon: String {
        switch self {
        case .overview: "chart.pie"
        case .map: "square.grid.3x3.fill"
        case .overTime: "chart.line.uptrend.xyaxis"
        case .suggestions: "lightbulb"
        case .duplicates: "square.on.square"
        case .photos: "photo.stack"
        case .clearouts: "camera.viewfinder"
        case .apps: "app.badge.checkmark"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// What a scan looks at: the whole disk, the home folder, or one folder or drive the user chose.
///
/// Only `.disk` scans are saved to the Over time history, because folder scans say nothing about the whole drive.
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

    /// The name shown in the target menu and on the Scan button.
    var title: String {
        switch self {
        case .disk: "This Mac"
        case .home: "Home folder"
        case .folder(let url): url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
    }

    /// The SF Symbol for the target; drives under /Volumes get a drive icon.
    var icon: String {
        switch self {
        case .disk: "desktopcomputer"
        case .home: "house"
        case .folder(let url): url.path.hasPrefix("/Volumes/") && url.pathComponents.count <= 3 ? "externaldrive" : "folder"
        }
    }

    /// The folder to walk; `home` is passed in so the type stays free of global state.
    func url(home: String) -> URL {
        switch self {
        case .disk: URL(fileURLWithPath: "/")
        case .home: URL(fileURLWithPath: home)
        case .folder(let url): url
        }
    }
}

/// The single observable model behind every screen.
///
/// It is `@MainActor` and `@Observable`: views read its properties through the SwiftUI environment and call its
/// methods, and contain no business logic of their own. It never does slow work itself. A method starts a `Task`,
/// hands the blocking part to `runBlocking` (or to a finder's own async API), then assigns the result back to a
/// property. The `Task` inherits the main actor, so those assignments happen on the main thread, which is what
/// lets SwiftUI observe them safely. Progress callbacks from background threads use `Task { @MainActor in ... }`
/// for the same reason.
///
/// Changes to the user's files follow one route: a screen calls a `request...` method, which builds a `TrashRequest`
/// for the confirmation sheet; only `confirmTrash(_:)` (after the user approves) passes it on to `ActionLog`.
@MainActor @Observable
final class AppModel {
    // MARK: - Navigation, drive facts and scan state
    // The selected screen, facts about the drive that exist before any scan, and the latest scan's results.

    /// The selected sidebar row. `ContentView` treats nil as the Overview.
    var selection: SidebarItem? = .overview

    // Drive facts (available before any scan)
    /// The APFS container (size, free space, per-volume use). Nil until it has been read, or if it can't be.
    var container: APFSContainerInfo?
    /// Local Time Machine snapshots, which hold space that no file accounts for.
    var snapshots: [LocalSnapshot] = []
    /// Cached free-space figures for the Data volume. Update it with `refreshVolume()`, not by assigning directly.
    var volume = VolumeInfo.current()
    /// Whether Reclaim can read protected folders. Assumed true until checked; when false the Overview shows the access guide.
    var fullDiskAccess = true

    // Scan
    /// What the next scan will look at (chosen on the Overview).
    var target: ScanTarget = .disk
    /// What the current results describe. It can differ from `target` if the user changes the choice after scanning.
    var scannedTarget: ScanTarget?
    /// Mounted drives under /Volumes (excluding the startup disk), offered as scan targets.
    var externalVolumes: [URL] = []
    /// Folders the user added as scan targets. Saved in UserDefaults (`customFolders`).
    var customFolders: [URL] = []
    /// True while a scan is running; the Overview shows progress and the scan buttons are disabled.
    var isScanning = false
    /// Live scan progress (files seen, bytes, current path), refreshed by a timer while scanning.
    var progress = ScanSnapshot()
    /// How long the current or last scan has taken.
    var scanSeconds: Double = 0
    /// The size tree from the last completed scan; the Space Map reads it. Cleared when a new scan starts.
    var root: FileNode?
    /// The last scan combined with the APFS facts: category totals and the "hidden" gap.
    var report: SpaceReport?
    /// The clean-up cards built from the last scan. Pruned in place as items are removed.
    var insights: [Insight] = []
    /// Paths ticked on the Clean up screen.
    var insightSelection = Set<String>()

    // MARK: - Duplicates: state
    // Folders to search, the size threshold, search progress, and the groups found with what is ticked for removal.

    /// Whether a search or load has not started, is running, or has finished (it may still have found nothing).
    /// Shared by the duplicate, photo, clear-out and app-list screens.
    enum DupState { case idle, working, done }
    /// Folders the duplicate search covers. Starts as the usual personal folders that exist; the user can add more.
    var dupFolders: [URL] = [] { didSet { persistSettings() } }
    /// Files smaller than this (1 MB by default) are ignored, so the search stays fast and the results worthwhile.
    var dupMinSize: Int64 = 1 << 20 { didSet { persistSettings() } }
    var dupState: DupState = .idle
    var dupProgress = DupProgress()
    /// The group open in the side-by-side compare sheet, if any.
    var dupCompare: DupGroup?
    /// Sets of identical files found by the last search.
    var dupGroups: [DupGroup] = []
    /// Paths ticked for removal. `setDuplicate` keeps at least one copy per group unticked.
    var dupSelection = Set<String>()
    /// Held so `cancelDuplicates()` can stop the running search.
    private var dupFinder: DuplicateFinder?

    // MARK: - Similar photos: state
    // The photo source (folders or the Photos library), strictness, progress, and the sets found.

    /// Where similar photos are looked for: ordinary folders, or the Photos library through PhotoKit.
    enum PhotoSourceKind: String, CaseIterable, Identifiable {
        case folders = "Folders"
        case library = "Photos library"
        var id: String { rawValue }
    }
    /// The source chosen on the Similar photos screen.
    var photoSourceKind: PhotoSourceKind = .folders { didSet { persistSettings() } }
    /// Photos permission. Re-read whenever the app becomes active, because the user can change it in System Settings.
    var photoAuth: PHAuthorizationStatus = LibrarySource.authorization
    /// Folders searched when the source is `.folders`.
    var photoFolders: [URL] = [] { didSet { persistSettings() } }
    /// How alike photos must be to be grouped.
    var photoStrictness: Strictness = .balanced { didSet { persistSettings() } }
    var photoState: DupState = .idle
    var photoProgress = PhotoProgress()
    /// Sets of near-identical photos found by the last search, each with a suggested best photo.
    var photoGroups: [SimilarGroup] = []
    /// Photos ticked for removal: file paths, or `photos://` asset keys for library photos.
    var photoSelection = Set<String>()
    /// The set open in the side-by-side compare sheet, if any.
    var photoCompare: SimilarGroup?
    /// Held so `cancelPhotos()` can stop the running search.
    private var photoFinder: SimilarPhotoFinder?

    // MARK: - Photo clear-outs: state
    // Screenshots, burst extras and text photos from the Photos library (library only), and what is ticked.

    var clearoutState: DupState = .idle
    var clearoutProgress = ClearoutProgress()
    /// Every candidate found, across all kinds; filter with `clearouts(of:)`.
    var clearouts: [ClearoutPhoto] = []
    var clearoutSelection = Set<String>()
    /// Held so `cancelClearouts()` can stop the running search.
    private var clearoutFinder: PhotoClearoutFinder?

    // MARK: - Over time: state

    // Space over time. `trend` is the on-disk store; the arrays mirror it so SwiftUI can observe changes.
    let trend = ScanHistoryStore()
    var scanRecords: [ScanRecord] = []
    var drivePoints: [DrivePoint] = []

    // MARK: - Uninstall: state
    // The installed-app list, the selected app with its leftover files, and what is ticked for removal.

    /// Progress of building the installed-app list.
    var appsState: DupState = .idle
    var apps: [InstalledApp] = []
    /// The app whose leftovers are being reviewed.
    var selectedApp: InstalledApp?
    /// Files and folders (preferences, caches, containers…) that belong to `selectedApp`.
    var leftovers: [Leftover] = []
    /// True while `leftovers` is still being searched for.
    var leftoversLoading = false
    /// Paths (app bundle and leftovers) marked for removal for the selected app.
    var uninstallSelection = Set<String>()
    /// Cancels the app-list build.
    private var appsCancel: CancelFlag?
    /// Cancels the leftover search for the previously selected app when another is chosen.
    private var leftoverCancel: CancelFlag?

    /// Every other installed app's identifier: the uninstall matcher must never claim a sibling product's files.
    private func otherBundleIDs(than app: InstalledApp) -> Set<String> {
        Set(apps.filter { $0.path != app.path }.compactMap(\.bundleID))
    }

    // MARK: - Report
    // The written summary of a scan, produced on this Mac by `AIReport`.

    /// The report text (simple Markdown), or nil before one is written. Cleared when a new scan starts.
    var aiReport: String?
    /// Whether Apple's on-device model or Reclaim's built-in writer produced `aiReport`.
    var aiReportSource: ReportSource?
    /// True while a report is being written.
    var aiReportWriting = false

    /// Writes the report from the current scan, unless one is already being written.
    ///
    /// The facts are gathered into a `ReportFacts` snapshot first, so the report describes the state at the moment the
    /// button was pressed. Only that short list of facts goes to `AIReport`, never file contents.
    func writeReport() {
        guard !aiReportWriting else { return }
        aiReportWriting = true
        let facts = ReportFacts.build(
            volume: volume, report: report, insights: insights, apps: apps,
            duplicateBytes: dupGroups.reduce(0) { $0 + $1.reclaimable },
            similarBytes: photoGroups.reduce(0) { $0 + $1.reclaimable },
            clearoutCount: clearouts.count, home: home,
            trend: comparison(.previous), freedByReclaim: comparison(.previous).map { freed(between: $0.older, and: $0.newer) } ?? 0)
        Task {
            let result = await AIReport.write(facts: facts)
            aiReport = result.text
            aiReportSource = result.source
            aiReportWriting = false
        }
    }

    // MARK: - Homebrew
    // Flow: a card's Run button calls `requestBrew` -> `BrewSheet` shows the exact command -> the user presses Run
    // -> `runBrew` executes it and streams the output. Nothing runs without that confirmation.

    /// Where the Homebrew sheet is: waiting for approval, running, or done with an exit status.
    enum CommandState { case confirming, running, finished(Int32) }
    /// The command shown in the sheet; the sheet is presented while this is non-nil.
    var brewRequest: BrewCommand?
    var brewState: CommandState = .confirming
    /// Everything the command has printed so far.
    var brewOutput = ""
    /// Whether Homebrew is installed, which decides whether a command box offers a Run button.
    var brewAvailable: Bool { CommandRunner.brewPath() != nil }

    /// Opens the confirmation sheet for a Homebrew command. Nothing runs yet.
    ///
    /// Commands come from `BrewCommand.parse`, which accepts only the allow-listed subcommands (cleanup, autoremove,
    /// uninstall) and rejects anything with shell metacharacters.
    func requestBrew(_ command: BrewCommand) {
        brewOutput = ""
        brewState = .confirming
        brewRequest = command
    }

    /// Runs the command shown in the sheet and streams its output. Only acts in the `.confirming` state, so a double
    /// click cannot start it twice. The command runs as an argument array, never through a shell.
    func runBrew() {
        guard let command = brewRequest, case .confirming = brewState else { return }
        brewState = .running
        actionLogger.info("running \(command.display, privacy: .public)")
        Task {
            // Output can arrive from a background thread, so it is appended on the main actor.
            let status = await CommandRunner.runBrew(command.arguments) { text in
                Task { @MainActor in self.brewOutput += text }
            }
            // A nil status means Homebrew wasn't found; 127 is the shell's usual "command not found" code.
            brewState = .finished(status ?? 127)
            if status == nil { brewOutput += "Homebrew isn't installed at /opt/homebrew or /usr/local.\n" }
            refreshVolume()
            // Uninstalling a cask changes what is installed, so the Uninstall list is rebuilt.
            if command.arguments.first == "uninstall" { loadApps() }
        }
    }

    /// True while Homebrew's dry run is running for the preview.
    var brewPreviewing = false

    /// Runs the command with Homebrew's own `--dry-run` and shows the output in the sheet. Nothing is removed, the
    /// sheet stays on the approval step, and nothing is logged as an action.
    func previewBrew() {
        guard let command = brewRequest, case .confirming = brewState, !brewPreviewing,
              let arguments = command.previewArguments else { return }
        brewPreviewing = true
        brewOutput = "Preview only. Nothing is removed.\n$ brew \(arguments.joined(separator: " "))\n\n"
        Task {
            let status = await CommandRunner.runBrew(arguments) { text in
                Task { @MainActor in self.brewOutput += text }
            }
            if status == nil { brewOutput += "Homebrew isn't installed at /opt/homebrew or /usr/local.\n" }
            else if brewOutput.hasSuffix("\n\n") { brewOutput += "Nothing to remove.\n" }
            brewPreviewing = false
        }
    }

    /// Closes the sheet. Ignored while the command is running, so a running command can't be left unattended.
    func dismissBrew() {
        if case .running = brewState { return }
        brewRequest = nil
    }

    // MARK: - Actions: state
    // The undo record, the pending approval request and the message toast.

    /// The request awaiting approval. `ContentView` shows the confirmation sheet while this is non-nil.
    var trashRequest: TrashRequest?
    /// The undo record: a copy of `ActionLog.entries`, refreshed after every action.
    var history: [HistoryEntry] = []
    /// The message at the bottom of the window. `ContentView` removes it after a delay.
    var toast: Toast?

    /// A short result message, optionally with an Undo button and shortcuts to the relevant macOS settings.
    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        /// History entries the Undo button puts back; empty means no Undo button.
        let undoIDs: [UUID]
        var isProblem = false
        /// Offer a button that opens the macOS privacy settings Reclaim may need.
        var offersSettings = false
        /// Offer a button that opens the Photos app (where Recently Deleted lives).
        var opensPhotos = false
    }

    /// Shows a result message. `problem` makes it linger longer and look like a warning.
    func showToast(_ text: String, undo: [UUID] = [], problem: Bool = false, settings: Bool = false, photos: Bool = false) {
        toast = Toast(text: text, undoIDs: undo, isProblem: problem, offersSettings: settings, opensPhotos: photos)
    }

    /// Puts back everything from a toast's Undo button.
    func undo(_ ids: [UUID]) {
        let log = self.log
        toast = nil
        // Items kept in iCloud only are put back by downloading again; trashed ones are restored from the Trash.
        let evicted = Set(history.filter { $0.status == .evicted }.map(\.id))
        Task {
            let results = await runBlocking { ids.map { evicted.contains($0) ? log.redownload($0) : log.restore($0) } }
            history = log.entries
            let failed = results.compactMap { $0 }
            refreshVolume()
            showToast(failed.isEmpty ? "Put back \(ids.count) item\(ids.count == 1 ? "" : "s")." : failed[0])
        }
    }

    // MARK: - Services and setup

    let home = NSHomeDirectory()
    let log = ActionLog()
    /// The running scanner, kept so `cancelScan()` can reach it.
    private var scanner: DiskScanner?
    /// The task that drives the current scan.
    private var scanTask: Task<Void, Never>?

    /// Loads saved settings, history and trend data, and starts watching for drives being mounted and permissions changing.
    init() {
        customFolders = (UserDefaults.standard.stringArray(forKey: "customFolders") ?? []).map { URL(fileURLWithPath: $0) }
        applySettings(Preferences.load())
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        // Keep the list of external drives current as they are plugged in or ejected.
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
        scanRecords = trend.scans
        drivePoints = trend.drive
        noteDrive()
        refreshHistory()
        refreshSystemInfo()
    }

    // MARK: - Over time
    // Records free space and scans for the Over time screen, and compares scans.

    /// Re-reads the drive's free space and, if it is time (see `ScanHistoryStore.shouldRecordDrive`), stores a point
    /// for the Over time chart. Called at launch and whenever something Reclaim did changes free space.
    func noteDrive() {
        let v = VolumeInfo.current()
        if trend.recordDrive(total: v.total, free: v.available) { drivePoints = trend.drive }
    }

    /// Refreshes the cached drive figures and also records a free-space point for the trend chart.
    ///
    /// Called after anything that changes free space, so the Over time timeline fills in between scans without a
    /// separate timer. `noteDrive()` decides whether a point is actually stored. Always use this rather than assigning
    /// `volume` directly, or the chart misses the reading.
    ///
    private func refreshVolume() {
        volume = VolumeInfo.current()
        noteDrive()
    }

    /// Compares the latest whole-disk scan with an earlier one. Nil until there are two scans.
    func comparison(_ baseline: TrendBaseline = .previous) -> ScanComparison? {
        guard let latest = scanRecords.max(by: { $0.date < $1.date }),
            let older = baseline.choose(for: latest, in: scanRecords)
        else { return nil }
        return ScanComparison(older: older, newer: latest)
    }

    /// Bytes Reclaim itself freed between two scans (from the action log).
    func freed(between older: ScanRecord, and newer: ScanRecord) -> Int64 {
        freedByReclaim(history, from: older.date, to: newer.date)
    }

    /// Deletes the saved scans and free-space readings (not any user files).
    func clearTrend() {
        trend.clear()
        scanRecords = []
        drivePoints = []
        noteDrive()
    }

    // MARK: - History, drives and scan folders
    // Re-reading persisted and system state: the undo record, mounted drives, user-added scan folders and APFS facts.

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

    /// Rebuilds the list of external drives from what is mounted now.
    func refreshVolumes() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        externalVolumes = urls.filter { url in
            url.path.hasPrefix("/Volumes/") && url.resolvingSymlinksInPath().path != "/"
        }
    }

    // MARK: - Remembered settings

    /// Saves the remembered choices. Called from the `didSet` of each one, but not while `applySettings` is loading.
    private func persistSettings() {
        guard !loadingSettings else { return }
        Preferences.save(Settings(
            dupFolders: dupFolders, dupMinSize: dupMinSize, photoSource: photoSourceKind.rawValue,
            photoFolders: photoFolders, photoStrictness: photoStrictness))
    }

    /// True while saved values are being copied in, so loading doesn't write them straight back.
    private var loadingSettings = false

    /// Copies loaded or default settings into the observable properties.
    private func applySettings(_ settings: Settings) {
        loadingSettings = true
        dupFolders = settings.dupFolders
        dupMinSize = settings.dupMinSize
        photoSourceKind = PhotoSourceKind(rawValue: settings.photoSource) ?? .folders
        photoFolders = settings.photoFolders
        photoStrictness = settings.photoStrictness
        loadingSettings = false
    }

    /// Forgets the saved choices and goes back to the defaults (the usual personal folders, 1 MB, balanced).
    func resetSettings() {
        Preferences.reset()
        applySettings(Settings.defaults())
    }

    /// Lets the user pick a folder or drive to scan, remembers it, and makes it the current target.
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

    /// Forgets a folder the user added; falls back to the whole disk if it was the selected target.
    func removeCustomFolder(_ url: URL) {
        customFolders.removeAll { $0 == url }
        UserDefaults.standard.set(customFolders.map(\.path), forKey: "customFolders")
        if target == .folder(url) { target = .disk }
    }

    /// Re-reads the APFS container, snapshots, free space and Full Disk Access state off the main thread.
    func refreshSystemInfo() {
        Task {
            let (c, s) = await runBlocking { (SystemInfo.apfsContainer(), SystemInfo.localSnapshots()) }
            container = c
            snapshots = s
            refreshVolume()
            fullDiskAccess = await runBlocking { SystemInfo.hasFullDiskAccess() }
        }
    }

    // MARK: - Scanning
    // Starting, cancelling and finishing a scan, and turning its tree into a report and clean-up cards.

    /// Scans `target`, then builds the report and clean-up cards from the result. Does nothing if a scan is already running.
    ///
    /// The scan only reads. Old results are cleared first so the screens never mix two scans. Only a whole-disk scan is
    /// recorded in the Over time history.
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

        // Progress is polled on a timer rather than pushed per file, so the scanner never has to call into the main actor for each one.
        scanTask = Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    self.progress = scanner.snapshot()
                    self.scanSeconds = Date().timeIntervalSince(started)
                }
            }
            // The APFS queries don't depend on the walk, so they run alongside it.
            async let system = runBlocking { (SystemInfo.apfsContainer(), SystemInfo.localSnapshots()) }
            let node = await scanner.scan(root: url)
            let (c, s) = await system
            poller.cancel()

            container = c ?? container
            snapshots = s
            refreshVolume()
            scanSeconds = Date().timeIntervalSince(started)
            fullDiskAccess = await runBlocking { SystemInfo.hasFullDiskAccess() }
            progress = scanner.snapshot()

            // A cancelled scan leaves no results behind (root and report stay nil).
            if !scanner.isCancelledPublic {
                // Classifying and card-building walk the whole tree, so they run off the main actor too.
                let cats = await runBlocking { SpaceClassifier.breakdown(root: node, home: home) }
                let found = await runBlocking { InsightEngine(home: home).generate(from: node) }
                // If the APFS query failed, the volume figures are enough to build a report.
                let fallback = APFSContainerInfo(ceiling: volume.total, free: volume.available, volumes: [])
                root = node
                scannedTarget = scanTarget
                insights = found
                let finished = SpaceReport(
                    container: container ?? fallback, snapshots: snapshots, categories: cats,
                    scannedBytes: node.size, unreadable: scanner.unreadablePaths, purgeable: volume.purgeable,
                    scannedWholeDisk: wholeDisk)
                report = finished
                // Only whole-disk scans are comparable over time; folder scans say nothing about the drive.
                if wholeDisk {
                    trend.record(ScanRecord(report: finished))
                    scanRecords = trend.scans
                    noteDrive()
                }
            }
            isScanning = false
        }
    }

    /// Asks the running scan to stop. `startScan` then discards the partial result.
    func cancelScan() { scanner?.cancel() }

    // MARK: - Duplicates: actions

    /// Searches `dupFolders` for identical files. Read-only; the groups appear in `dupGroups`.
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
            // The finder reports progress from background threads; publish it on the main actor.
            let groups = await finder.find(roots: folders, minSize: minSize) { p in
                Task { @MainActor in self.dupProgress = p }
            }
            dupGroups = groups
            dupState = .done
        }
    }

    /// Stops the running duplicate search.
    func cancelDuplicates() { dupFinder?.cancel() }

    /// Lets the user add folders to the duplicate search.
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

    // MARK: - Similar photos: actions

    /// Searches the chosen source for sets of similar photos. Read-only; sets appear in `photoGroups`.
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

    /// Stops the running photo search.
    func cancelPhotos() { photoFinder?.cancel() }

    /// Asks macOS for Photos access (the system shows its own prompt) and stores the answer.
    func requestPhotoAccess() {
        Task { photoAuth = await LibrarySource.requestAccess() }
    }

    /// Re-reads the Photos permission, which the user may have changed in System Settings.
    func refreshPhotoAuth() { photoAuth = LibrarySource.authorization }

    /// Whether the library can be searched: full or limited Photos access.
    var canSearchLibrary: Bool { photoAuth == .authorized || photoAuth == .limited }

    /// Opens System Settings at the Photos privacy page.
    func openPhotosPrivacySettings() { openPrivacyPane("Privacy_Photos") }

    // MARK: - Uninstall: actions

    /// Builds the installed-app list (cancellable). If the selected app has gone, the selection is cleared.
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

    /// Stops building the app list.
    func cancelApps() { appsCancel?.cancel() }

    /// Whether the app is open right now; the Uninstall screen warns about running apps.
    func isRunning(_ app: InstalledApp) -> Bool { AppInventory.isRunning(app) }

    /// Selects an app and searches for its leftover files.
    ///
    /// Choosing another app cancels the earlier search, and a result that arrives after the selection has moved on is dropped.
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
            // Both guards drop the result if a newer inspection has started or the user has picked another app.
            guard !flag.isCancelled else { return }
            guard selectedApp == app else { return }
            leftovers = found
            // Everything removable starts selected; the user unticks what to keep. Admin-only files can't be.
            uninstallSelection = Set([app.path] + found.filter { !$0.needsAdmin }.map(\.path))
            leftoversLoading = false
        }
    }

    /// Total size of the ticked parts of the selected app.
    var uninstallBytes: Int64 {
        guard let app = selectedApp else { return 0 }
        var total: Int64 = uninstallSelection.contains(app.path) ? app.size : 0
        for l in leftovers where uninstallSelection.contains(l.path) { total += l.size }
        return total
    }

    /// Builds the approval sheet for the ticked parts of the selected app.
    ///
    /// Leftovers are checked against the narrower uninstall rule (`SafetyPolicy.verdict(forPath:uninstalling:)`); any
    /// that fail appear as blocked. The scope travels with the request so `ActionLog` applies the same rule when moving.
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

    // MARK: - Photo clear-outs: actions

    /// Searches the Photos library for screenshots, burst extras and text photos. Read-only.
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

    /// Stops the running clear-out search.
    func cancelClearouts() { clearoutFinder?.cancel() }

    /// The candidates of one kind.
    func clearouts(of kind: ClearoutKind) -> [ClearoutPhoto] { clearouts.filter { $0.kind == kind } }

    /// Ticks every candidate of a kind that Reclaim is allowed to remove, optionally only those at least `days` old.
    /// When an age is given, photos with no known date are skipped.
    func selectClearouts(_ kind: ClearoutKind, olderThanDays days: Int? = nil) {
        let now = Date()
        for c in clearouts(of: kind) where canTrash(c.photo.path) {
            if let days, let age = c.ageInDays(now: now), age < days { continue }
            if days != nil, c.ageInDays(now: now) == nil { continue }
            clearoutSelection.insert(c.photo.path)
        }
    }

    /// Unticks every candidate of a kind.
    func clearClearoutSelection(_ kind: ClearoutKind) {
        for c in clearouts(of: kind) { clearoutSelection.remove(c.photo.path) }
    }

    // MARK: - Photo removal and selection helpers
    // Turning ticks on screen into approval requests, and "select the extras" helpers that always keep one item per set.

    /// Builds the approval sheet for photos chosen on the Similar photos screen (files or library assets).
    func requestPhotoRemoval(_ photos: [PhotoInfo], reason: String) {
        if photos.allSatisfy(\.isAsset) {
            let entries = photos.map { TrashRequest.Entry(path: $0.path, name: $0.name, size: $0.size, blockedReason: nil) }
            trashRequest = TrashRequest(kind: .photosLibrary, reason: reason, entries: entries)
        } else {
            // A mixed selection can't be one request (Photos and the Trash have different confirmations), so only the
            // files go ahead, and the user is told the library photos were left alone rather than silently dropped.
            let skipped = photos.filter(\.isAsset).count
            if skipped > 0 {
                showToast("\(skipped) Photos library item\(skipped == 1 ? " was" : "s were") left out. Remove those separately.", problem: true)
            }
            requestTrash(photos.filter { !$0.isAsset }.map { ($0.path, $0.size) }, reason: reason)
        }
    }

    /// Deletes approved library photos through PhotoKit, which shows its own confirmation. They go to Recently Deleted,
    /// and the screens' selections and results are updated afterwards.
    private func deleteFromPhotos(_ request: TrashRequest) {
        let ids = request.allowed.compactMap { PhotoInfo.assetID(fromKey: $0.path) }
        let log = self.log
        Task {
            do {
                try await LibrarySource.delete(assetIDs: ids)
            // The user declined Photos' own prompt, so nothing changed and nothing is recorded.
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

    /// Removes moved photos from each set. A set left with fewer than two photos is no longer a set and is dropped. If
    /// the suggested photo was removed, the first remaining one becomes the suggestion and the old reasons are cleared.
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

    /// Lets the user add folders to the similar-photo search.
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

    /// Ticks every photo except each set's suggested best (only those Reclaim may remove).
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

    /// Unticks every photo in one set.
    func clearPhotoSelection(in group: SimilarGroup) {
        for p in group.photos { photoSelection.remove(p.path) }
    }

    /// Ticks or unticks one photo. Refuses to tick the last unticked photo, so a set always keeps one.
    func setPhoto(_ photo: PhotoInfo, in group: SimilarGroup, selected: Bool) {
        if selected {
            let kept = group.photos.filter { $0.path != photo.path && !photoSelection.contains($0.path) }.count
            guard kept >= 1 else { return }
            photoSelection.insert(photo.path)
        } else {
            photoSelection.remove(photo.path)
        }
    }

    /// Whether a path could be removed: library photos need full (not limited) Photos access; files must pass `SafetyPolicy`.
    /// Screens use it to avoid offering items that would only be refused later.
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

    /// Ticks or unticks one copy. Refuses to tick the last unticked copy, so a group always keeps one.
    func setDuplicate(_ file: DupFile, in group: DupGroup, selected: Bool) {
        if selected {
            let stillKept = group.files.filter { $0.path != file.path && !dupSelection.contains($0.path) }.count
            guard stillKept >= 1 else { return }
            dupSelection.insert(file.path)
        } else {
            dupSelection.remove(file.path)
        }
    }

    // MARK: - Actions: trash, evict, restore and purge
    // Everything that changes files. Each `request...` method only builds a `TrashRequest`; the change happens in `confirmTrash`.

    /// Builds the approval sheet for moving files to the Trash.
    ///
    /// Every path is checked against `SafetyPolicy` again here, even though screens already avoid offering protected
    /// items, so the sheet is authoritative: refused items stay in the request with their reason and are listed
    /// separately as ones Reclaim won't touch. `ActionLog` checks again when the move happens.
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
            let blocked = CloudEvict.status(of: item.path).refusal
            return TrashRequest.Entry(path: item.path, name: (item.path as NSString).lastPathComponent, size: item.size, blockedReason: blocked)
        }
        trashRequest = TrashRequest(kind: .cloudEvict, reason: reason, entries: entries)
    }

    /// Removes the local copies of approved iCloud items and updates the clean-up cards to match.
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
                return Insight(id: insight.id, title: insight.title, summary: insight.summary, icon: insight.icon,
                               category: insight.category, risk: insight.risk, items: remaining,
                               totalBytes: remaining.reduce(0) { $0 + $1.size }, command: insight.command, advice: insight.advice,
                               partial: insight.partial, action: .evict)
            }
            insightSelection.subtract(done)
            refreshVolume()
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

    /// Downloads an item that was kept in iCloud only, from the Undo screen.
    func redownload(_ entry: HistoryEntry) {
        let log = self.log
        Task {
            let error = await runBlocking { log.redownload(entry.id) }
            history = log.entries
            showToast(error ?? "Downloading \((entry.originalPath as NSString).lastPathComponent) from iCloud again.")
        }
    }

    /// Carries out an approved request. This is the single point where a user's approval becomes a change.
    ///
    /// Routes on `request.kind`: library photos go to PhotoKit, iCloud items to eviction, and files to `ActionLog.trash`.
    /// Afterwards every list that might still show the moved items (cards, duplicate and photo sets, uninstall lists)
    /// is pruned, so the screens stop offering things that are already gone.
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
        // Only allowed entries are passed on; blocked ones never reach the log.
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
                // A permission failure gets its own message pointing at the two privacy panes that can cause it.
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
            refreshVolume()
        }
    }

    /// Puts one trashed item back where it came from.
    func restore(_ entry: HistoryEntry) {
        let log = self.log
        Task {
            let error = await runBlocking { log.restore(entry.id) }
            history = log.entries
            showToast(error ?? "Put back \((entry.originalPath as NSString).lastPathComponent).")
        }
    }

    /// Permanently deletes items Reclaim earlier moved to the Trash, so their space comes back. This is the one step
    /// that cannot be undone, and it only runs when the user chooses it on the Undo screen.
    func purge(_ ids: Set<UUID>) {
        let log = self.log
        Task {
            let result = await runBlocking { log.purge(ids) }
            history = log.entries
            refreshVolume()
            showToast("Freed \(ByteFormat.string(result.freed)) for good."
                + (result.failures.isEmpty ? "" : " \(result.failures.count) item(s) failed."))
        }
    }

    // MARK: - Helpers
    // Small wrappers around AppKit: Finder, System Settings, relaunching and the clipboard.

    /// Shows the item in Finder.
    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens System Settings at Full Disk Access.
    func openFullDiskAccessSettings() { openPrivacyPane("Privacy_AllFiles") }
    /// Opens System Settings at Files and Folders.
    func openFilesAndFoldersSettings() { openPrivacyPane("Privacy_FilesAndFolders") }

    /// Opens a pane of System Settings' Privacy & Security page by its anchor name.
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

    /// Puts text on the clipboard (used by the command boxes).
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Lets `AppModel` read the scanner's cancelled state under a name that is clear at the call site.
extension DiskScanner {
    var isCancelledPublic: Bool { cancelledFlag }
}

/// Library photos are identified by a `photos://` key in place of a path.
extension PhotoInfo {
    /// The PhotoKit local identifier inside an asset key, or nil if the key is an ordinary file path.
    static func assetID(fromKey key: String) -> String? {
        key.hasPrefix(PhotoItem.assetPrefix) ? String(key.dropFirst(PhotoItem.assetPrefix.count)) : nil
    }
}
