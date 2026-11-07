import SwiftUI

// The "Photo clear-outs" screen. It lists Photos-library pictures that are often temporary (screenshots, burst
// extras, text-heavy photos), grouped by kind, and lets the user pick some. Removal is requested through
// `AppModel`, which asks Photos to delete them; Photos shows its own confirmation and keeps them in Recently Deleted.

struct ClearoutsView: View {
    @Environment(AppModel.self) private var model

    /// The clear-out photos currently ticked by the user.
    private var selected: [ClearoutPhoto] { model.clearouts.filter { model.clearoutSelection.contains($0.photo.path) } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Page.spacing) {
                header
                setup
                if model.clearoutState == .working { working }
                if model.clearoutState != .idle { CloudNote(count: model.clearoutProgress.skippedCloud) }
                if model.clearoutState == .done {
                    if !model.clearouts.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(ClearoutKind.allCases) { kind in
                                StatTile(value: "\(model.clearouts(of: kind).count)", label: kind.rawValue, color: .teal)
                            }
                        }
                        .arrives()
                    }
                    if model.clearouts.isEmpty {
                        ContentUnavailableView("Nothing to clear out", systemImage: "checkmark.seal",
                                               description: Text("No screenshots, text-heavy photos or burst extras were found."))
                    } else {
                        ForEach(ClearoutKind.allCases) { kind in
                            let items = model.clearouts(of: kind)
                            if !items.isEmpty { KindCard(kind: kind, items: items) }
                        }
                    }
                }
            }
            .pageBody()
        }
        .safeAreaInset(edge: .bottom) { if !selected.isEmpty { actionBar } }
        .navigationTitle("Photo clear-outs")
        .onAppear { model.refreshPhotoAuth() }
    }

    private var header: some View {
        ScreenHeader(title: "Photo clear-outs", subtitle: "Photos that were probably meant to be temporary: screenshots, meter readings, clock cards, receipts and burst extras.",
                     icon: "camera.viewfinder", colors: [.teal, .blue])
    }

    /// Search controls, or the Photos permission prompt when access has not been granted.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.canSearchLibrary {
                HStack {
                    Label("Looks through your Photos library on this Mac. Photos stored only in iCloud are skipped, so nothing is downloaded.", systemImage: "photo.on.rectangle")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.clearoutState == .working {
                        Button("Stop") { model.cancelClearouts() }
                    } else {
                        Button { model.findClearouts() } label: {
                            Label(model.clearoutState == .done ? "Look again" : "Find clear-outs", systemImage: "magnifyingglass")
                                .font(.headline).padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                    }
                }
            } else {
                HStack {
                    Text("Reclaim needs permission to look at your Photos library. It reads photos already on this Mac and never changes anything without you.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.photoAuth == .notDetermined {
                        Button("Allow access to Photos") { model.requestPhotoAccess() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Open Settings") { model.openPhotosPrivacySettings() }
                        Button("Restart Reclaim") { model.relaunch() }
                    }
                }
            }
        }
        .card()
    }

    /// Progress card for the two stages of `PhotoClearoutFinder` (listing, then reading pictures).
    private var working: some View {
        let p = model.clearoutProgress
        return VStack(alignment: .leading, spacing: 10) {
            Text(p.stage == 1 ? "Listing your photos…" : "Reading pictures for text…")
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.teal)
            Text(p.stage == 1
                ? "Photos already tags screenshots and bursts, so those come straight from the library."
                : "Apple's on-device text recogniser checks each remaining photo for readings, receipts and notes. Nothing leaves your Mac.")
                .font(.title3).foregroundStyle(.secondary)
            if p.total > 0 {
                ProgressView(value: safeFraction(Double(p.done), of: Double(p.total))).tint(.teal)
                Text("\(p.done.formatted()) of \(p.total.formatted()) photos").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.teal)
            }
            HStack(spacing: 12) {
                ForEach(ClearoutKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.found[kind] ?? 0)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.teal.opacity(0.16), .teal.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
    }

    /// Shown only when something is selected.
    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(selected.count) photo\(selected.count == 1 ? "" : "s") chosen").font(.headline)
                Text("They go to Recently Deleted in Photos, recoverable for about 30 days.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review and delete from Photos…") {
                model.requestPhotoRemoval(selected.map(\.photo), reason: "Photo clear-out")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One category (for example "Screenshots") with bulk-select shortcuts and a grid of its photos.
private struct KindCard: View {
    let kind: ClearoutKind
    let items: [ClearoutPhoto]
    @Environment(AppModel.self) private var model
    @State private var showAll = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 10)]

    var body: some View {
        let chosen = items.filter { model.clearoutSelection.contains($0.photo.path) }.count
        let old = items.filter { ($0.ageInDays() ?? 0) >= 30 }.count
        let shown = showAll ? items : Array(items.prefix(24))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.icon).font(.title2).foregroundStyle(.teal).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(kind.rawValue) · \(items.count)").font(.title3.bold())
                    Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                // One button that flips between choosing everything and clearing the choice.
                if chosen == 0 {
                    Button("Select all") { model.selectClearouts(kind) }
                } else {
                    Button("Clear choice") { model.clearClearoutSelection(kind) }
                }
                Button("Older than 30 days (\(old))") { model.selectClearouts(kind, olderThanDays: 30) }.disabled(old == 0)
                Spacer()
                if chosen > 0 { Text("\(chosen) chosen").font(.callout).foregroundStyle(.red) }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(shown) { item in tile(item) }
            }
            if items.count > shown.count {
                Button("Show all \(items.count)") { showAll = true }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(.teal).frame(width: 4).padding(.vertical, 12)
        }
    }

    /// One photo. Tapping toggles it, but only if `canTrash` says the item is allowed (for library photos, that
    /// Photos access has been granted).
    private func tile(_ item: ClearoutPhoto) -> some View {
        let chosen = model.clearoutSelection.contains(item.photo.path)
        let allowed = model.canTrash(item.photo.path)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if allowed { toggle(item, to: !chosen) }
            } label: {
                PhotoThumb(photo: item.photo, side: 150, fit: true)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? Color.red : .clear, lineWidth: 2.5))
                    .overlay(alignment: .topLeading) {
                        if chosen {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .red).font(.title3).padding(6)
                        }
                    }
            }
            .buttonStyle(.plain)
            Text(item.detail).font(.caption).lineLimit(1)
            Text(item.photo.created.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 150)
    }

    private func toggle(_ item: ClearoutPhoto, to on: Bool) {
        if on { model.clearoutSelection.insert(item.photo.path) } else { model.clearoutSelection.remove(item.photo.path) }
    }
}
