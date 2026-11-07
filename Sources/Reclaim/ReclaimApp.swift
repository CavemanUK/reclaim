// App entry point: the window, the sidebar and detail switch, the shared sheets and toast, and the developer
// diagnostics (`CLIScan`). All state lives in `AppModel`; this file only wires screens to it.
// Diagnostics run only when `RECLAIM_DEV=1` is set, so a normal launch can never trigger them.

import AppKit
import SwiftUI

/// The application. Owns the one `AppModel` and shows `ContentView` in a single window.
@main
struct ReclaimApp: App {
    /// Created once and shared with every screen through the SwiftUI environment.
    @State private var model = AppModel()

    init() {
        // Developer diagnostics (`Reclaim --scan /path`, `--dups`, `--photos`, …) run and exit without a window.
        // They are reachable only with RECLAIM_DEV=1 in the environment, so a normal launch can never trigger them.
        // This runs in `init`, which executes before the scene (and so any window) is created. Each `CLIScan` function
        // ends with `exit`, so a diagnostic run finishes without a window ever appearing.
        let args = CommandLine.arguments
        guard ProcessInfo.processInfo.environment["RECLAIM_DEV"] == "1" else { return }
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            CLIScan.run(path: args[i + 1], out: out)
        }
        if args.contains("--selftest-trash") { CLIScan.trashSelfTest() }
        if let i = args.firstIndex(of: "--probe-dir"), let o = args.firstIndex(of: "--out"),
            i + 1 < args.count, o + 1 < args.count
        {
            CLIScan.probe(dir: args[i + 1], out: args[o + 1])
        }
        if args.contains("--apps") { CLIScan.apps() }
        if args.contains("--trend-check") { CLIScan.trendCheck() }
        if let i = args.firstIndex(of: "--trash-file"), let o = args.firstIndex(of: "--out"), i + 1 < args.count, o + 1 < args.count {
            CLIScan.trashFile(path: args[i + 1], out: args[o + 1], restore: args.contains("--restore"))
        }
        if args.contains("--evict-test") { CLIScan.evictTest() }
        if let o = args.firstIndex(of: "--report"), o + 1 < args.count { CLIScan.report(out: args[o + 1]) }
        if let o = args.firstIndex(of: "--clearouts"), o + 1 < args.count {
            CLIScan.clearouts(out: args[o + 1])
        }
        if let o = args.firstIndex(of: "--library"), o + 1 < args.count {
            CLIScan.library(out: args[o + 1], strict: args.count > o + 2 ? args[o + 2] : "balanced")
        }
        if let i = args.firstIndex(of: "--photos"), i + 1 < args.count {
            CLIScan.photos(path: args[i + 1], strict: args.count > i + 2 ? args[i + 2] : "balanced")
        }
        if let i = args.firstIndex(of: "--dups"), i + 1 < args.count {
            CLIScan.dups(path: args[i + 1])
        }
    }

    /// A single resizable window; the minimum size keeps the sidebar and detail screen usable.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)
    }
}

/// The root view: the sidebar, the screen for the selected item, and the sheets and toast that any screen can trigger
/// by setting `trashRequest`, `brewRequest` or `toast` on the model.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Whether the first-run welcome sheet has been dismissed (stored in UserDefaults).
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        // Gives `$model.selection` and the sheet bindings a writable path into the environment's model.
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Your Mac") {
                    ForEach([SidebarItem.overview, .map, .overTime, .suggestions]) { sidebarRow($0) }
                }
                Section("Find") {
                    ForEach([SidebarItem.duplicates, .photos, .clearouts]) { sidebarRow($0) }
                }
                Section("Apps") {
                    sidebarRow(.apps)
                }
                Section("History") {
                    sidebarRow(.history)
                        .badge(model.history.filter { $0.status == .trashed }.count)
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                Label("Reclaim only looks. Nothing changes until you say so.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
            }
        } detail: {
            switch model.selection ?? .overview {
            case .overview: OverviewView()
            case .map: SpaceMapView()
            case .overTime: OverTimeView()
            case .suggestions: SuggestionsView()
            case .duplicates: DuplicatesView()
            case .photos: SimilarPhotosView()
            case .clearouts: ClearoutsView()
            case .apps: AppsView()
            case .history: HistoryView()
            }
        }
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeSheet { hasSeenWelcome = true }
        }
        .sheet(item: $model.trashRequest) { request in
            TrashConfirmSheet(request: request)
        }
        .sheet(item: $model.brewRequest) { command in
            BrewSheet(command: command)
                .interactiveDismissDisabled({ if case .running = model.brewState { return true } else { return false } }())
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Keyed on the toast's id so a newer message restarts the timer; problems stay up longer so they can be read.
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.isProblem ? 40 : 14))
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
            }
        }
        .animation(.snappy, value: model.toast?.id)
    }
}

/// The first-run sheet that states the safety promises before anything is scanned.
struct WelcomeSheet: View {
    /// Called when the user presses Get started.
    let done: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.pie.fill").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(.linearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                .shadow(color: .purple.opacity(0.35), radius: 12, y: 5)
            Text("Welcome to Reclaim").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Find out exactly what is using your drive, and get the space back safely.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                point("eye", "Reclaim only looks", "Scanning only reads file sizes. Nothing is changed.")
                point("hand.raised", "You approve everything", "Every change shows you the exact files first.")
                point("trash", "Always undoable", "Items go to the Trash, with a Put back button in History.")
                point("lock.shield", "Protected places stay protected", "System files, app bundles and Photos libraries are never touched.")
            }
            .padding(.vertical, 6)
            Button("Get started", action: done)
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(34)
        .frame(width: 520)
    }

    /// One icon-and-text line of the welcome sheet.
    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

extension ContentView {
    /// A sidebar row for an item. The `.tag` is what makes the list's selection binding work.
    fileprivate func sidebarRow(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.icon).foregroundStyle(item.color)
        }
        .padding(.vertical, 2)
        .tag(item)
    }

}

/// The result message shown over the bottom of the window.
///
/// Depending on the toast it offers Undo, a link to the privacy settings, or a button to open Photos.
struct ToastView: View {
    let toast: AppModel.Toast
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isProblem ? .orange : .green).font(.title3)
            Text(toast.text).font(.callout).frame(maxWidth: 560, alignment: .leading)
            if toast.offersSettings {
                Button("Full Disk Access") { model.openFullDiskAccessSettings() }.buttonStyle(.borderedProminent)
                Button("Files and Folders") { model.openFilesAndFoldersSettings() }
            }
            if !toast.undoIDs.isEmpty {
                Button("Undo") { model.undo(toast.undoIDs) }.buttonStyle(.borderedProminent)
            }
            if toast.opensPhotos {
                Button("Open Photos") { LibrarySource.openPhotosApp() }
            }
            Button { model.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(radius: 12, y: 4)
    }
}

/// The approval sheet every change goes through. It lists exactly what will be affected and the size, lists refused
/// items separately, and words its explanation and button for the request's `kind` (Trash, Photos, or iCloud only).
/// The confirm button calls `AppModel.confirmTrash(_:)`; nothing has changed before that.
struct TrashConfirmSheet: View {
    let request: TrashRequest
    @Environment(AppModel.self) private var model
    /// Set by the Preview button: what each item would do, worked out without changing anything.
    @State private var preview: [String: PreviewLine]?
    @State private var previewing = false

    /// Library photos: the wording says Photos will ask again and that recovery happens inside Photos.
    private var isPhotos: Bool { request.kind == .photosLibrary }
    /// Keep in iCloud only: the wording says nothing is deleted and the files stay in iCloud.
    private var isEvict: Bool { request.kind == .cloudEvict }

    var body: some View {
        let n = request.allowed.count
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: isPhotos ? "photo.on.rectangle.angled" : (isEvict ? "icloud.and.arrow.up.fill" : "trash.circle.fill"))
                    .font(.system(size: 40)).foregroundStyle(isEvict ? .cyan : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPhotos ? "Delete \(n) photo\(n == 1 ? "" : "s") from your Photos library?"
                                  : (isEvict ? "Keep \(n) item\(n == 1 ? "" : "s") in iCloud only?"
                                             : "Move \(n) item\(n == 1 ? "" : "s") to the Trash?"))
                        .font(.title2.bold())
                    Text("That is \(ByteFormat.string(request.totalBytes)). \(request.reason)")
                        .foregroundStyle(.secondary)
                }
            }

            if preview != nil {
                Label("Preview only. Nothing has been changed.", systemImage: "eye")
                    .font(.callout.weight(.semibold)).foregroundStyle(.teal)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.teal.opacity(0.14), in: Capsule())
            }

            List {
                ForEach(request.allowed) { entry in
                    HStack(spacing: 10) {
                        if let id = PhotoInfo.assetID(fromKey: entry.path) {
                            AssetImage(assetID: id, side: 28)
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            if !isPhotos {
                                Text(((entry.path as NSString).deletingLastPathComponent).replacingOccurrences(of: model.home, with: "~"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if let line = preview?[entry.path] { previewRow(line) }
                        }
                        Spacer()
                        Text(ByteFormat.string(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if !request.blocked.isEmpty {
                    Section("Reclaim won't touch these") {
                        ForEach(request.blocked) { entry in
                            VStack(alignment: .leading) {
                                Text((entry.path as NSString).lastPathComponent).lineLimit(1)
                                Text(entry.blockedReason ?? "").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            Label(isPhotos
                  ? "Photos will ask you to confirm as well. The photos go to Recently Deleted in Photos, where you can recover them for about 30 days. Reclaim can't put them back itself."
                  : (isEvict
                     ? "Nothing is deleted. Only the copy on this Mac is removed; the files stay in iCloud and download again when you open them (you'll need internet). Undo offers Download again."
                     : "Nothing is deleted. You can put everything back from Undo. The space only comes back once the Trash is emptied."),
                  systemImage: isEvict ? "icloud" : "arrow.uturn.backward.circle")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                if !isPhotos {
                    Button {
                        if preview != nil { preview = nil } else { runPreview() }
                    } label: {
                        Label(preview != nil ? "Hide preview" : "Preview", systemImage: "eye")
                    }
                    .controlSize(.large).disabled(previewing || request.allowed.isEmpty)
                    .help("Shows exactly what would happen to each item, without changing anything")
                }
                Spacer()
                Button("Not now", role: .cancel) { model.trashRequest = nil }
                    .keyboardShortcut(.cancelAction).controlSize(.large)
                Button(isPhotos ? "Delete from Photos" : (isEvict ? "Keep in iCloud only" : "Move to Trash")) { model.confirmTrash(request) }
                    .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(request.allowed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 660, height: 520)
    }

    /// One line under an item's name saying what the real run would do.
    @ViewBuilder private func previewRow(_ line: PreviewLine) -> some View {
        switch line.outcome {
        case .wouldAct(let note):
            Label(isEvict ? "Would keep in iCloud only" : "Would move to the Trash", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        case .refused(let why):
            Label("Would be left alone: \(why)", systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
        }
    }

    /// Asks the action log what it would do. The preview functions never move, write or delete anything.
    private func runPreview() {
        let items = request.allowed.map { (path: $0.path, size: $0.size) }
        let log = model.log, scope = request.uninstalling, evict = isEvict
        previewing = true
        Task {
            let lines = await runBlocking { evict ? log.previewEvict(items) : log.previewTrash(items, uninstalling: scope) }
            preview = Dictionary(lines.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            previewing = false
        }
    }
}

/// Headless developer checks, reachable only with `RECLAIM_DEV=1` (see `ReclaimApp.init`). Each function prints or
/// writes a report and exits.
///
/// Several are meant to be run as the installed app (`open -n -W --env RECLAIM_DEV=1 ... --args ...`) because macOS
/// privacy permissions belong to the app, not to the shell. Functions that write files only touch temporary or
/// throwaway paths, except `trashFile`, which moves the one file it is given.
enum CLIScan {
    /// Runs inside the real app process (launch with `open`) so macOS privacy rules apply exactly as they do to users.
    static func probe(dir: String, out: String) {
        var lines: [String] = []
        let fm = FileManager.default
        let file = dir + "/.reclaim-probe.txt"
        lines.append("bundle: \(Bundle.main.bundlePath)")
        lines.append("full disk access: \(SystemInfo.hasFullDiskAccess())")
        lines.append("list dir: \((try? fm.contentsOfDirectory(atPath: dir).count).map(String.init) ?? "DENIED")")
        let created = fm.createFile(atPath: file, contents: Data("probe".utf8))
        lines.append("create probe: \(created)")
        if created {
            var result: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: file), resultingItemURL: &result)
                lines.append("trashItem: OK -> \((result as URL?)?.path ?? "?")")
                if let r = result as URL? { try? fm.removeItem(at: r) }
            } catch {
                lines.append("trashItem: FAILED \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
                let done = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var info = ""
                NSWorkspace.shared.recycle([URL(fileURLWithPath: file)]) { map, err in
                    info = err.map { "FAILED \(($0 as NSError).domain) \(($0 as NSError).code) \($0.localizedDescription)" } ?? "OK \(map.values.first?.path ?? "")"
                    if let r = map.values.first { try? fm.removeItem(at: r) }
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 20)
                lines.append("recycle: \(info)")
            }
            try? fm.removeItem(atPath: file)
        }
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Trash then restore a throwaway file to prove the action log works. Touches only a temp folder in Caches.
    static func trashSelfTest() {
        let dir = NSHomeDirectory() + "/Library/Caches/reclaim-selftest"
        let file = dir + "/probe.txt"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "probe".write(toFile: file, atomically: true, encoding: .utf8)
        let log = ActionLog(fileURL: URL(fileURLWithPath: dir + "/history.json"))
        let r = log.trash([(file, 5)], reason: "self test")
        print("trashed: \(r.done.count) failed: \(r.failed.map(\.message))")
        print("original gone: \(!FileManager.default.fileExists(atPath: file)), in trash: \(r.done.first?.trashPath ?? "nil")")
        if let e = r.done.first {
            print("restore error: \(log.restore(e.id) ?? "none")")
            print("back at original: \(FileManager.default.fileExists(atPath: file))")
        }
        try? FileManager.default.removeItem(atPath: dir)
        exit(0)
    }

    /// Runs a real whole-disk scan through the Over time pipeline using a temporary history file: report → record →
    /// save → reload → compare → report fact. Prints what each step produced.
    static func trendCheck() {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var lines: [String] = []
        Task.detached {
            let home = NSHomeDirectory()
            let scanner = DiskScanner(options: .wholeDisk)
            let root = await scanner.scan(root: URL(fileURLWithPath: "/"))
            let cats = SpaceClassifier.breakdown(root: root, home: home)
            let volume = VolumeInfo.current()
            let container = SystemInfo.apfsContainer() ?? APFSContainerInfo(ceiling: volume.total, free: volume.available, volumes: [])
            let report = SpaceReport(
                container: container, snapshots: SystemInfo.localSnapshots(), categories: cats, scannedBytes: root.size,
                unreadable: scanner.unreadablePaths, purgeable: volume.purgeable, scannedWholeDisk: true)
            let record = ScanRecord(report: report)
            let sum = record.categories.values.reduce(0, +)
            lines.append("record: used \(ByteFormat.string(record.used)) free \(ByteFormat.string(record.free)) hidden \(ByteFormat.string(record.hidden)) categories \(record.categories.count) folders \(record.folders.count)")
            lines.append("categories sum == scannedBytes: \(sum == record.scannedBytes)")
            let file = URL(fileURLWithPath: NSTemporaryDirectory() + "trendcheck-\(UUID().uuidString)/trend.json")
            let store = ScanHistoryStore(fileURL: file)
            store.record(record)
            store.recordDrive(total: record.total, free: record.free)
            let reopened = ScanHistoryStore(fileURL: file)
            lines.append("reloaded: \(reopened.scans.count) scan, \(reopened.drive.count) drive point, file \((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) bytes")
            // A pretend later scan: 3 GB more used, one category 3 GB bigger.
            var bigger = record.categories
            if let first = bigger.keys.sorted().first { bigger[first, default: 0] += 3 << 30 }
            let later = ScanRecord(
                id: UUID(), date: record.date.addingTimeInterval(3 * 86_400), total: record.total, free: record.free - (3 << 30),
                dataUsed: record.dataUsed + (3 << 30), scannedBytes: record.scannedBytes + (3 << 30), purgeable: record.purgeable,
                hidden: record.hidden, snapshotCount: 0, categories: bigger, folders: record.folders)
            let c = ScanComparison(older: record, newer: later)
            lines.append("comparison: used +\(ByteFormat.string(c.usedChange)) over \(Int(c.days.rounded())) days; biggest growth \(c.biggestGrowth?.name ?? "none") +\(ByteFormat.string(c.biggestGrowth?.change ?? 0))")
            let facts = ReportFacts.build(volume: volume, report: report, insights: [], apps: [], duplicateBytes: 0, similarBytes: 0,
                                          clearoutCount: 0, home: home, trend: c, freedByReclaim: 2 << 30)
            lines.append("report fact: " + (facts.lines.first { $0.hasPrefix("Compared with") } ?? "MISSING"))
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            done.signal()
        }
        done.wait()
        Swift.print(lines.joined(separator: "\n"))
        exit(0)
    }

    /// Scans the whole disk, then writes the report (on-device model if available) to a file. Run as the app.
    static func report(out: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let home = NSHomeDirectory()
            let scanner = DiskScanner(options: .wholeDisk)
            let root = await scanner.scan(root: URL(fileURLWithPath: "/"))
            let cats = SpaceClassifier.breakdown(root: root, home: home)
            let insights = InsightEngine(home: home).generate(from: root)
            let volume = VolumeInfo.current()
            let container = SystemInfo.apfsContainer() ?? APFSContainerInfo(ceiling: volume.total, free: volume.available, volumes: [])
            let report = SpaceReport(
                container: container, snapshots: SystemInfo.localSnapshots(), categories: cats, scannedBytes: root.size,
                unreadable: scanner.unreadablePaths, purgeable: volume.purgeable, scannedWholeDisk: true)
            let apps = AppInventory.installedApps(cancel: CancelFlag())
            let facts = ReportFacts.build(volume: volume, report: report, insights: insights, apps: apps,
                                          duplicateBytes: 0, similarBytes: 0, clearoutCount: 0, home: home)
            let start = Date()
            let result = await AIReport.write(facts: facts)
            var lines = ["source: \(result.source)", "seconds: \(Int(Date().timeIntervalSince(start)))", "", "FACTS:", facts.text, "", "REPORT:", result.text]
            if case .builtIn = result.source { lines.insert("(built-in writer used)", at: 1) }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Moves one file to the Trash exactly as the app would (same ActionLog path), as the real app process so
    /// macOS privacy rules apply. Optionally restores it. Writes what happened to `out`.
    static func trashFile(path: String, out: String, restore: Bool) {
        var lines: [String] = []
        let dir = NSTemporaryDirectory() + "reclaim-trashfile-\(UUID().uuidString)"
        let log = ActionLog(fileURL: URL(fileURLWithPath: dir + "/history.json"))
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let result = log.trash([(path, size)], reason: "dev trash-file")
        lines.append("trashed: \(result.done.count)")
        for f in result.failed { lines.append("failed: \(f.message) permission=\(f.isPermission)") }
        if let e = result.done.first {
            lines.append("trashPath: \(e.trashPath ?? "nil")")
            lines.append("original gone: \(!FileManager.default.fileExists(atPath: path))")
            if restore {
                lines.append("restore: \(log.restore(e.id) ?? "ok")")
                lines.append("back at original: \(FileManager.default.fileExists(atPath: path))")
            }
        }
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: dir)
        exit(0)
    }

    /// Round-trips a throwaway 2 MB file through iCloud Drive: upload, evict, re-download, delete.
    static func evictTest() {
        let fm = FileManager.default
        let dir = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Reclaim Test"
        let file = dir + "/probe.bin"
        func status() -> String {
            let s = CloudEvict.status(of: file)
            return "inCloud=\(s.inCloud) uploaded=\(s.uploaded) downloaded=\(s.downloaded) local=\(CloudEvict.localBytes(of: file))"
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 2 << 20)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761) }
        fm.createFile(atPath: file, contents: Data(bytes))
        print("created: \(status())")
        var waited = 0
        while !CloudEvict.status(of: file).uploaded, waited < 420 { sleep(3); waited += 3 }
        print("after upload wait (\(waited)s): \(status())")
        let r = CloudEvict.evict(file)
        print("evict: freed \(r.freed) skipped \(r.skipped) error \(r.error ?? "none")")
        sleep(2)
        print("after evict: \(status())")
        print("download: \(CloudEvict.download(file) ?? "requested")")
        waited = 0
        while !CloudEvict.status(of: file).downloaded, waited < 120 { sleep(2); waited += 2 }
        print("after download wait (\(waited)s): \(status())")
        try? fm.removeItem(atPath: dir)
        print("cleaned up: exists=\(fm.fileExists(atPath: dir))")
        exit(0)
    }

    /// Read-only: lists installed apps and the leftovers Reclaim would offer for the biggest few.
    static func apps() {
        let start = Date()
        let apps = AppInventory.installedApps(cancel: CancelFlag())
        print("apps: \(apps.count) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        for a in apps.prefix(12) {
            print(String(format: "  %-28@ %10@  used %@  %@%@", a.name as NSString, ByteFormat.string(a.size) as NSString,
                         (a.lastUsed.map { ageText($0) } ?? "never") as NSString, a.caskToken.map { "brew:\($0) " } ?? "", a.bundleID ?? ""))
        }
        for a in apps.prefix(4) {
            let l = AppLeftoverFinder.find(for: a)
            print("leftovers for \(a.name): \(l.count), \(ByteFormat.string(l.reduce(0) { $0 + $1.size }))")
            for x in l.prefix(8) { print("     \(x.kind.rawValue)\(x.needsAdmin ? " [admin]" : "")  \(ByteFormat.string(x.size))  \(x.path)") }
        }
        exit(0)
    }

    /// Runs the clear-outs search inside the real app and writes a report.
    static func clearouts(out: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var lines: [String] = []
            var status = LibrarySource.authorization
            if status == .notDetermined { status = await LibrarySource.requestAccess() }
            lines.append("authorization: \(status.rawValue)")
            if status == .authorized || status == .limited {
                let start = Date()
                let found = await PhotoClearoutFinder().find { _ in }
                lines.append("seconds: \(Int(Date().timeIntervalSince(start)))")
                for kind in ClearoutKind.allCases {
                    let items = found.filter { $0.kind == kind }
                    lines.append("\(kind.rawValue): \(items.count)")
                    for c in items.prefix(6) { lines.append("   \(c.photo.name)  \(c.detail)") }
                }
            }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Runs the Photos-library search inside the real app (launch with `open`) and writes a report.
    static func library(out: String, strict: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var lines: [String] = []
            var status = LibrarySource.authorization
            if status == .notDetermined { status = await LibrarySource.requestAccess() }
            lines.append("authorization: \(status.rawValue)")
            if status == .authorized || status == .limited {
                let level = Strictness.allCases.first { $0.rawValue.lowercased() == strict } ?? .balanced
                let source = LibrarySource()
                let start = Date()
                let groups = await SimilarPhotoFinder().find(source: source, strictness: level) { _ in }
                lines.append("sets: \(groups.count) (\(level.rawValue)) skippedCloud: \(source.skippedCloud) seconds: \(Int(Date().timeIntervalSince(start)))")
                for g in groups {
                    lines.append("set of \(g.photos.count), keep \(g.photos.first?.name ?? "?") because \(g.reasons.joined(separator: ", ")), reclaimable \(g.reclaimable)")
                    for p in g.photos {
                        guard let s = p.scores else {
                            lines.append("   \(p.name)  \(p.width)x\(p.height)  \(p.size) B  NO SCORES (no local render)")
                            continue
                        }
                        lines.append(String(
                            format: "   %@  %dx%d  %lld B  q %.2f sharp %.1f aes %@ face %@ exact %d",
                            p.name as NSString, p.width, p.height, p.size, s.quality, s.sharpness,
                            s.aesthetics.map { String(format: "%.2f", $0) } ?? "nil", s.face.map { String(format: "%.2f", $0) } ?? "nil",
                            p.exactCopies.count))
                    }
                }
            }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Runs the similar-photo search over a folder and prints each set with the scores behind the suggestion.
    static func photos(path: String, strict: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let level = Strictness.allCases.first { $0.rawValue.lowercased() == strict } ?? .balanced
            let groups = await SimilarPhotoFinder().find(roots: [URL(fileURLWithPath: path)], strictness: level) { _ in }
            print("sets: \(groups.count) (\(level.rawValue))")
            for g in groups {
                print("set of \(g.photos.count), looseness \(String(format: "%.2f", g.looseness)), keep \((g.suggestedKeep as NSString).lastPathComponent) because \(g.reasons.joined(separator: ", "))")
                for p in g.photos {
                    let s = p.scores
                    print(String(format: "   %@  %dx%d  %d KB  sharp %.0f aes %.2f faces %d q %.2f  exact-copies %d",
                                 p.name as NSString, p.width, p.height, Int(p.size / 1024), s?.sharpness ?? -1,
                                 s?.aesthetics ?? -9, s?.faceCount ?? -1, s?.quality ?? -1, p.exactCopies.count))
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Runs the duplicate search over a folder (minimum size 1 byte) and prints each group.
    static func dups(path: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let groups = await DuplicateFinder().find(roots: [URL(fileURLWithPath: path)], minSize: 1) { _ in }
            print("groups: \(groups.count)")
            for g in groups {
                print("size \(g.fileSize) copies \(g.files.count) keep \((g.suggestedKeep as NSString).lastPathComponent)")
                for f in g.files { print("   \(f.path)") }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// The `--scan` check: scans a path and prints totals, the deepest big folders, category sums and APFS facts, so the
    /// figures can be compared with `du` and Finder. `path == "/"` uses the whole-disk scan options.
    static func run(path: String, out: String? = nil) {
        let done = DispatchSemaphore(value: 0)
        // Mutated only by the detached task while this thread waits on the semaphore, so there is no concurrent access.
        nonisolated(unsafe) var lines: [String] = []
        func print(_ s: String) { lines.append(s) }
        Task.detached {
            let wholeDisk = path == "/"
            let scanner = DiskScanner(options: wholeDisk ? .wholeDisk : DiskScanner.Options())
            let start = Date()
            let root = await scanner.scan(root: URL(fileURLWithPath: path))
            let snap = scanner.snapshot()
            print("path: \(path)")
            print("full disk access: \(SystemInfo.hasFullDiskAccess())")
            // Deep dive: the biggest folders three levels down, which is where "System Data" hides.
            var deep: [(Int64, String)] = []
            let base = root.path.split(separator: "/").count
            root.walk { node in
                let depth = node.path.split(separator: "/").count - base
                if node.isDirectory, depth >= 1, depth <= 3, node.size >= 200 << 20 { deep.append((node.size, node.path)) }
                return depth < 3
            }
            for (size, p) in deep.sorted(by: { $0.0 > $1.0 }).prefix(40) { print("  deep \(ByteFormat.string(size))  \(p)") }
            print("total bytes: \(root.size)  (\(ByteFormat.string(root.size)))")
            print("files: \(snap.files)  seconds: \(String(format: "%.1f", Date().timeIntervalSince(start)))")
            print("unreadable dirs: \(scanner.unreadablePaths.count)")
            for p in scanner.unreadablePaths.prefix(10) { print("  \(p)") }
            for c in root.children.prefix(8) {
                print("  \(ByteFormat.string(c.size))  \(c.path)")
                for g in c.children.prefix(4) { print("      \(ByteFormat.string(g.size))  \(g.path)") }
            }
            let cats = SpaceClassifier.breakdown(root: root, home: NSHomeDirectory())
            for c in cats { print(String(format: "  %-26@ %@", c.category.rawValue as NSString, ByteFormat.string(c.bytes) as NSString)) }
            print("category sum: \(cats.reduce(Int64(0)) { $0 + $1.bytes })")
            if let c = SystemInfo.apfsContainer() {
                print("APFS data volume in use: \(c.dataVolume?.inUse ?? 0)")
                for v in c.volumes { print("  volume \(v.name) [\(v.role)] \(v.inUse)") }
                print("container free: \(c.free) ceiling: \(c.ceiling)")
            }
            print("snapshots: \(SystemInfo.localSnapshots().count)")
            let v = VolumeInfo.current()
            print("volume total \(v.total) available \(v.available) availableIncludingPurgeable \(v.availableIncludingPurgeable) purgeable \(v.purgeable)")
            var tops: [String: Int] = [:]
            for p in scanner.unreadablePaths { tops[p.split(separator: "/").prefix(2).joined(separator: "/"), default: 0] += 1 }
            for (k, n) in tops.sorted(by: { $0.value > $1.value }).prefix(8) { print("  unreadable under /\(k): \(n)") }
            done.signal()
        }
        done.wait()
        let text = lines.joined(separator: "\n")
        if let out { try? text.write(toFile: out, atomically: true, encoding: .utf8) } else { Swift.print(text) }
        exit(0)
    }
}
