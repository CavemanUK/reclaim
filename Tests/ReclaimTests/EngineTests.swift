import Foundation
import Testing

@testable import Reclaim

// The Command Line Tools ship Swift Testing without its Foundation overlay, so run with
// `scripts/test.sh` (it passes -disable-cross-import-overlays). Plain `swift test` fails to find _Testing_Foundation.

private func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "reclaim-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ bytes: [UInt8], to path: String) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(bytes))
}

private func randomBytes(_ n: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    return (0..<n).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
}

@Suite struct DuplicateFinderTests {
    @Test func findsOnlyTrueCopies() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = randomBytes(300_000, seed: 1)
        write(original, to: dir + "/Documents/photo.bin")
        write(original, to: dir + "/Downloads/photo.bin")
        write(original, to: dir + "/Downloads/photo copy.bin")
        write(randomBytes(300_000, seed: 2), to: dir + "/Other/samesize.bin")
        var tricky = original
        for i in 150_000..<150_008 { tricky[i] = 0x58 }   // same head and tail, different middle
        write(tricky, to: dir + "/Other/tricky.bin")
        write(randomBytes(1000, seed: 3), to: dir + "/Other/unique.bin")

        let groups = await DuplicateFinder().find(roots: [URL(fileURLWithPath: dir)], minSize: 1) { _ in }
        #expect(groups.count == 1)
        guard let g = groups.first else { return }
        #expect(g.files.count == 3)
        #expect(g.files.map(\.name).sorted() == ["photo copy.bin", "photo.bin", "photo.bin"])
        #expect(!g.files.contains { $0.name == "tricky.bin" || $0.name == "samesize.bin" })
        // Keeps the copy outside Downloads and not named "copy".
        #expect(g.suggestedKeep.hasSuffix("/Documents/photo.bin"))
        #expect(g.reclaimable == 600_000)
    }

    @Test func hardLinksCountOnce() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(randomBytes(50_000, seed: 9), to: dir + "/a.bin")
        try! FileManager.default.linkItem(atPath: dir + "/a.bin", toPath: dir + "/b.bin")
        let groups = await DuplicateFinder().find(roots: [URL(fileURLWithPath: dir)], minSize: 1) { _ in }
        #expect(groups.isEmpty)
    }
}

@Suite struct ActionLogTests {
    private func log(with entries: [HistoryEntry]) -> (ActionLog, String) {
        let dir = makeTempDir()
        let file = dir + "/history.json"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try! encoder.encode(entries).write(to: URL(fileURLWithPath: file))
        return (ActionLog(fileURL: URL(fileURLWithPath: file)), dir)
    }

    @Test func reconcileNoticesFinderEmptiedTheTrash() {
        let gone = HistoryEntry(
            id: UUID(), date: Date(), originalPath: "/nonexistent/original/a.txt",
            trashPath: "/nonexistent/.Trash/a.txt", size: 10, reason: "t", status: .trashed)
        let (log, dir) = log(with: [gone])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        log.reconcile()
        #expect(log.entries.first?.status == .deleted)
    }

    @Test func reconcileNoticesManualRestore() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write([1, 2, 3], to: dir + "/back.txt")
        let restored = HistoryEntry(
            id: UUID(), date: Date(), originalPath: dir + "/back.txt",
            trashPath: "/nonexistent/.Trash/back.txt", size: 3, reason: "t", status: .trashed)
        let (log, dir2) = log(with: [restored])
        defer { try? FileManager.default.removeItem(atPath: dir2) }
        log.reconcile()
        #expect(log.entries.first?.status == .restored)
    }

    @Test func purgeRefusesPathsOutsideTheTrash() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write([1], to: dir + "/victim.txt")
        let entry = HistoryEntry(
            id: UUID(), date: Date(), originalPath: "/x/victim.txt", trashPath: dir + "/victim.txt",
            size: 1, reason: "t", status: .trashed)
        let (log, dir2) = log(with: [entry])
        defer { try? FileManager.default.removeItem(atPath: dir2) }
        let result = log.purge([entry.id])
        #expect(result.freed == 0)
        #expect(result.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir + "/victim.txt"))
        #expect(log.entries.first?.status == .trashed)
    }

    @Test func permissionErrorsAreRecognised() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(TrashFailure.from(cocoa, path: "/x").isPermission)
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(!TrashFailure.from(missing, path: "/x").isPermission)
    }
}

@Suite struct RankingTests {
    private func photo(_ name: String, pixels: Int, size: Int64, sharp: Double, aes: Double?) -> PhotoInfo {
        var p = PhotoInfo(
            path: "/p/" + name, name: name, size: size, width: pixels, height: 1, modified: nil, created: nil, hash: 0)
        p.scores = PhotoScores(aesthetics: aes, sharpness: sharp, face: nil, faceCount: 0, quality: 0)
        return p
    }

    @Test func clearWinnerGetsNamedReasons() {
        var set = [
            photo("small.jpg", pixels: 1000, size: 50_000, sharp: 100, aes: 0.1),
            photo("big.jpg", pixels: 4000, size: 400_000, sharp: 150, aes: 0.5),
        ]
        let (ranked, reasons) = SimilarPhotoFinder.rank(&set)
        #expect(ranked.first?.name == "big.jpg")
        #expect(reasons.contains("Highest resolution"))
        #expect(reasons.contains("Sharpest"))
    }

    @Test func nearTiesAreCalledTies() {
        var set = [
            photo("a.jpg", pixels: 2000, size: 200_000, sharp: 100, aes: 0.40),
            photo("b.jpg", pixels: 2000, size: 199_000, sharp: 101, aes: 0.39),
        ]
        let (_, reasons) = SimilarPhotoFinder.rank(&set)
        #expect(reasons == ["Practically identical quality"])
    }

    @Test func nanScoresAreNeutralised() {
        var a = photo("a.jpg", pixels: 2000, size: 0, sharp: .nan, aes: .nan)
        var b = photo("b.jpg", pixels: 2000, size: 0, sharp: .nan, aes: nil)
        a.scores?.face = .nan
        b.scores?.face = nil
        var set = [a, b]
        let (ranked, reasons) = SimilarPhotoFinder.rank(&set)
        for p in ranked {
            #expect(p.scores?.quality.isFinite == true)
            #expect(p.scores?.sharpness.isFinite == true)
            #expect(p.scores?.aesthetics == nil)
            #expect(p.scores?.face == nil)
        }
        #expect(!reasons.isEmpty)
    }

    @Test func nanNeverReachesTheUI() {
        #expect(safeFraction(Double.nan) == 0)
        #expect(safeFraction(5, of: 0) == 0)
        #expect(safeFraction(5, of: 2) == 1)
        #expect(safeFraction(1, of: 4) == 0.25)
    }
}

@Suite struct TreemapTests {
    @Test func rectsTileTheWholeArea() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let sizes: [Double] = [50, 30, 10, 5, 3, 2]
        let rects = squarify(sizes: sizes, in: rect)
        #expect(rects.count == sizes.count)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(area - 120_000) < 1)
        for r in rects {
            #expect(r.minX >= -0.001 && r.maxX <= 400.001 && r.minY >= -0.001 && r.maxY <= 300.001)
        }
    }
}
