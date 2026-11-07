import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Photos

/// One photo, wherever it lives. `key` is a file path, or "photos://<localIdentifier>" for a Photos library asset.
struct PhotoItem: Hashable, Sendable {
    let key: String
    let name: String
    var size: Int64
    let width: Int
    let height: Int
    let created: Date?
    let modified: Date?

    static let assetPrefix = "photos://"
    var assetID: String? { key.hasPrefix(Self.assetPrefix) ? String(key.dropFirst(Self.assetPrefix.count)) : nil }
    var isAsset: Bool { assetID != nil }
}

/// Where similar-photo search reads from. Everything is blocking and must be called off the main thread.
protocol PhotoSource: AnyObject, Sendable {
    var label: String { get }
    /// How many analysis images to request at once.
    var parallelism: Int { get }
    /// Photos left alone because they live only in iCloud (reading them would start a download).
    var skippedCloud: Int { get }
    func items(cancel: CancelFlag, progress: @Sendable (_ found: Int, _ currentPath: String) -> Void) -> [PhotoItem]
    /// Downscaled image for analysis. nil when unreadable or cloud-only.
    func image(for item: PhotoItem, maxPixel: Int) -> CGImage?
    /// Fills in anything expensive that was skipped during listing (the real byte size, for the library).
    func details(for item: PhotoItem) -> PhotoItem
    /// Identifies byte-identical content; only called for items that share a size. nil = unknown.
    func exactKey(for item: PhotoItem, cancel: CancelFlag) -> String?
}

// MARK: - Files on disk

final class FileSource: PhotoSource, @unchecked Sendable {
    let label = "Folders"
    let parallelism = ProcessInfo.processInfo.activeProcessorCount
    private(set) var skippedCloud = 0
    private let roots: [URL]

    init(roots: [URL]) { self.roots = roots }

    func items(cancel: CancelFlag, progress: @Sendable (Int, String) -> Void) -> [PhotoItem] {
        var seen = Set<String>()
        var out: [PhotoItem] = []
        var visited = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        for root in roots {
            guard
                let en = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants, .skipsHiddenFiles])
            else { continue }
            for case let url as URL in en {
                if cancel.isCancelled { return [] }
                if DuplicateFinder.skipDirectoryNames.contains(url.lastPathComponent) {
                    en.skipDescendants()
                    continue
                }
                visited += 1
                if visited % 100 == 0 { progress(out.count, url.deletingLastPathComponent().path) }
                guard Imaging.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                if Imaging.isCloudOnly(path: url.path) { skippedCloud += 1; continue }
                guard seen.insert(url.path).inserted else { continue }
                let dims = Imaging.pixelSize(path: url.path) ?? (0, 0)
                out.append(PhotoItem(
                    key: url.path, name: url.lastPathComponent, size: Int64(v.fileSize ?? 0), width: dims.width,
                    height: dims.height, created: v.creationDate, modified: v.contentModificationDate))
            }
        }
        return out
    }

    func image(for item: PhotoItem, maxPixel: Int) -> CGImage? { Imaging.thumbnail(path: item.key, maxPixel: maxPixel) }
    func details(for item: PhotoItem) -> PhotoItem { item }
    func exactKey(for item: PhotoItem, cancel: CancelFlag) -> String? { DuplicateFinder.fullHash(path: item.key, cancel: cancel) }
}

// MARK: - The Photos app library

/// Reads the user's Photos library through Apple's PhotoKit, the supported route. Originals are read only when
/// they are already on this Mac, never downloaded. Deletion asks Photos, which shows its own confirmation and
/// keeps the photos in Recently Deleted for 30 days.
final class LibrarySource: PhotoSource, @unchecked Sendable {
    let label = "Photos library"
    let parallelism = 4
    private(set) var skippedCloud = 0
    private var assets: [String: PHAsset] = [:]
    private let lock = NSLock()
    private var dataHashes: [String: (size: Int64, hash: String)] = [:]

    static var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    func items(cancel: CancelFlag, progress: @Sendable (Int, String) -> Void) -> [PhotoItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.includeHiddenAssets = false
        let fetch = PHAsset.fetchAssets(with: options)
        var out: [PhotoItem] = []
        var map: [String: PHAsset] = [:]
        withoutActuallyEscaping(progress) { progress in
            fetch.enumerateObjects { asset, index, stop in
                if cancel.isCancelled { stop.pointee = true; return }
                let id = asset.localIdentifier
                map[id] = asset
                let name = PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename
                    ?? "Photo \(index + 1)"
                out.append(PhotoItem(
                    key: PhotoItem.assetPrefix + id, name: name, size: 0, width: asset.pixelWidth, height: asset.pixelHeight,
                    created: asset.creationDate, modified: asset.modificationDate))
                if index % 200 == 0 { progress(out.count, "Photos library") }
            }
        }
        lock.lock(); assets = map; lock.unlock()
        return out
    }

    private func asset(for item: PhotoItem) -> PHAsset? {
        guard let id = item.assetID else { return nil }
        lock.lock(); let a = assets[id]; lock.unlock()
        return a ?? Self.asset(id)
    }

    private static func localOnlyOptions() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.isNetworkAccessAllowed = false
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .exact
        return o
    }

    func image(for item: PhotoItem, maxPixel: Int) -> CGImage? {
        guard let asset = asset(for: item) else { return nil }
        var result: CGImage?
        var inCloud = false
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel), contentMode: .aspectFit,
            options: Self.localOnlyOptions()
        ) { image, info in
            result = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
        }
        // Count a photo as "cloud-only" only when even the smallest render is missing (the first-stage request).
        // Larger renders are often absent for optimised photos, and callers fall back to smaller ones.
        if result == nil, inCloud, maxPixel <= 128 {
            lock.lock(); skippedCloud += 1; lock.unlock()
        }
        return result
    }

    /// Reads the original's bytes (local only) once, recording size and content hash.
    private func originalData(for item: PhotoItem) -> (size: Int64, hash: String)? {
        guard let id = item.assetID else { return nil }
        lock.lock()
        if let cached = dataHashes[id] { lock.unlock(); return cached }
        lock.unlock()
        guard let asset = asset(for: item) else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.version = .current
        var found: (Int64, String)?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data else { return }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            found = (Int64(data.count), digest)
        }
        if let found {
            lock.lock(); dataHashes[id] = found; lock.unlock()
        }
        return found
    }

    func details(for item: PhotoItem) -> PhotoItem {
        var copy = item
        if let d = originalData(for: item) { copy.size = d.size }
        return copy
    }

    func exactKey(for item: PhotoItem, cancel: CancelFlag) -> String? { originalData(for: item)?.hash }

    /// Asks Photos to delete the assets. Photos shows its own confirmation; the user can still say no there.
    static func delete(assetIDs: [String]) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(fetch) }
    }

    nonisolated(unsafe) private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        c.totalCostLimit = 300 << 20
        return c
    }()

    /// Thumbnail for display (local only, never downloads). Cached and bounded.
    static func thumbnail(assetID: String, side: CGFloat) async -> NSImage? {
        let key = "\(assetID)@\(Int(side))" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let asset = asset(assetID) else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            nonisolated(unsafe) var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side * 2, height: side * 2), contentMode: .aspectFit, options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded && image != nil { return }   // a better one is coming
                if !resumed { resumed = true; continuation.resume(returning: image) }
            }
        }
        if let image {
            let px = Int(image.size.width * image.size.height * 4)
            thumbCache.setObject(image, forKey: key, cost: max(1, px))
        }
        return image
    }

    static func openPhotosApp() {
        if let url = URL(string: "photos://") { NSWorkspace.shared.open(url) }
    }
}
