import SwiftUI

// The "Duplicates" screen: choose folders, run `DuplicateFinder`, then review sets of identical files.
// The suggested keeper in each set is never selected for removal by the bulk actions, and selected files go
// to the Trash via `AppModel.requestTrash` after the user confirms.

/// One colour per stage of the duplicate search, shared by the stage chips and the progress card.
private let stageColors: [Color] = [.blue, .purple, .orange, .green]

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    /// Total size of the files currently marked for removal.
    private var selectedBytes: Int64 {
        model.dupGroups.reduce(Int64(0)) { sum, g in
            sum + g.files.filter { model.dupSelection.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Page.spacing) {
                header
                setup
                if model.dupState == .working { DupWorkingCard(progress: model.dupProgress) }
                if model.dupState != .idle { CloudNote(count: model.dupProgress.skippedCloud) }
                if model.dupState == .done { results.arrives() }
            }
            .animation(.snappy, value: model.dupState == .done)
            .pageBody()
        }
        .safeAreaInset(edge: .bottom) { if !model.dupSelection.isEmpty { actionBar } }
        .sheet(item: Bindable(model).dupCompare) { group in CompareSheet(group: group) }
        .navigationTitle("Duplicates")
    }

    private var header: some View {
        ScreenHeader(title: "Duplicates", subtitle: "Files that are exactly the same, byte for byte. See them side by side and choose which extras to remove.",
                     icon: "square.on.square.dashed", colors: [.indigo, .blue])
    }

    // MARK: Setup

    /// Folder chooser, minimum size and the search button.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where should Reclaim look?").font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(model.dupFolders, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(url.lastPathComponent)
                        Button { model.dupFolders.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .help(url.path)
                }
                Button { model.addDupFolder() } label: { Label("Add folder", systemImage: "plus") }
            }
            HStack {
                Picker("Ignore files smaller than", selection: Bindable(model).dupMinSize) {
                    Text("100 KB").tag(Int64(100 << 10))
                    Text("1 MB").tag(Int64(1 << 20))
                    Text("10 MB").tag(Int64(10 << 20))
                }
                .fixedSize()
                // Folders and the size are remembered between launches; this puts them back to the usual ones.
                Button("Reset to defaults") { model.resetSettings() }
                    .buttonStyle(.link).help("Forget the saved folders and size")
                Spacer()
                if model.dupState == .working {
                    Button("Stop") { model.cancelDuplicates() }
                } else {
                    Button { model.findDuplicates() } label: {
                        Label(model.dupState == .done ? "Search again" : "Find duplicates", systemImage: "magnifyingglass")
                            .font(.headline).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.dupFolders.isEmpty)
                }
            }
            Text("Photos inside the Photos app library, apps, and hidden or developer folders (like node_modules) are skipped automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: Results

    @ViewBuilder
    /// Summary figures, bulk actions and one card per set of duplicates.
    private var results: some View {
        if model.dupGroups.isEmpty {
            ContentUnavailableView("No duplicates found", systemImage: "checkmark.seal",
                                   description: Text("Every file in those folders is unique."))
        } else {
            let reclaimable = model.dupGroups.reduce(Int64(0)) { $0 + $1.reclaimable }
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(value: "\(model.dupGroups.count)", label: "sets of duplicates", color: .indigo)
                    StatTile(value: ByteFormat.string(reclaimable), label: "you could free", color: .green)
                    StatTile(value: "\(model.dupGroups.reduce(0) { $0 + $1.files.count - 1 })", label: "extra copies", color: .orange)
                }
                HStack {
                    Text("Click any picture, or Compare, to look at the copies side by side.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.selectDuplicateExtras() } label: { Label("Remove all extras", systemImage: "trash") }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .help("Marks every copy for removal except the one Reclaim suggests keeping")
                    Button("Keep everything") { model.dupSelection = [] }.disabled(model.dupSelection.isEmpty)
                }
                ForEach(model.dupGroups) { GroupCard(group: $0) }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(model.dupSelection.count) file\(model.dupSelection.count == 1 ? "" : "s") chosen").font(.headline)
                Text("\(ByteFormat.string(selectedBytes)) to free. One copy of each is always kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review and move to Trash…") {
                let items = model.dupGroups.flatMap(\.files)
                    .filter { model.dupSelection.contains($0.path) }.map { ($0.path, $0.size) }
                model.requestTrash(items, reason: "Duplicate files")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Explaining the scan

/// Explains what the search is doing at each of its four stages (matching `DupProgress.stage`), so a long
/// scan is understandable rather than just a spinner.
private struct DupWorkingCard: View {
    let progress: DupProgress

    private static let titles = ["Looking through your folders", "Ruling out different sizes", "Quick fingerprint check", "Making absolutely sure"]
    private static let short = ["Look", "Sort", "Quick check", "Make sure"]
    private static let explain = [
        "Reclaim is listing every file in the folders you chose and noting its size. Nothing is opened or changed.",
        "Two files of different sizes can't be identical, so most files are ruled out right away. Only files that share a size with another file go on.",
        "For files of the same size, Reclaim reads a tiny sample from the start and end of each and compares them. This weeds out nearly all lookalikes very quickly.",
        "The last suspects are read in full and compared exactly. Only true byte-for-byte copies make the list, so it never guesses.",
    ]

    var body: some View {
        let stage = min(max(progress.stage, 1), 4)
        let color = stageColors[stage - 1]
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    let done = i + 1 < stage
                    let active = i + 1 == stage
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.dotted.circle" : "circle"))
                        Text(Self.short[i]).font(.callout.weight(active ? .bold : .regular))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(done || active ? stageColors[i] : .secondary)
                    .background((done || active ? stageColors[i] : Color.secondary).opacity(0.14), in: Capsule())
                    if i < 3 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(stage) of 4: \(Self.titles[stage - 1])")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
                Text(Self.explain[stage - 1]).font(.title3).foregroundStyle(.secondary)
            }

            if progress.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).tint(color)
                    Text("\(progress.done.formatted()) of \(progress.total.formatted()) files checked")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                ProgressView().progressViewStyle(.linear).tint(color)
            }

            HStack(spacing: 12) {
                tile("\(progress.filesFound.formatted())", "files looked at", .blue)
                tile(stage >= 2 ? "\(progress.candidates.formatted())" : "…", "share a size with another", .purple)
                tile(stage >= 4 ? "\(progress.suspects.formatted())" : "…", "still look identical", .orange)
                tile(stage >= 4 ? ByteFormat.string(progress.candidateBytes) : "…", "left to read in full", .green)
            }

            if !progress.currentPath.isEmpty, stage == 1 {
                Label(progress.currentPath, systemImage: "folder").font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [color.opacity(0.16), color.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.35)))
        .animation(.snappy, value: stage)
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - A set of duplicates

/// One set of identical files, each row with a keep/remove switch.
private struct GroupCard: View {
    let group: DupGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files.first(where: { $0.path == group.suggestedKeep })?.name ?? group.files[0].name)
                        .font(.headline).lineLimit(1)
                    Text("\(group.files.count) identical copies · \(ByteFormat.string(group.fileSize)) each")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(ByteFormat.string(group.reclaimable)) to free")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.green.opacity(0.15), in: Capsule())
                Button { model.dupCompare = group } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            ForEach(group.files) { file in
                row(file)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(.purple).frame(width: 4).padding(.vertical, 12)
        }
    }

    private func row(_ file: DupFile) -> some View {
        let keep = file.path == group.suggestedKeep
        let allowed = model.canTrash(file.path)
        let chosen = model.dupSelection.contains(file.path)
        return HStack(spacing: 12) {
            KeepRemoveToggle(
                remove: Binding(get: { chosen }, set: { model.setDuplicate(file, in: group, selected: $0) }),
                enabled: allowed)
                .frame(width: 130)
            Button { model.dupCompare = group } label: { ThumbView(path: file.path, side: 58) }
                .buttonStyle(.plain).help("Look at the copies side by side")
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: model.home, with: "~"))
                    .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text("Modified \(ageText(file.modified))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if keep {
                badge("Suggested keep", .green)
            } else if chosen {
                badge("Will move to Trash", .red)
            }
            Button { model.reveal(file.path) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(8)
        .background(chosen ? Color.red.opacity(0.08) : (keep ? Color.green.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 10))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}

// MARK: - Side-by-side comparison

/// Shows every copy of a set side by side with its metadata, so the user can pick which to keep.
private struct CompareSheet: View {
    let group: DupGroup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var playing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare \(group.files.count) copies").font(.title2.bold())
                    Text("These files are identical inside, so they look and sound the same. What differs is where they live and when they were made. Play or look at each, then decide which to keep.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(group.files) { file in pane(file) }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(22)
        .frame(minWidth: 760, idealWidth: 980, minHeight: 560)
    }

    /// The button that would remove the last unselected copy is disabled, so at least one copy always remains.
    private func pane(_ file: DupFile) -> some View {
        let keep = file.path == group.suggestedKeep
        let chosen = model.dupSelection.contains(file.path)
        let allowed = model.canTrash(file.path)
        let dims = Imaging.pixelSize(path: file.path)
        return VStack(alignment: .leading, spacing: 10) {
            FilePreview(path: file.path, height: 280, playingPath: $playing)
            HStack {
                Text(file.name).font(.headline).lineLimit(2)
                Spacer()
            }
            if keep { tag("Suggested keep", .green) } else if chosen { tag("Will move to Trash", .red) }
            VStack(alignment: .leading, spacing: 3) {
                meta("Size", ByteFormat.string(file.size))
                if let dims { meta("Dimensions", "\(dims.width) × \(dims.height)") }
                meta("Modified", file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                meta("Created", file.created?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
            Text(file.path.replacingOccurrences(of: model.home, with: "~"))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(3).truncationMode(.middle)
            HStack {
                if allowed {
                    Button(chosen ? "Keep this one" : "Move to Trash") {
                        model.setDuplicate(file, in: group, selected: !chosen)
                    }
                    .tint(chosen ? .green : .red)
                    .disabled(!chosen && group.files.filter { !model.dupSelection.contains($0.path) && $0.path != file.path }.isEmpty)
                } else {
                    Label("Protected", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                Button("Show in Finder") { model.reveal(file.path) }
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 330)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(keep ? Color.green.opacity(0.6) : (chosen ? Color.red.opacity(0.5) : .clear), lineWidth: 2))
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.caption)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}
