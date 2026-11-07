import Foundation
import Vision

// The near-duplicate photo pipeline. `SimilarPhotoFinder.find` narrows candidates cheaply, confirms them with
// a heavier model, removes exact copies (which belong to the Duplicates screen), and finally ranks each set so the
// UI can suggest which photo to keep. It works on any `PhotoSource`, so folders and the Photos library share
// the same code. It is read-only; trashing or deleting is done elsewhere after the user approves.

/// Quality measurements for one photo, used to rank the photos in a set.
struct PhotoScores: Hashable, Sendable {
    var aesthetics: Double?   // Apple, -1 ... 1
    var sharpness: Double     // Laplacian variance, higher is sharper
    var face: Double?         // Apple face capture quality, 0 ... 1 (nil when no faces)
    var faceCount: Int
    var quality: Double       // combined 0 ... 1, relative within a set
}

/// A photo that has been fingerprinted and is being compared with others.
struct PhotoInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    /// File path, or "photos://<id>" for a Photos library asset. Used as the selection key everywhere.
    let path: String
    let name: String
    let size: Int64
    let width: Int
    let height: Int
    let modified: Date?
    let created: Date?
    /// 64-bit perceptual (difference) hash from `Imaging.differenceHash`. Zero where no hash was needed.
    let hash: UInt64
    /// Filled in only after the set has been confirmed; nil if the image could not be read.
    var scores: PhotoScores?
    /// Byte-for-byte identical files folded into this photo. They are handled on the Duplicates screen.
    var exactCopies: [String] = []

    var pixels: Int { width * height }
    var assetID: String? { path.hasPrefix(PhotoItem.assetPrefix) ? String(path.dropFirst(PhotoItem.assetPrefix.count)) : nil }
    var isAsset: Bool { assetID != nil }

    init(item: PhotoItem, hash: UInt64) {
        path = item.key
        name = item.name
        size = item.size
        width = item.width
        height = item.height
        modified = item.modified
        created = item.created
        self.hash = hash
    }

    init(path: String, name: String, size: Int64, width: Int, height: Int, modified: Date?, created: Date?, hash: UInt64) {
        self.path = path
        self.name = name
        self.size = size
        self.width = width
        self.height = height
        self.modified = modified
        self.created = created
        self.hash = hash
    }
}

/// A confirmed set of similar photos, ordered best-first, with a recommendation of which to keep.
struct SimilarGroup: Identifiable, Sendable {
    let id = UUID()
    let photos: [PhotoInfo]
    var suggestedKeep: String
    /// Why the suggested photo won, in plain words.
    var reasons: [String]
    /// Largest Vision distance between linked photos. Lower means more alike.
    let looseness: Float
    /// Bytes freed by trashing everything except the suggested photo. Photos with unknown size count as 0.
    var reclaimable: Int64 {
        photos.filter { $0.path != suggestedKeep }.reduce(0) { $0 + $1.size }
    }
    /// True when some sizes are unknown because the originals are in iCloud (only an optimised copy is local).
    var sizesUnknown: Bool { photos.contains { $0.size == 0 } }
}

/// Progress report for the Similar Photos screen. `stage` runs 1 (reading and hashing), 2 (finding
/// candidate pairs), 3 (Vision confirmation) and 4 (choosing the best of each set).
struct PhotoProgress: Sendable {
    var stage: Int = 1
    var done: Int = 0
    var total: Int = 0
    var photosFound: Int = 0
    var lookalikes: Int = 0     // photos that have a look-alike candidate
    var sets: Int = 0           // confirmed sets so far
    var currentPath: String = ""
    var skippedCloud: Int = 0   // iCloud-only photos left alone so nothing gets downloaded
}

/// How alike two photos must be to be grouped. Each level sets a limit for both filtering stages.
enum Strictness: String, CaseIterable, Identifiable, Sendable {
    case strict = "Strict"
    case balanced = "Balanced"
    case loose = "Loose"

    var id: String { rawValue }
    /// Largest number of differing bits between two perceptual hashes for a pair to become a candidate.
    var hammingLimit: Int {
        switch self { case .strict: 6; case .balanced: 10; case .loose: 14 }
    }
    /// Largest Vision feature-print distance (lower is more alike) for a candidate pair to be confirmed.
    var visionLimit: Double {
        switch self { case .strict: 0.20; case .balanced: 0.40; case .loose: 0.60 }
    }
    var blurb: String {
        switch self {
        case .strict: "Same photo saved twice, resized or recompressed."
        case .balanced: "Also catches burst shots and tiny edits."
        case .loose: "Includes similar compositions. Review carefully."
        }
    }
}

/// Lets a `VNFeaturePrintObservation`, which is not declared `Sendable`, cross the thread boundary.
/// Observations are never mutated after creation.
private struct PrintBox: @unchecked Sendable {
    let observation: VNFeaturePrintObservation
}

/// Near-duplicate detector, entirely on this Mac, for any `PhotoSource` (folders or the Photos library):
/// 1. A cheap perceptual hash groups likely candidates.
/// 2. Apple's Vision feature print confirms each pair before it is shown.
/// 3. Byte-identical copies are folded out (they belong to the Duplicates screen).
/// 4. Apple's aesthetics and face-quality models, plus a sharpness check, pick the best of each set.
///
/// Why this shape: the perceptual hash is a few bits per photo and can be compared for every pair in memory
/// quickly, but it can also match images that merely look alike at 9x8 pixels. The Vision feature print
/// is a much better judge of similarity but slower to compute, so it is computed only for photos that
/// already have a hash-level candidate. Pairs that pass both tests are linked, and linked photos form a set
/// (so two photos in one set are connected through a chain, not necessarily directly alike). Byte-identical
/// copies are folded out before scoring so the ranking compares genuinely different files.
final class SimilarPhotoFinder: @unchecked Sendable {
    let cancelFlag = CancelFlag()
    func cancel() { cancelFlag.cancel() }

    // MARK: - Pipeline

    /// Searches photos in ordinary folders. Convenience wrapper around `find(source:strictness:progress:)`.
    func find(
        roots: [URL], strictness: Strictness, progress: @escaping @Sendable (PhotoProgress) -> Void
    ) async -> [SimilarGroup] {
        await find(source: FileSource(roots: roots), strictness: strictness, progress: progress)
    }

    /// Runs the full pipeline on `source` and returns the sets of similar photos, largest saving first.
    ///
    /// The stages are numbered as in `PhotoProgress`. Returns an empty array if nothing similar is found or the
    /// search is cancelled.
    func find(
        source: any PhotoSource, strictness: Strictness, progress: @escaping @Sendable (PhotoProgress) -> Void
    ) async -> [SimilarGroup] {
        let flag = cancelFlag
        progress(PhotoProgress(stage: 1))
        let items = await runBlocking {
            source.items(cancel: flag) { found, path in
                progress(PhotoProgress(stage: 1, photosFound: found, currentPath: path))
            }
        }
        if flag.isCancelled || items.isEmpty { return [] }
        // Adds the source's running count of skipped cloud-only photos to every progress report.
        let report: @Sendable (PhotoProgress) -> Void = { p in
            var q = p
            q.skippedCloud = source.skippedCloud
            progress(q)
        }
        report(PhotoProgress(stage: 1, done: 0, total: items.count, photosFound: items.count))

        // Stage 1: fingerprint every photo. Image decoding (and, later, Vision) blocks its caller, so it runs through
        // `blockingParallelMap` on a few dedicated threads inside `runBlocking`, not as tasks on Swift's cooperative pool.
        let infos = await runBlocking {
            blockingParallelMap(items, width: source.parallelism, cancel: flag, onProgress: { n in
                if n % 20 == 0 || n == items.count {
                    report(PhotoProgress(stage: 1, done: n, total: items.count, photosFound: items.count))
                }
            }) { item -> PhotoInfo? in
                guard let thumb = source.image(for: item, maxPixel: 128) else { return nil }
                var fixed = item
                // Some sources do not know the dimensions up front; take them from the decoded thumbnail.
                if fixed.width == 0 || fixed.height == 0 {
                    fixed = PhotoItem(key: item.key, name: item.name, size: item.size, width: thumb.width, height: thumb.height,
                                      created: item.created, modified: item.modified)
                }
                return PhotoInfo(item: fixed, hash: Imaging.differenceHash(thumb))
            }
        }
        let photos = infos.compactMap { $0 ?? nil }
        if flag.isCancelled || photos.count < 2 { return [] }

        // Stage 2: candidate pairs by hash distance.
        report(PhotoProgress(stage: 2, photosFound: photos.count))
        let limit = strictness.hammingLimit
        let hashes = photos.map(\.hash)
        let edges = await runBlocking { Self.candidateEdges(hashes: hashes, limit: limit) }
        if edges.isEmpty || flag.isCancelled { return [] }

        // Stage 3: confirm with Vision feature prints (only for photos that have a candidate).
        // Only photos that have at least one hash-level candidate need the (slower) feature print.
        let involved = Array(Set(edges.flatMap { [$0.0, $0.1] })).sorted()
        report(PhotoProgress(stage: 3, total: involved.count, photosFound: photos.count, lookalikes: involved.count))
        let prints = await runBlocking {
            blockingParallelMap(involved, width: 3, cancel: flag, onProgress: { n in
                if n % 5 == 0 || n == involved.count {
                    report(PhotoProgress(stage: 3, done: n, total: involved.count, photosFound: photos.count, lookalikes: involved.count))
                }
            }) { i -> PrintBox? in
                guard let img = source.image(for: Self.item(photos[i]), maxPixel: 360),
                    let obs = Imaging.featurePrint(of: img)
                else { return nil }
                return PrintBox(observation: obs)
            }
        }
        if flag.isCancelled { return [] }
        var printByIndex: [Int: PrintBox] = [:]
        for (i, box) in zip(involved, prints) { if let box = box ?? nil { printByIndex[i] = box } }

        let maxDistance = Float(strictness.visionLimit)
        // Union-find over photo indices: each confirmed pair merges two photos into the same set.
        var parent = Array(0..<photos.count)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        // Remembers the largest confirmed distance per photo; the group's `looseness` is the maximum over its members.
        var worstByPhoto: [Int: Float] = [:]
        for (a, b) in edges {
            guard let pa = printByIndex[a], let pb = printByIndex[b] else { continue }
            var distance: Float = 0
            guard (try? pa.observation.computeDistance(&distance, to: pb.observation)) != nil, distance <= maxDistance
            else { continue }
            let ra = root(a), rb = root(b)
            if ra != rb { parent[ra] = rb }
            worstByPhoto[a] = max(worstByPhoto[a] ?? 0, distance)
            worstByPhoto[b] = max(worstByPhoto[b] ?? 0, distance)
        }

        var members: [Int: [Int]] = [:]
        for i in 0..<photos.count { members[root(i), default: []].append(i) }
        let rawSets = members.values.filter { $0.count > 1 }
        if rawSets.isEmpty { return [] }

        // Fill in expensive details (real byte size for library photos) for set members only, because getting
        // one means reading the original. Then fold byte-identical copies into one representative.
        let (detailed, folded) = await runBlocking { () -> ([PhotoInfo], (sets: [[Int]], exact: [Int: [String]])) in
            var filled = photos
            for i in rawSets.flatMap({ $0 }) {
                let d = source.details(for: Self.item(filled[i]))
                filled[i] = PhotoInfo(item: d, hash: filled[i].hash)
            }
            let fold = Self.foldExactCopies(sets: rawSets, photos: filled, cancel: flag) { item in
                source.exactKey(for: item, cancel: flag)
            }
            return (filled, fold)
        }
        if flag.isCancelled { return [] }
        let sets = folded.sets
        let exactByIndex = folded.exact
        if sets.isEmpty { return [] }

        // Stage 4: pick the best of each set.
        let toScore = sets.flatMap { $0 }
        report(PhotoProgress(stage: 4, total: toScore.count, photosFound: photos.count, lookalikes: involved.count, sets: sets.count))
        // This stage uses Vision's async requests, so it runs on the cooperative pool with a small width of 4.
        let scored = await concurrentMapAsync(toScore.map { detailed[$0] }, width: 4, cancel: flag, onProgress: { n in
            if n % 5 == 0 || n == toScore.count {
                report(PhotoProgress(stage: 4, done: n, total: toScore.count, photosFound: photos.count,
                                     lookalikes: involved.count, sets: sets.count))
            }
        }) { photo -> PhotoScores? in
            // Library photos may only have a smaller render on this Mac; score the largest one available.
            let item = Self.item(photo)
            guard let img = await runBlocking({ () -> CGImage? in
                for size in [1024, 640, 360] {
                    if let i = source.image(for: item, maxPixel: size) { return i }
                }
                return nil
            }) else { return nil }
            let apple = await Imaging.appleScores(img)
            return PhotoScores(aesthetics: apple.aesthetics, sharpness: Imaging.sharpness(img), face: apple.face,
                               faceCount: apple.faceCount, quality: 0)
        }
        if flag.isCancelled { return [] }
        var scoreByIndex: [Int: PhotoScores] = [:]
        for (i, s) in zip(toScore, scored) { if let s = s ?? nil { scoreByIndex[i] = s } }

        var groups: [SimilarGroup] = []
        for idx in sets {
            var list = idx.map { i -> PhotoInfo in
                var p = detailed[i]
                p.scores = scoreByIndex[i]
                p.exactCopies = exactByIndex[i] ?? []
                return p
            }
            let (ranked, reasons) = Self.rank(&list)
            let loose = idx.compactMap { worstByPhoto[$0] }.max() ?? 0
            groups.append(SimilarGroup(photos: ranked, suggestedKeep: ranked[0].path, reasons: reasons, looseness: loose))
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Converts back to the lightweight source-level type that `PhotoSource` methods take.
    private static func item(_ p: PhotoInfo) -> PhotoItem {
        PhotoItem(key: p.path, name: p.name, size: p.size, width: p.width, height: p.height, created: p.created, modified: p.modified)
    }

    /// Within each set, groups photos of equal size and confirms identical content with `exactKey`.
    /// Returns the sets reduced to one representative per identical cluster (dropping sets left with one photo),
    /// plus the keys of the copies folded into each representative. Unknown sizes (0) are never treated as equal.
    ///
    /// A size of 0 means "unknown" (see `PhotoSource`), and unknown sizes are left alone because there is nothing
    /// safe to compare. Exact-key checks (a file hash or the Photos original) run only for photos of identical size.
    static func foldExactCopies(
        sets: [[Int]], photos: [PhotoInfo], cancel: CancelFlag, exactKey: (PhotoItem) -> String?
    ) -> (sets: [[Int]], exact: [Int: [String]]) {
        var outSets: [[Int]] = []
        var exact: [Int: [String]] = [:]
        for set in sets {
            var bySize: [Int64: [Int]] = [:]
            for i in set { bySize[photos[i].size, default: []].append(i) }
            var kept: [Int] = []
            for (size, sameSize) in bySize {
                if sameSize.count == 1 || size <= 0 { kept.append(contentsOf: sameSize); continue }
                var byHash: [String: [Int]] = [:]
                var unknown: [Int] = []
                for i in sameSize {
                    if let h = exactKey(item(photos[i])) { byHash[h, default: []].append(i) } else { unknown.append(i) }
                }
                kept.append(contentsOf: unknown)
                for (_, cluster) in byHash {
                    // Representative: the copy we would most want to keep (not in Downloads, not named "copy", oldest).
                    let ranked = cluster.sorted {
                        let a = DupFile(path: photos[$0].path, size: photos[$0].size, modified: photos[$0].modified, created: photos[$0].created)
                        let b = DupFile(path: photos[$1].path, size: photos[$1].size, modified: photos[$1].modified, created: photos[$1].created)
                        return DuplicateFinder.lexLess(DuplicateFinder.keepScore(a), DuplicateFinder.keepScore(b))
                    }
                    kept.append(ranked[0])
                    if ranked.count > 1 { exact[ranked[0]] = ranked.dropFirst().map { photos[$0].path } }
                }
            }
            if kept.count > 1 { outSets.append(kept.sorted()) }
        }
        return (outSets, exact)
    }

    /// Orders a set best-first, blending resolution, sharpness, Apple's aesthetics score and face quality.
    /// Returns the ranked photos and plain-language reasons the first one won.
    ///
    /// Each score is normalised against the best in the set, so the quality number is only meaningful within one set.
    /// Weights favour face quality when any photo has faces, otherwise sharpness and aesthetics. Resolution and
    /// "detail" (bytes per pixel, i.e. how little the file is compressed) are blended in with lower weights.
    /// Equal quality falls back to higher resolution, then the earliest creation date.
    /// The reason shown when the top two photos score almost the same. The UI matches this text to style it as a tie.
    static let tieReason = "Practically identical quality"

    static func rank(_ photos: inout [PhotoInfo]) -> ([PhotoInfo], [String]) {
        let maxPixels = Double(max(1, photos.map(\.pixels).max() ?? 1))
        let maxSharp = max(1e-6, photos.compactMap { $0.scores?.sharpness }.max() ?? 1)
        let anyFaces = photos.contains { ($0.scores?.face) != nil }
        func bpp(_ p: PhotoInfo) -> Double { Double(p.size) / Double(max(1, p.pixels)) }
        let maxBpp = max(1e-9, photos.map(bpp).max() ?? 1)
        let sizesKnown = photos.allSatisfy { $0.size > 0 }

        for i in photos.indices {
            guard var s = photos[i].scores else { continue }
            // Belt and braces: no NaN may reach a comparison or the UI.
            if !s.sharpness.isFinite { s.sharpness = 0 }
            if let a = s.aesthetics, !a.isFinite { s.aesthetics = nil }
            if let f = s.face, !f.isFinite { s.face = nil }
            let res = Double(photos[i].pixels) / maxPixels
            let sharp = s.sharpness / maxSharp
            let aes = ((s.aesthetics ?? 0) + 1) / 2
            if sizesKnown {
                // Bytes per pixel is a proxy for how little the file has been compressed.
                let detail = bpp(photos[i]) / maxBpp
                if anyFaces, let face = s.face {
                    s.quality = 0.30 * face + 0.22 * sharp + 0.22 * aes + 0.13 * res + 0.13 * detail
                } else if anyFaces {
                    s.quality = 0.22 * sharp + 0.22 * aes + 0.13 * res + 0.13 * detail
                } else {
                    s.quality = 0.28 * sharp + 0.28 * aes + 0.20 * res + 0.24 * detail
                }
            } else {
                // Some library photos have no known byte size (the original is in iCloud). Leave "detail" out and
                // spread its weight over the other signals; substituting resolution for it would count resolution twice.
                if anyFaces, let face = s.face {
                    s.quality = 0.35 * face + 0.25 * sharp + 0.25 * aes + 0.15 * res
                } else if anyFaces {
                    s.quality = 0.25 * sharp + 0.25 * aes + 0.15 * res
                } else {
                    s.quality = 0.40 * sharp + 0.35 * aes + 0.25 * res
                }
            }
            if !s.quality.isFinite { s.quality = 0 }
            photos[i].scores = s
        }
        photos.sort {
            let a = $0.scores?.quality ?? 0, b = $1.scores?.quality ?? 0
            if abs(a - b) > 1e-6 { return a > b }
            if $0.pixels != $1.pixels { return $0.pixels > $1.pixels }
            return ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture)
        }

        var reasons: [String] = []
        if let best = photos.first, photos.count > 1 {
            let others = photos.dropFirst()
            if let bs = best.scores {
                if others.allSatisfy({ best.pixels > $0.pixels }) { reasons.append("Highest resolution") }
                if others.allSatisfy({ bs.sharpness > ($0.scores?.sharpness ?? 0) * 1.15 }) { reasons.append("Sharpest") }
                if sizesKnown, others.allSatisfy({ bpp(best) > bpp($0) * 1.2 }) { reasons.append("Least compressed") }
                if let f = bs.face, others.allSatisfy({ f > ($0.scores?.face ?? 0) + 0.02 }) { reasons.append("Best captured faces") }
                if let a = bs.aesthetics, others.allSatisfy({ a > ($0.scores?.aesthetics ?? -1) + 0.02 }) { reasons.append("Best composition") }
            }
            if reasons.isEmpty {
                let gap = (best.scores?.quality ?? 0) - (photos[1].scores?.quality ?? 0)
                reasons.append(gap < 0.03 ? Self.tieReason : "Best overall")
            }
        }
        return (photos, reasons)
    }

    /// Compares every pair of hashes and returns the pairs within `limit` differing bits. This is quadratic in the
    /// number of photos, so it is split into chunks across threads and capped at 3 million pairs to bound memory.
    private static func candidateEdges(hashes: [UInt64], limit: Int) -> [(Int, Int)] {
        let n = hashes.count
        let lock = NSLock()
        var all: [(Int, Int)] = []
        let cap = 3_000_000
        let stride = 64
        let chunks = (n + stride - 1) / stride
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var local: [(Int, Int)] = []
            let start = chunk * stride
            for i in start..<min(start + stride, n) {
                let hi = hashes[i]
                var j = i + 1
                while j < n {
                    if (hi ^ hashes[j]).nonzeroBitCount <= limit { local.append((i, j)) }
                    j += 1
                }
            }
            lock.lock()
            if all.count < cap { all.append(contentsOf: local) }
            lock.unlock()
        }
        return all
    }
}
