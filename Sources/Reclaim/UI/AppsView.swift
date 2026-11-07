import SwiftUI

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var sort: Sort = .size

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Biggest", unused = "Least used", name = "Name"
        var id: String { rawValue }
    }

    private var shown: [InstalledApp] {
        var list = model.apps
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .unused: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "Uninstall apps", subtitle: "Remove an app and everything it left behind, in one go. Everything goes to the Trash first.",
                         icon: "app.badge.checkmark", colors: [.orange, .red])
                .padding(.horizontal, Page.inset).padding(.top, Page.top).padding(.bottom, Page.spacing)
            HSplitView {
                list.frame(minWidth: 320, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .pageColumn()
        .navigationTitle("Uninstall apps")
        .onAppear { if model.appsState == .idle { model.loadApps() } }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.apps.count) apps").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if model.appsState == .working { ProgressView().controlSize(.small) }
                Button { model.loadApps() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    .disabled(model.appsState == .working)
            }
            TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
            Picker("", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if model.appsState == .done, model.apps.isEmpty {
                ContentUnavailableView("No apps found", systemImage: "app.dashed", description: Text("Nothing in /Applications or ~/Applications."))
            } else {
                List(shown, selection: Binding(get: { model.selectedApp?.path }, set: { path in
                    if let path, let app = model.apps.first(where: { $0.path == path }) { model.inspect(app) }
                })) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).lineLimit(1)
                            Text(app.lastUsed.map { "Used \(ageText($0))" } ?? "Never opened (as far as Spotlight knows)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormat.string(app.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(app.path)
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.leading, Page.inset).padding(.trailing, 16).padding(.bottom, Page.inset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            AppDetail(app: app)
        } else {
            ContentUnavailableView(
                "Pick an app", systemImage: "app.badge.checkmark",
                description: Text("Sort by least used to find apps you've forgotten about. The biggest wins are usually there."))
        }
    }
}

private struct AppDetail: View {
    let app: InstalledApp
    @Environment(AppModel.self) private var model

    private var running: Bool { model.isRunning(app) }
    private var removable: [Leftover] { model.leftovers.filter { !$0.needsAdmin } }
    private var adminOnly: [Leftover] { model.leftovers.filter(\.needsAdmin) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if running { runningNote }
                if let token = app.caskToken { brewNote(token) }
                leftoverSection
                if !adminOnly.isEmpty { adminSection }
            }
            .padding(.leading, 16).padding(.trailing, Page.inset).padding(.bottom, Page.inset)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 26, weight: .bold, design: .rounded))
                Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    pill(ByteFormat.string(app.size), "app")
                    if let used = app.lastUsed { pill("Used \(ageText(used))", "clock") } else { pill("Never opened", "clock") }
                    if app.fromAppStore { pill("App Store", "bag") }
                    if app.isApple { pill("Apple app", "apple.logo") }
                }
                HStack {
                    Button("Show in Finder") { model.reveal(app.path) }
                    if !running { Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) } }
                }
                .controlSize(.small)
            }
        }
    }

    private func pill(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var runningNote: some View {
        Label("\(app.name) is running. Quit it first, then uninstall.", systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange).card()
    }

    private func brewNote(_ token: String) -> some View {
        let command = BrewCommand(
            arguments: ["uninstall", "--cask", token], title: "Uninstall \(app.name) with Homebrew",
            explanation: "Homebrew installed this app, so it should remove it: the app goes, and Homebrew forgets its record. Leftovers in your Library are handled by Reclaim below.")
        return VStack(alignment: .leading, spacing: 8) {
            Label("Installed by Homebrew", systemImage: "mug").font(.headline)
            Text("The tidiest way is to let Homebrew remove it, which also forgets its record. Reclaim can run that for you after you confirm.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { model.requestBrew(command) } label: { Label("Uninstall with Homebrew…", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(running || !model.brewAvailable)
                Text("then remove the leftovers below").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var leftoverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What will be removed").font(.title3.bold())
                Spacer()
                if model.leftoversLoading { ProgressView().controlSize(.small) }
            }
            row(path: app.path, name: app.name + ".app", kind: nil, size: app.size, note: "The app itself.", warn: false)
            if removable.isEmpty, !model.leftoversLoading {
                Text("No leftover files found in your Library for this app.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(removable) { l in
                row(path: l.path, name: l.name, kind: l.kind, size: l.size,
                    note: l.sizeUnknown
                        ? l.kind.explanation + " Size unknown: macOS hides this folder until Reclaim has Full Disk Access."
                        : l.kind.explanation,
                    warn: l.mayHoldUserData || (l.sizeUnknown && l.kind == .supportData))
            }
        }
        .card()
    }

    private func row(path: String, name: String, kind: LeftoverKind?, size: Int64, note: String, warn: Bool) -> some View {
        let on = model.uninstallSelection.contains(path)
        return HStack(alignment: .top, spacing: 12) {
            KeepRemoveToggle(remove: Binding(
                get: { on },
                set: { if $0 { model.uninstallSelection.insert(path) } else { model.uninstallSelection.remove(path) } }))
                .frame(width: 130)
            Image(systemName: kind?.icon ?? "app").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(kind?.rawValue ?? "Application").font(.headline)
                    if warn {
                        Text("may hold your data").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(path.replacingOccurrences(of: model.home, with: "~"))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(size)).monospacedDigit()
            Button { model.reveal(path) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 4)
    }

    private var adminSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs an administrator", systemImage: "lock.shield").font(.headline)
            Text("These were installed for all users. Reclaim can't move them; remove them in Finder (it will ask for your password) once the app is gone.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(adminOnly) { l in
                HStack {
                    Text(l.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.string(l.size)).font(.caption).monospacedDigit()
                    Button("Show in Finder") { model.reveal(l.path) }.controlSize(.small)
                }
            }
        }
        .card()
    }

    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(model.uninstallSelection.count) item\(model.uninstallSelection.count == 1 ? "" : "s") · \(ByteFormat.string(model.uninstallBytes))").font(.headline)
                Text("Goes to the Trash. Put it back from Undo if you change your mind.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review and uninstall…") { model.requestUninstall() }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                .disabled(running || model.uninstallSelection.isEmpty || model.leftoversLoading)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
