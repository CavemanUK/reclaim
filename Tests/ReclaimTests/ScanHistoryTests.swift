import Foundation
import Testing

@testable import Reclaim

private let GB: Int64 = 1 << 30
private let MB: Int64 = 1 << 20

private func record(
    daysAgo: Double, free: Int64, categories: [String: Int64] = [:], folders: [ScanRecord.Folder] = [], now: Date = Date()
) -> ScanRecord {
    ScanRecord(
        id: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), total: 245 * GB, free: free, dataUsed: 100 * GB,
        scannedBytes: 90 * GB, purgeable: 5 * GB, hidden: 5 * GB, snapshotCount: 0, categories: categories, folders: folders)
}

@Suite struct ScanComparisonTests {
    @Test func usedAndFreeMoveOppositely() {
        let older = record(daysAgo: 3, free: 100 * GB)
        let newer = record(daysAgo: 0, free: 97 * GB)
        let c = ScanComparison(older: older, newer: newer)
        #expect(c.usedChange == 3 * GB)
        #expect(c.freeChange == -3 * GB)
        #expect(abs(c.days - 3) < 0.001)
    }

    @Test func categoriesUnionAndSortByMovement() {
        let older = record(daysAgo: 7, free: 100 * GB, categories: ["Caches & logs": 2 * GB, "Applications": 10 * GB, "Trash": GB])
        let newer = record(daysAgo: 0, free: 95 * GB, categories: ["Caches & logs": 6 * GB, "Applications": 10 * GB, "Local AI models": 3 * GB])
        let c = ScanComparison(older: older, newer: newer)
        // Applications didn't move, so it is dropped as noise; the others keep their order of movement.
        #expect(c.categories.map(\.name) == ["Caches & logs", "Local AI models", "Trash"])
        #expect(c.biggestGrowth?.name == "Caches & logs")
        #expect(c.categories.first { $0.name == "Trash" }?.change == -GB)
        // A category new in the later scan counts from zero.
        #expect(c.categories.first { $0.name == "Local AI models" }?.before == 0)
    }

    @Test func foldersMatchByPathAndFlagEstimates() {
        let old = [
            ScanRecord.Folder(path: "/a/big", size: 2 * GB, category: "App data"),
            ScanRecord.Folder(path: "/a/gone", size: 500 * MB, category: "Caches & logs"),
        ]
        let new = [
            ScanRecord.Folder(path: "/a/big", size: 5 * GB, category: "App data"),
            ScanRecord.Folder(path: "/a/new", size: 800 * MB, category: "Developer tools"),
        ]
        let c = ScanComparison(older: record(daysAgo: 5, free: 90 * GB, folders: old), newer: record(daysAgo: 0, free: 86 * GB, folders: new))
        let byPath = Dictionary(uniqueKeysWithValues: c.folders.map { ($0.path, $0) })
        #expect(byPath["/a/big"]?.change == 3 * GB)
        #expect(byPath["/a/big"]?.isApproximate == false)
        #expect(byPath["/a/new"]?.change == 800 * MB)      // appeared: counted from nothing
        #expect(byPath["/a/new"]?.isApproximate == true)
        #expect(byPath["/a/gone"]?.change == -500 * MB)    // dropped away
        #expect(byPath["/a/gone"]?.isApproximate == true)
        #expect(c.grewFolders.count == 2 && c.shrankFolders.count == 1)
        #expect(c.folders.first?.path == "/a/big")          // biggest movement first
    }
}

@Suite struct ChartGeometryTests {
    @Test func axisLimitsAreRoundAndContainTheData() {
        for (lo, hi) in [(97.3, 112.8), (0.2, 0.9), (15.0, 15.0), (88.0, 240.0), (1.0, 1.4)] {
            let b = TrendChart.Geometry.niceBounds(min: lo, max: hi)
            #expect(b.lo <= lo && b.hi >= hi)
            #expect(b.hi > b.lo && b.step > 0)
            // The step is 1, 2 or 5 times a power of ten.
            let mantissa = b.step / pow(10, floor(log10(b.step)))
            #expect([1.0, 2.0, 5.0].contains { abs($0 - mantissa) < 1e-9 })
            // About two to eight gridlines, never hundreds.
            #expect((b.hi - b.lo) / b.step <= 8.0001)
        }
    }

    @Test func datesAndValuesMapInsideThePlot() {
        let now = Date()
        let points = [
            DrivePoint(date: now.addingTimeInterval(-10 * 86_400), total: 245 * GB, free: 100 * GB),
            DrivePoint(date: now, total: 245 * GB, free: 90 * GB),
        ]
        let plot = CGRect(x: 50, y: 10, width: 400, height: 200)
        let g = TrendChart.Geometry(plot: plot, points: points, scans: [])
        #expect(abs(g.x(points[0].date) - plot.minX) < 0.5)
        #expect(abs(g.x(points[1].date) - plot.maxX) < 0.5)
        for p in points {
            let y = g.y(p.free)
            #expect(y >= plot.minY - 0.5 && y <= plot.maxY + 0.5)
        }
        // More free space is drawn higher up (smaller y).
        #expect(g.y(points[0].free) < g.y(points[1].free))
    }

    @Test func aSinglePointStillHasAWidth() {
        let p = DrivePoint(date: Date(), total: 245 * GB, free: 100 * GB)
        let g = TrendChart.Geometry(plot: CGRect(x: 0, y: 0, width: 100, height: 100), points: [p], scans: [])
        #expect(g.tMax > g.tMin)
    }
}

@Suite struct BaselineTests {
    @Test func choosesPreviousWeekAndFirst() {
        let now = Date()
        let scans = [
            record(daysAgo: 30, free: 120 * GB, now: now),
            record(daysAgo: 9, free: 110 * GB, now: now),
            record(daysAgo: 2, free: 105 * GB, now: now),
            record(daysAgo: 0, free: 100 * GB, now: now),
        ]
        let latest = scans[3]
        #expect(TrendBaseline.previous.choose(for: latest, in: scans)?.id == scans[2].id)
        #expect(TrendBaseline.first.choose(for: latest, in: scans)?.id == scans[0].id)
        // Nine days ago is closer to "a week ago" than two days or thirty days.
        #expect(TrendBaseline.weekAgo.choose(for: latest, in: scans)?.id == scans[1].id)
    }

    @Test func nothingEarlierMeansNoBaseline() {
        let only = record(daysAgo: 0, free: 100 * GB)
        for kind in TrendBaseline.allCases { #expect(kind.choose(for: only, in: [only]) == nil) }
    }
}

@Suite struct FreedByReclaimTests {
    private func entry(_ daysAgo: Double, _ size: Int64, _ status: HistoryEntry.Status, now: Date) -> HistoryEntry {
        HistoryEntry(id: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), originalPath: "/x", trashPath: nil, size: size, reason: "t", status: status)
    }

    @Test func countsOnlyWhatStayedGoneInsideTheWindow() {
        let now = Date()
        let history = [
            entry(1, 2 * GB, .trashed, now: now),
            entry(2, GB, .deleted, now: now),
            entry(3, 500 * MB, .evicted, now: now),
            entry(2, 700 * MB, .restored, now: now),            // put back: not freed
            entry(10, 9 * GB, .trashed, now: now),               // before the window
        ]
        let freed = freedByReclaim(history, from: now.addingTimeInterval(-5 * 86_400), to: now)
        #expect(freed == 2 * GB + GB + 500 * MB)
    }
}

@Suite struct ScanHistoryStoreTests {
    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "reclaim-trend-\(UUID().uuidString)/trend.json")
    }

    @Test func roundTripsThroughDisk() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ScanHistoryStore(fileURL: file)
        store.record(record(daysAgo: 2, free: 100 * GB, categories: ["Trash": GB]))
        store.recordDrive(total: 245 * GB, free: 99 * GB)
        let reopened = ScanHistoryStore(fileURL: file)
        #expect(reopened.scans.count == 1)
        #expect(reopened.scans.first?.categories["Trash"] == GB)
        #expect(reopened.drive.count == 1)
    }

    @Test func twoScansInAMinuteKeepOnlyTheLatest() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ScanHistoryStore(fileURL: file)
        let now = Date()
        store.record(record(daysAgo: 0, free: 100 * GB, now: now.addingTimeInterval(-30)))
        store.record(record(daysAgo: 0, free: 99 * GB, now: now))
        #expect(store.scans.count == 1)
        #expect(store.scans.first?.free == 99 * GB)
    }

    @Test func scanCountIsCapped() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ScanHistoryStore(fileURL: file)
        let now = Date()
        for i in 0..<(ScanHistoryStore.maxScans + 10) {
            store.record(record(daysAgo: Double(ScanHistoryStore.maxScans + 10 - i), free: 100 * GB, now: now))
        }
        #expect(store.scans.count == ScanHistoryStore.maxScans)
        // The newest survive.
        #expect(store.scans.last?.date == store.scans.map(\.date).max())
    }

    @Test func driveReadingsAreThrottled() {
        let now = Date()
        let last = DrivePoint(date: now.addingTimeInterval(-3600), total: 245 * GB, free: 100 * GB)
        #expect(!ScanHistoryStore.shouldRecordDrive(last: last, free: 100 * GB - 10 * MB, now: now))   // too soon, barely moved
        #expect(ScanHistoryStore.shouldRecordDrive(last: last, free: 100 * GB - GB, now: now))          // moved by 1 GB
        #expect(ScanHistoryStore.shouldRecordDrive(last: DrivePoint(date: now.addingTimeInterval(-7 * 3600), total: 245 * GB, free: 100 * GB),
                                                   free: 100 * GB, now: now))                            // six hours passed
        #expect(ScanHistoryStore.shouldRecordDrive(last: nil, free: 1, now: now))
    }

    @Test func oldDrivePointsThinToOnePerDay() {
        // Pin "now" to noon so each day's eight hourly points stay inside one calendar day whatever time the
        // test runs (otherwise points near midnight legitimately fall on two days).
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        var points: [DrivePoint] = []
        // Eight points on each of three old days, plus four recent ones.
        for day in [60.0, 59.0, 58.0] {
            for h in 0..<8 { points.append(DrivePoint(date: now.addingTimeInterval(-day * 86_400 + Double(h) * 3600), total: 245 * GB, free: 100 * GB)) }
        }
        for h in 0..<4 { points.append(DrivePoint(date: now.addingTimeInterval(-Double(h) * 3600), total: 245 * GB, free: 90 * GB)) }
        let thinned = ScanHistoryStore.thinned(points, now: now)
        #expect(thinned.count == 3 + 4)
    }

    @Test func clearEmptiesEverything() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ScanHistoryStore(fileURL: file)
        store.record(record(daysAgo: 1, free: 100 * GB))
        store.recordDrive(total: 245 * GB, free: 100 * GB)
        store.clear()
        #expect(store.scans.isEmpty && store.drive.isEmpty)
        #expect(ScanHistoryStore(fileURL: file).scans.isEmpty)
    }
}
