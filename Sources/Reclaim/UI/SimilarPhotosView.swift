import SwiftUI

// The "Similar photos" screen: pick folders or the Photos library, choose how strict the match should be, run
// `SimilarPhotoFinder`, then review each set. Files go to the Trash and library photos go to Photos'
// Recently Deleted, always through `AppModel.requestPhotoRemoval` after the user confirms.

/// One colour per pipeline stage, shared by the stage chips and the progress card.
private let stageColors: [Color] = [.pink, .purple, .blue, .green]

struct SimilarPhotosView: View {
    @Environment(AppModel.self) private var model

    /// Total known size of the photos marked for removal. Library photos with unknown size contribute 0.
    private var selectedBytes: Int64 {
        model.photoGroups.reduce(Int64(0)) { sum, g in
            sum + g.photos.filter { model.photoSelection.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Page.spacing) {
                header
                setup
                if model.photoState == .working { PhotoWorkingCard(progress: model.photoProgress) }
                if model.photoState != .idle { CloudNote(count: model.photoProgress.skippedCloud) }
                if model.photoState == .done { results.arrives() }
            }
            .animation(.snappy, value: model.photoState == .done)
            .pageBody()
        }
        .safeAreaInset(edge: .bottom) { if !model.photoSelection.isEmpty { actionBar } }
        .sheet(item: Bindable(model).photoCompare) { group in PhotoCompareSheet(group: group) }
        .navigationTitle("Similar photos")
        .onAppear { model.refreshPhotoAuth() }
    }

    private var header: some View {
        ScreenHeader(title: "Similar photos", subtitle: "The same shot or nearly the same: bursts, edits, resized copies. Reclaim suggests the best of each set, and you decide.",
                     icon: "photo.stack", colors: [.pink, .orange])
    }

    // MARK: Setup

    /// Source picker (folders or Photos library), strictness and the search button.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Where should Reclaim look?").font(.headline)
                Picker("", selection: Bindable(model).photoSourceKind) {
                    ForEach(AppModel.PhotoSourceKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .disabled(model.photoState == .working)
            }

            if model.photoSourceKind == .folders {
                FlowLayout(spacing: 8) {
                    ForEach(model.photoFolders, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(.pink)
                            Text(url.lastPathComponent)
                            Button { model.photoFolders.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.pink.opacity(0.12), in: Capsule())
                        .help(url.path)
                    }
                    Button { model.addPhotoFolder() } label: { Label("Add folder", systemImage: "plus") }
                }
            } else {
                libraryAccess
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How alike must they be?").font(.headline)
                Picker("", selection: Bindable(model).photoStrictness) {
                    ForEach(Strictness.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                Text(model.photoStrictness.blurb + (model.photoSourceKind == .folders
                    ? " Exact copies are not listed here. Find those on the Duplicates screen."
                    : " Photos stored only in iCloud are skipped, so nothing is downloaded."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if model.photoState == .working {
                    Button("Stop") { model.cancelPhotos() }
                } else {
                    Button { model.findPhotos() } label: {
                        Label(model.photoState == .done ? "Search again" : "Find similar photos", systemImage: "magnifyingglass")
                            .font(.headline).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.pink)
                    .disabled(model.photoSourceKind == .folders ? model.photoFolders.isEmpty : !model.canSearchLibrary)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    /// Explains the current Photos permission and what the user can do about it.
    private var libraryAccess: some View {
        switch model.photoAuth {
        case .authorized:
            Label("Reclaim can read your Photos library. Deleting always asks you twice: here, then in Photos.", systemImage: "checkmark.seal")
                .font(.callout).foregroundStyle(.secondary)
        case .limited:
            Label("Reclaim can see only the photos you chose to share. Allow full access in System Settings › Privacy & Security › Photos to search the whole library.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 8) {
                Label("Photos access is turned off for Reclaim.", systemImage: "lock").font(.callout).foregroundStyle(.orange)
                Text("Turn it on under Privacy & Security › Photos. If it already shows Full Access, macOS hasn't told Reclaim yet: restart Reclaim.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Settings") { model.openPhotosPrivacySettings() }.buttonStyle(.borderedProminent)
                    Button("Restart Reclaim") { model.relaunch() }.buttonStyle(.link)
                }
            }
        default:
            HStack {
                Text("Reclaim needs your permission to look at your Photos library. It reads photos already on this Mac and never downloads or changes anything without you.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Allow access to Photos") { model.requestPhotoAccess() }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    /// Summary figures, bulk actions and one card per set.
    private var results: some View {
        if model.photoGroups.isEmpty {
            ContentUnavailableView("No similar photos found", systemImage: "checkmark.seal",
                                   description: Text("Try “Loose” to also catch photos that are only roughly alike."))
        } else {
            let reclaimable = model.photoGroups.reduce(Int64(0)) { $0 + $1.reclaimable }
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(value: "\(model.photoGroups.count)", label: "sets of similar photos", color: .pink)
                    StatTile(value: ByteFormat.string(reclaimable), label: model.photoGroups.contains(where: \.sizesUnknown) ? "you could free on this Mac (more in iCloud)" : "you could free", color: .green)
                    StatTile(value: "\(model.photoGroups.reduce(0) { $0 + $1.photos.count - 1 })", label: "extra photos", color: .orange)
                }
                HStack {
                    Text("Each photo has a Keep / Remove switch. Click a photo to compare its set.").foregroundStyle(.secondary)
                    Spacer()
                    if !model.photoSelection.isEmpty {
                        Button("Keep everything") { model.photoSelection = [] }
                    }
                    Button { model.reviewPhotoExtras() } label: { Label("Remove all extras…", systemImage: "trash") }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .help("Lists every photo except the best of each set, for you to approve")
                }
                ForEach(model.photoGroups) { PhotoGroupCard(group: $0) }
            }
        }
    }

    /// The button wording reflects where the chosen photos live, since library photos are deleted through Photos
    /// rather than moved to the Trash.
    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(model.photoSelection.count) photo\(model.photoSelection.count == 1 ? "" : "s") chosen").font(.headline)
                Text((selectedBytes > 0 ? "\(ByteFormat.string(selectedBytes)) to free. " : "") + "At least one photo from every set is always kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let chosen = model.photoGroups.flatMap(\.photos).filter { model.photoSelection.contains($0.path) }
            Button(chosen.allSatisfy(\.isAsset) ? "Review and delete from Photos…" : "Review and move to Trash…") {
                model.requestPhotoRemoval(chosen, reason: "Similar photos")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Explaining the search

/// Explains each of the four pipeline stages as it runs (matching `PhotoProgress.stage`).
private struct PhotoWorkingCard: View {
    let progress: PhotoProgress

    private static let titles = ["Looking at your photos", "Spotting look-alikes", "Checking them closely", "Choosing the best of each set"]
    private static let short = ["Look", "Spot", "Check", "Choose"]
    private static let explain = [
        "Reclaim makes a tiny fingerprint of every picture, like a thumbnail you can't see. Your originals are only read, never changed.",
        "Pictures with similar fingerprints are put aside as possible matches. Everything else is ruled out straight away.",
        "Apple's on-device image model, the same kind of technology the Photos app uses, compares the possible matches properly. This stops different photos being mixed up.",
        "Apple's model rates composition and how well faces are captured (eyes open, in focus), and Reclaim measures sharpness and detail, to suggest the one worth keeping.",
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
                    Text("\(progress.done.formatted()) of \(progress.total.formatted()) photos")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                ProgressView().progressViewStyle(.linear).tint(color)
            }
            HStack(spacing: 12) {
                stat("\(progress.photosFound.formatted())", "photos found", .pink)
                stat(stage >= 3 ? "\(progress.lookalikes.formatted())" : "…", "have a look-alike", .purple)
                stat(stage >= 4 ? "\(progress.sets.formatted())" : "…", "sets confirmed", .green)
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

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - A set of similar photos

/// One set of similar photos with the reasons the top one was suggested.
private struct PhotoGroupCard: View {
    let group: SimilarGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.photos.count) similar photos").font(.headline)
                    if !group.reasons.isEmpty {
                        HStack(spacing: 6) {
                            Text("Why this one:").font(.caption).foregroundStyle(.secondary)
                            ForEach(group.reasons, id: \.self) { r in
                                // This string must match the reason produced by `SimilarPhotoFinder.rank`.
                                let tie = r == SimilarPhotoFinder.tieReason
                                Text(r).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background((tie ? Color.secondary : Color.green).opacity(0.18), in: Capsule())
                                    .foregroundStyle(tie ? Color.secondary : Color.green)
                            }
                        }
                    }
                }
                Spacer()
                if group.sizesUnknown && group.reclaimable == 0 {
                    Label("Originals in iCloud", systemImage: "icloud")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help("Only an optimised copy is on this Mac, so the size isn't known. Deleting frees iCloud space and the local copy.")
                } else {
                    Text("\(ByteFormat.string(group.reclaimable)) to free")
                        .font(.callout.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(group.photos) { photo in tile(photo) }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(.pink).frame(width: 4).padding(.vertical, 12)
        }
    }

    /// One photo in a set, with its keep/remove switch and quality bar.
    private func tile(_ photo: PhotoInfo) -> some View {
        let keep = photo.path == group.suggestedKeep
        let chosen = model.photoSelection.contains(photo.path)
        let allowed = model.canTrash(photo.path)
        return VStack(alignment: .leading, spacing: 6) {
            Button { model.photoCompare = group } label: {
                PhotoThumb(photo: photo, side: 200, fit: true)
                    .overlay(alignment: .topLeading) {
                        if chosen { badge("Remove", .red).padding(6) } else if keep { badge("Best", .green).padding(6) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(keep ? Color.green : (chosen ? Color.red : .clear), lineWidth: 2.5))
            }
            .buttonStyle(.plain)
            HStack {
                KeepRemoveToggle(
                    remove: Binding(get: { chosen }, set: { model.setPhoto(photo, in: group, selected: $0) }),
                    enabled: allowed)
                if !photo.isAsset {
                    Button { model.reveal(photo.path) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
            if let q = photo.scores?.quality {
                ProgressView(value: safeFraction(q)).tint(keep ? .green : .gray)
                    .help("Overall quality score, relative to the others in this set")
            }
            Text("\(photo.width) × \(photo.height)" + (photo.size > 0 ? " · \(ByteFormat.string(photo.size))" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if !photo.exactCopies.isEmpty {
                Label("+\(photo.exactCopies.count) exact cop\(photo.exactCopies.count == 1 ? "y" : "ies"), see Duplicates", systemImage: "square.on.square")
                    .font(.caption2).foregroundStyle(.orange)
                    .help("Byte-for-byte identical files are handled on the Duplicates screen, so they're counted there.")
            }
        }
        .frame(width: 200)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color, in: Capsule())
    }
}

// MARK: - Side-by-side comparison

/// Larger side-by-side view of a whole set, showing each score that went into the ranking.
private struct PhotoCompareSheet: View {
    let group: SimilarGroup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var playing: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 14, alignment: .top)] }

    var body: some View {
        let count = group.photos.count
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let idealWidth = min(screen.width - 80, CGFloat(min(count, 4)) * 350 + 60)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare all \(count) photos").font(.title2.bold())
                    Text("Best first. The bars show how each photo scores. Flip the switch on any photo you don't want.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(group.photos) { photo in pane(photo) }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(22)
        .frame(minWidth: 720, idealWidth: idealWidth, maxWidth: screen.width - 60,
               minHeight: 620, idealHeight: min(screen.height - 80, count > 4 ? 1000 : 760), maxHeight: screen.height - 60)
    }

    private func pane(_ photo: PhotoInfo) -> some View {
        let keep = photo.path == group.suggestedKeep
        let chosen = model.photoSelection.contains(photo.path)
        let allowed = model.canTrash(photo.path)
        // Each bar is shown relative to the best value in the set, matching how `SimilarPhotoFinder.rank` normalises.
        let maxPixels = Double(max(1, group.photos.map(\.pixels).max() ?? 1))
        let maxSize = Double(max(1, group.photos.map(\.size).max() ?? 1))
        let maxSharp = max(1e-6, group.photos.compactMap { $0.scores?.sharpness }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            PhotoPreview(photo: photo, height: 260, playingPath: $playing)
            HStack(alignment: .firstTextBaseline) {
                Text(photo.name).font(.headline).lineLimit(2)
                Spacer()
                if chosen { tag("Will be removed", .red) } else if keep { tag("Best pick", .green) }
            }
            KeepRemoveToggle(
                remove: Binding(get: { chosen }, set: { model.setPhoto(photo, in: group, selected: $0) }),
                removeLabel: photo.isAsset ? "Delete from Photos" : "Move to Trash", enabled: allowed)

            VStack(alignment: .leading, spacing: 7) {
                if let q = photo.scores?.quality { bar("Overall", q, .green) }
                bar("Resolution", Double(photo.pixels) / maxPixels, .blue, "\(photo.width) × \(photo.height)")
                if let s = photo.scores { bar("Sharpness", s.sharpness / maxSharp, .purple) }
                if let a = photo.scores?.aesthetics { bar("Composition", (a + 1) / 2, .orange) }
                if let f = photo.scores?.face {
                    bar("Faces", f, .pink, "\(photo.scores?.faceCount ?? 0) found")
                }
                // Library photos whose original is in iCloud have no known size; showing "0 bytes" would mislead.
                if photo.size > 0 { bar("Detail kept", Double(photo.size) / maxSize, .teal, ByteFormat.string(photo.size)) }
            }

            if !photo.exactCopies.isEmpty {
                Label("\(photo.exactCopies.count) exact cop\(photo.exactCopies.count == 1 ? "y" : "ies") of this photo also exist. They're listed on the Duplicates screen.", systemImage: "square.on.square")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Modified \(photo.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            if !photo.isAsset {
                Text(photo.path.replacingOccurrences(of: model.home, with: "~"))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            HStack {
                if !allowed {
                    Label("Protected", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                if photo.isAsset {
                    Button("Open Photos") { LibrarySource.openPhotosApp() }
                } else {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: photo.path)) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(keep ? Color.green.opacity(0.6) : (chosen ? Color.red.opacity(0.5) : .clear), lineWidth: 2))
    }

    private func bar(_ label: String, _ value: Double, _ color: Color, _ trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            ProgressView(value: safeFraction(value)).tint(color)
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing) }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}
