import Foundation
import Photos

/// Collections of photos people often mean to be temporary.
enum ClearoutKind: String, CaseIterable, Identifiable, Sendable {
    case screenshots = "Screenshots"
    case text = "Text & readings"
    case bursts = "Burst extras"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .text: "doc.text.viewfinder"
        case .bursts: "square.stack.3d.down.right"
        }
    }

    var explanation: String {
        switch self {
        case .screenshots:
            "Screenshots, as tagged by Photos. Often taken to remember something briefly, then forgotten."
        case .text:
            "Photos that are mostly text or numbers: meter readings, clock cards, receipts, documents, labels and notes. Spotted on this Mac by Apple's text recogniser; nothing is sent anywhere."
        case .bursts:
            "Extra frames from burst shots. Photos keeps every frame; usually only the chosen one matters."
        }
    }
}

struct ClearoutPhoto: Identifiable, Hashable, Sendable {
    var id: String { photo.path }
    let photo: PhotoInfo
    let kind: ClearoutKind
    /// A short reason, e.g. "mostly numbers" or "receipt".
    let detail: String

    func ageInDays(now: Date = Date()) -> Int? {
        guard let created = photo.created else { return nil }
        return Calendar.current.dateComponents([.day], from: created, to: now).day
    }
}

struct ClearoutProgress: Sendable {
    var stage: Int = 1          // 1 listing, 2 reading pictures
    var done: Int = 0
    var total: Int = 0
    var found: [ClearoutKind: Int] = [:]
    var skippedCloud: Int = 0
}

/// Finds clear-out candidates in the Photos library. Read-only; deletion goes through Photos separately.
final class PhotoClearoutFinder: @unchecked Sendable {
    let cancelFlag = CancelFlag()
    func cancel() { cancelFlag.cancel() }

    private static let textLabels: Set<String> = [
        "document", "receipt", "paper", "text", "whiteboard", "menu", "ticket", "newspaper", "magazine", "book",
        "envelope", "letter", "sign", "label", "business_card", "calendar", "map", "blackboard", "poster",
    ]

    func find(progress: @escaping @Sendable (ClearoutProgress) -> Void) async -> [ClearoutPhoto] {
        let flag = cancelFlag
        let source = LibrarySource()
        progress(ClearoutProgress(stage: 1))

        // Listing, with Photos' own tags.
        let listed = await runBlocking { () -> [(PhotoItem, PHAssetMediaSubtype, Bool)] in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            // Photos hides the unpicked frames of a burst by default; those are exactly the extras.
            options.includeAllBurstAssets = true
            let fetch = PHAsset.fetchAssets(with: options)
            var out: [(PhotoItem, PHAssetMediaSubtype, Bool)] = []
            fetch.enumerateObjects { asset, index, stop in
                if flag.isCancelled { stop.pointee = true; return }
                let name = PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename ?? "Photo \(index + 1)"
                let item = PhotoItem(
                    key: PhotoItem.assetPrefix + asset.localIdentifier, name: name, size: 0, width: asset.pixelWidth,
                    height: asset.pixelHeight, created: asset.creationDate, modified: asset.modificationDate)
                // The extras of a burst: not the representative frame, and not one the user (or Photos) picked.
                let burstExtra = asset.burstIdentifier != nil && !asset.representsBurst && asset.burstSelectionTypes.isEmpty
                out.append((item, asset.mediaSubtypes, burstExtra))
            }
            return out
        }
        if flag.isCancelled { return [] }

        var results: [ClearoutPhoto] = []
        var toRead: [PhotoItem] = []
        for (item, subtypes, burstExtra) in listed {
            let info = PhotoInfo(item: item, hash: 0)
            if subtypes.contains(.photoScreenshot) {
                results.append(ClearoutPhoto(photo: info, kind: .screenshots, detail: "Screenshot"))
            } else if burstExtra {
                results.append(ClearoutPhoto(photo: info, kind: .bursts, detail: "Burst frame"))
            } else {
                toRead.append(item)
            }
        }
        var counts = Dictionary(grouping: results, by: \.kind).mapValues(\.count)
        progress(ClearoutProgress(stage: 2, done: 0, total: toRead.count, found: counts))

        // Reading pictures for text. Local copies only; cloud-only photos are skipped.
        let countsSnapshot = counts
        let pending = toRead
        let read = await runBlocking {
            blockingParallelMap(pending, width: 3, cancel: flag, onProgress: { n in
                if n % 10 == 0 || n == pending.count {
                    progress(ClearoutProgress(stage: 2, done: n, total: pending.count, found: countsSnapshot, skippedCloud: source.skippedCloud))
                }
            }) { item -> ClearoutPhoto? in
                guard let img = source.image(for: item, maxPixel: 768) ?? source.image(for: item, maxPixel: 128) else { return nil }
                let text = Imaging.textAmount(img)
                let labels = Imaging.labels(img)
                let labelHit = labels.first { Self.textLabels.contains($0) }
                let detail: String?
                if text.characters >= 12, text.digits * 2 >= text.characters {
                    detail = "Mostly numbers (\(text.digits) digits)"
                } else if text.characters >= 40 {
                    detail = "Lots of text (\(text.characters) characters)"
                } else if let labelHit, text.characters >= 8 {
                    detail = labelHit.replacingOccurrences(of: "_", with: " ").capitalized
                } else {
                    detail = nil
                }
                guard let detail else { return nil }
                return ClearoutPhoto(photo: PhotoInfo(item: item, hash: 0), kind: .text, detail: detail)
            }
        }
        if flag.isCancelled { return [] }
        for case let hit?? in read { results.append(hit) }
        counts = Dictionary(grouping: results, by: \.kind).mapValues(\.count)
        progress(ClearoutProgress(stage: 2, done: pending.count, total: pending.count, found: counts, skippedCloud: source.skippedCloud))

        return results.sorted { ($0.photo.created ?? .distantPast) > ($1.photo.created ?? .distantPast) }
    }
}
