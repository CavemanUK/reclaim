import SwiftUI

struct SuggestionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Page.spacing) {
                ScreenHeader(title: "Clean up", subtitle: "What Reclaim found that you can get back, with a plain explanation and a risk label on each.",
                             icon: "lightbulb.fill", colors: [.yellow, .orange])
                if model.insights.isEmpty {
                    ContentUnavailableView(
                        model.report == nil ? "No scan yet" : "Nothing obvious to clean up",
                        systemImage: "lightbulb",
                        description: Text(model.report == nil
                            ? "Run a scan from My Mac and Reclaim will explain what is worth cleaning."
                            : "No large caches, stale dependencies or old installers were found."))
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    let potential = model.insights.reduce(Int64(0)) { $0 + $1.potentialBytes }
                    HStack(spacing: 12) {
                        StatTile(value: ByteFormat.string(potential), label: "you could get back safely", color: .green)
                        StatTile(value: "\(model.insights.count)", label: "suggestions", color: .orange)
                    }
                    Text("Tick what you want to remove, look it over, and approve. Nothing moves until you say so.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach([(Risk.safe, "Safe wins", "checkmark.seal"), (.review, "Worth a look", "eye"), (.careful, "Handle with care", "exclamationmark.triangle")], id: \.0) { group in
                        let items = model.insights.filter { $0.risk == group.0 }
                        if !items.isEmpty {
                            Label(group.1, systemImage: group.2).font(.title2.bold()).padding(.top, 6)
                            ForEach(items) { InsightCard(insight: $0) }
                        }
                    }
                }
            }
            .pageBody()
        }
        .navigationTitle("Clean up")
    }
}

struct InsightCard: View {
    let insight: Insight
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    private var selectedItems: [InsightItem] {
        insight.items.filter { model.insightSelection.contains($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(insight.title, systemImage: insight.icon).font(.title3.bold())
                RiskBadge(risk: insight.risk)
                Spacer()
                if insight.partial {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("up to \(ByteFormat.string(insight.totalBytes))").font(.headline).monospacedDigit().foregroundStyle(.secondary)
                        Text("exact amount decided by the tool").font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(ByteFormat.string(insight.totalBytes)).font(.title3.bold()).monospacedDigit()
                }
            }
            Text(insight.summary).font(.callout).foregroundStyle(.secondary)
            if let advice = insight.advice { Label(advice, systemImage: "hand.point.right").font(.callout) }
            if let command = insight.command {
                let brew = BrewCommand.parse(command, title: insight.title, explanation: insight.summary)
                Text(brew != nil
                    ? "Reclaim can run this Homebrew command for you. You'll see it and confirm first:"
                    : "If you want to do this yourself, run this in Terminal. Reclaim won't run it:")
                    .font(.callout)
                CommandBox(command: command, runnable: brew)
            }

            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 4) {
                    ForEach(insight.items) { item in
                        HStack {
                            if item.trashable || item.evictable {
                                Toggle("", isOn: Binding(
                                    get: { model.insightSelection.contains(item.path) },
                                    set: { on in
                                        if on { model.insightSelection.insert(item.path) } else { model.insightSelection.remove(item.path) }
                                    }))
                                    .labelsHidden()
                            } else {
                                Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 20)
                                    .help("Reclaim won't remove this itself")
                            }
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(1)
                                Text(item.path.replacingOccurrences(of: model.home, with: "~") + (item.note.map { " · \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.size)).monospacedDigit()
                            Button { model.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("\(insight.items.count) item\(insight.items.count == 1 ? "" : "s")")
            }

            if !insight.actionableItems.isEmpty {
                HStack {
                    Button("Select all") { insight.actionableItems.forEach { model.insightSelection.insert($0.path) }; expanded = true }
                    Button("Clear") { insight.items.forEach { model.insightSelection.remove($0.path) } }
                        .disabled(selectedItems.isEmpty)
                    Spacer()
                    let bytes = selectedItems.reduce(Int64(0)) { $0 + $1.size }
                    if insight.action == .evict {
                        Button("Review and keep \(selectedItems.count) in iCloud only (\(ByteFormat.string(bytes)))…") {
                            model.requestEvict(selectedItems.map { ($0.path, $0.size) }, reason: insight.title)
                        }
                        .buttonStyle(.borderedProminent).tint(.cyan).disabled(selectedItems.isEmpty)
                    } else {
                        Button("Review \(selectedItems.count) chosen (\(ByteFormat.string(bytes)))…") {
                            model.requestTrash(selectedItems.map { ($0.path, $0.size) }, reason: insight.title)
                        }
                        .buttonStyle(.borderedProminent).disabled(selectedItems.isEmpty)
                    }
                }
            }
        }
        .card()
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmPurge = false

    private var pending: [HistoryEntry] { model.history.filter { $0.status == .trashed } }

    var body: some View {
        VStack(alignment: .leading, spacing: Page.spacing) {
            ScreenHeader(title: "Undo", subtitle: "Everything Reclaim has moved. Put any of it back until you free the space for good.",
                         icon: "clock.arrow.circlepath", colors: [.gray, .secondary])

            if !pending.isEmpty {
                let bytes = pending.reduce(Int64(0)) { $0 + $1.size }
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(pending.count) item\(pending.count == 1 ? "" : "s") waiting in the Trash").font(.headline)
                        Text("\(ByteFormat.string(bytes)) is not free until they are deleted for good. This only affects items Reclaim moved, not anything else in your Trash.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete permanently…", role: .destructive) { confirmPurge = true }
                }
                .card()
            }

            if model.history.isEmpty {
                ContentUnavailableView("Nothing to undo", systemImage: "clock", description: Text("Reclaim hasn't moved anything yet."))
            } else {
                List(model.history) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            if entry.status == .photosRecentlyDeleted {
                                Text(entry.reason.components(separatedBy: " · ").last ?? "Photo")
                            } else {
                                Text((entry.originalPath as NSString).lastPathComponent)
                                Text(entry.originalPath.replacingOccurrences(of: model.home, with: "~"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Text("\(entry.reason) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormat.string(entry.size)).monospacedDigit()
                        switch entry.status {
                        case .trashed: Button("Put back") { model.restore(entry) }
                        case .restored: Text("Restored").foregroundStyle(.green)
                        case .deleted: Text("Deleted").foregroundStyle(.secondary)
                        case .photosRecentlyDeleted:
                            Button("In Photos › Recently Deleted") { LibrarySource.openPhotosApp() }
                                .help("Recoverable in the Photos app for about 30 days")
                        case .evicted:
                            Button("Download again") { model.redownload(entry) }
                                .help("Asks iCloud to bring the local copy back")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Page.inset).padding(.top, Page.top).padding(.bottom, Page.inset)
        .frame(maxWidth: Page.maxWidth).frame(maxWidth: .infinity)
        .navigationTitle("Undo")
        .onAppear { model.refreshHistory() }
        .confirmationDialog(
            "Permanently delete \(pending.count) item(s)?", isPresented: $confirmPurge, titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) { model.purge(Set(pending.map(\.id))) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(ByteFormat.string(pending.reduce(Int64(0)) { $0 + $1.size })) and cannot be undone.")
        }
    }
}
