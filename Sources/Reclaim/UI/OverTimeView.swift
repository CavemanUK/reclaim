// The "Over time" screen: a free-space chart, what grew and shrank since an earlier scan, and the scan history.
//
// Data comes from `ScanHistoryStore` (see Core/ScanHistory.swift) through `AppModel.scanRecords` and
// `AppModel.drivePoints`. The chart is drawn by hand with `Canvas` rather than Apple's Charts framework, whose
// SwiftUI overlay is not reliable in builds made with only the Command Line Tools.

import SwiftUI

/// The Over time screen: summary tiles, the free-space chart, what changed between two scans, and the scan list.
/// It holds only display choices (which baseline, how much of the timeline); the data comes from `AppModel`.
struct OverTimeView: View {
    @Environment(AppModel.self) private var model
    /// Which earlier scan the latest one is compared with.
    @State private var baseline: TrendBaseline = .previous
    /// How much of the timeline the chart shows.
    @State private var range: ChartRange = .days90
    /// Whether the "clear history" confirmation dialog is showing.
    @State private var confirmClear = false

    /// How much of the timeline the chart shows.
    enum ChartRange: String, CaseIterable, Identifiable {
        case days30 = "30 days", days90 = "90 days", all = "All"
        var id: String { rawValue }
        /// The length of the window in days, or nil for everything.
        var days: Double? {
            switch self {
            case .days30: 30
            case .days90: 90
            case .all: nil
            }
        }
    }

    /// The latest scan against the chosen baseline; nil until there are two scans.
    private var comparison: ScanComparison? { model.comparison(baseline) }

    /// Points inside the selected range, oldest first.
    private var visiblePoints: [DrivePoint] {
        guard let days = range.days else { return model.drivePoints }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        return model.drivePoints.filter { $0.date >= cutoff }
    }

    /// Whole-disk scans inside the selected range; drawn as dots on the chart.
    private var visibleScans: [ScanRecord] {
        guard let days = range.days else { return model.scanRecords }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        return model.scanRecords.filter { $0.date >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Page.spacing) {
                ScreenHeader(
                    title: "Over time", subtitle: "How your free space moves, and what grew or shrank between scans.",
                    icon: "chart.line.uptrend.xyaxis", colors: [.mint, .teal])
                if model.scanRecords.isEmpty && model.drivePoints.count < 2 {
                    emptyState
                } else {
                    tiles
                    chartCard
                    if let comparison { changesCard(comparison) }
                    historyCard
                }
            }
            .pageBody()
        }
        .navigationTitle("Over time")
    }

    // MARK: Empty state

    /// Shown until there is something to plot: no saved scans and fewer than two free-space readings.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Nothing to compare yet").font(.title3.bold())
            Text("Reclaim remembers every whole-disk scan, and notes your free space now and then while it is open. Scan your Mac from My Mac, then scan again in a few days to see what changed.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            Button("Go to My Mac") { model.selection = .overview }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).card()
    }

    // MARK: Summary tiles

    /// Headline figures: free space now, then (with two scans) how much more or less was used, how much Reclaim freed
    /// in between, and the category that grew most.
    private var tiles: some View {
        let latestFree = model.drivePoints.last?.free ?? model.volume.available
        return HStack(spacing: 12) {
            StatTile(value: ByteFormat.string(latestFree), label: "free right now", color: .green)
            if let c = comparison {
                let grew = c.usedChange >= 0
                StatTile(
                    value: (grew ? "+" : "−") + ByteFormat.string(abs(c.usedChange)),
                    label: "used since \(c.older.date.formatted(date: .abbreviated, time: .omitted))",
                    color: grew ? .orange : .teal)
                let freed = model.freed(between: c.older, and: c.newer)
                StatTile(value: ByteFormat.string(freed), label: "freed by Reclaim in that time", color: .blue)
                if let g = c.biggestGrowth {
                    StatTile(value: "+" + ByteFormat.string(g.change), label: "\(g.name) grew most", color: .pink)
                }
            } else {
                StatTile(value: "\(model.scanRecords.count)", label: "scan\(model.scanRecords.count == 1 ? "" : "s") saved. Scan again later to compare.", color: .teal)
            }
        }
    }

    // MARK: Chart

    /// The free-space chart with its range picker. Needs two readings to draw a line.
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Free space").font(.title3.bold())
                Spacer()
                Picker("", selection: $range) { ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if visiblePoints.count >= 2 {
                TrendChart(points: visiblePoints, scans: visibleScans)
                Text("Dots mark whole-disk scans. The line is your free space, noted when Reclaim is open.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The chart appears once Reclaim has seen your free space on two different occasions. Keep using the app and it will fill in.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .card()
    }

    // MARK: What changed

    /// Lists what grew or shrank between the two scans compared, by category and by folder.
    private func changesCard(_ c: ScanComparison) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What changed").font(.title3.bold())
                    Text("Between \(c.older.date.formatted(date: .abbreviated, time: .shortened)) and \(c.newer.date.formatted(date: .abbreviated, time: .shortened)) (\(Int(c.days.rounded())) day\(Int(c.days.rounded()) == 1 ? "" : "s"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Compare with", selection: $baseline) {
                    ForEach(TrendBaseline.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }

            if c.categories.isEmpty {
                Text("Nothing moved by more than a megabyte.").foregroundStyle(.secondary)
            } else {
                Text("By category").font(.headline)
                ForEach(c.categories.prefix(8)) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text("\(ByteFormat.string(row.before)) → \(ByteFormat.string(row.after))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        deltaLabel(row.change).frame(width: 96, alignment: .trailing)
                    }
                }
            }

            if !c.grewFolders.isEmpty {
                Divider()
                Text("Folders that grew").font(.headline)
                ForEach(c.grewFolders.prefix(6)) { folderRow($0) }
            }
            if !c.shrankFolders.isEmpty {
                Divider()
                Text("Folders that shrank").font(.headline)
                ForEach(c.shrankFolders.prefix(4)) { folderRow($0) }
            }
            Text("Only folders of 100 MB or more are tracked, so a folder marked “new” may simply have crossed that size.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .card()
    }

    /// One folder's change. A "new" or "gone" badge marks folders present in only one scan, whose size change may just
    /// reflect crossing the tracking threshold.
    private func folderRow(_ f: FolderChange) -> some View {
        HStack {
            Text(f.path.replacingOccurrences(of: model.home, with: "~"))
                .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if f.isApproximate {
                Text(f.before == nil ? "new" : "gone")
                    .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button { model.reveal(f.path) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Show in Finder")
            deltaLabel(f.change).frame(width: 96, alignment: .trailing)
        }
    }

    /// "+2.1 GB" in orange when space grew, "−2.1 GB" in teal when it shrank.
    private func deltaLabel(_ change: Int64) -> some View {
        Text((change >= 0 ? "+" : "−") + ByteFormat.string(abs(change)))
            .font(.callout.weight(.semibold)).monospacedDigit()
            .foregroundStyle(change >= 0 ? Color.orange : Color.teal)
    }

    // MARK: History

    /// Every saved scan, newest first, with the change in use since the scan before it and what Reclaim freed in between. Also holds the Clear history control.
    private var historyCard: some View {
        let scans = model.scanRecords.sorted { $0.date > $1.date }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Scan history").font(.title3.bold())
                Spacer()
                Button("Clear history…", role: .destructive) { confirmClear = true }
                    .disabled(model.scanRecords.isEmpty && model.drivePoints.count < 2)
            }
            if scans.isEmpty {
                Text("No whole-disk scans saved yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(scans.enumerated()), id: \.element.id) { index, scan in
                let previous = index + 1 < scans.count ? scans[index + 1] : nil
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                        Text("\(ByteFormat.string(scan.free)) free · \(ByteFormat.string(scan.hidden)) hidden")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let previous {
                        let freed = freedByReclaim(model.history, from: previous.date, to: scan.date)
                        if freed > 0 {
                            Text("Reclaim freed \(ByteFormat.string(freed))").font(.caption).foregroundStyle(.blue)
                        }
                        deltaLabel(scan.used - previous.used).frame(width: 96, alignment: .trailing)
                    }
                }
                Divider()
            }
            Text("Stored only on this Mac, in Application Support. Clearing it removes the saved scans and free-space readings; nothing else.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .card()
        .confirmationDialog("Clear all saved history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearTrend() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved scans and free-space readings used for these charts. Your files are not touched.")
        }
    }
}

// MARK: - Chart

/// A line-and-area chart of free space over time, drawn with `Canvas`.
///
/// Hovering shows the reading nearest the pointer. Whole-disk scans are drawn as dots on the line.
struct TrendChart: View {
    let points: [DrivePoint]
    let scans: [ScanRecord]
    /// The pointer position while it is over the chart, in the chart's own coordinates; nil otherwise.
    @State private var hover: CGPoint?

    /// Room on the left for value labels.
    private let leftMargin: CGFloat = 58
    /// Room underneath for date labels.
    private let bottomMargin: CGFloat = 26

    /// Pure geometry: maps dates and byte counts to points in the plot rectangle. Internal so tests can check it.
    struct Geometry {
        /// The rectangle the line is drawn in, inside the margins.
        let plot: CGRect
        /// The date range of the x axis, as seconds since 1970.
        let tMin: TimeInterval, tMax: TimeInterval
        /// The y axis range and gridline spacing, in gigabytes.
        let lo: Double, hi: Double, step: Double

        init(plot: CGRect, points: [DrivePoint], scans: [ScanRecord]) {
            self.plot = plot
            let times = points.map(\.date.timeIntervalSince1970) + scans.map(\.date.timeIntervalSince1970)
            var t0 = times.min() ?? 0, t1 = times.max() ?? 1
            if t1 - t0 < 3600 { t0 -= 1800; t1 += 1800 }     // a single instant still needs a visible width
            tMin = t0; tMax = t1
            let values = points.map { Double($0.free) / 1e9 } + scans.map { Double($0.free) / 1e9 }
            let bounds = Self.niceBounds(min: values.min() ?? 0, max: values.max() ?? 1)
            lo = bounds.lo; hi = bounds.hi; step = bounds.step
        }

        /// The horizontal position of a date.
        func x(_ date: Date) -> CGFloat {
            plot.minX + CGFloat((date.timeIntervalSince1970 - tMin) / (tMax - tMin)) * plot.width
        }

        /// The vertical position of a free-space figure (larger values are higher).
        func y(_ freeBytes: Int64) -> CGFloat {
            plot.maxY - CGFloat((Double(freeBytes) / 1e9 - lo) / (hi - lo)) * plot.height
        }

        /// Round axis limits and step (1, 2, 5 × a power of ten) giving about four gridlines.
        static func niceBounds(min lo: Double, max hi: Double) -> (lo: Double, hi: Double, step: Double) {
            let span = Swift.max(hi - lo, 1)
            let raw = span / 4
            let magnitude = pow(10, floor(log10(raw)))
            let normalised = raw / magnitude
            let step = (normalised < 1.5 ? 1 : normalised < 3 ? 2 : normalised < 7 ? 5 : 10) * magnitude
            var bottom = floor(lo / step) * step
            var top = ceil(hi / step) * step
            if top - bottom < step { bottom -= step / 2; top += step / 2 }
            return (bottom, top, step)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: leftMargin, y: 8, width: max(10, geo.size.width - leftMargin - 12),
                              height: max(10, geo.size.height - bottomMargin - 8))
            let g = Geometry(plot: plot, points: points, scans: scans)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, g) }
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = p
                        case .ended: hover = nil
                        }
                    }
                if let hover, let nearest = nearest(to: hover, g) {
                    tooltip(for: nearest, g)
                }
            }
        }
        .frame(height: 230)
    }

    // MARK: Drawing

    /// Paints gridlines, date labels, the area and line, scan dots and the hover guide, in that order.
    private func draw(_ ctx: GraphicsContext, _ g: Geometry) {
        // Gridlines and value labels.
        var tick = g.lo
        while tick <= g.hi + g.step / 2 {
            let y = g.plot.maxY - CGFloat((tick - g.lo) / (g.hi - g.lo)) * g.plot.height
            var line = Path()
            line.move(to: CGPoint(x: g.plot.minX, y: y))
            line.addLine(to: CGPoint(x: g.plot.maxX, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            let label = Text(ByteFormat.string(Int64(tick * 1e9))).font(.system(size: 10)).foregroundColor(.secondary)
            ctx.draw(ctx.resolve(label), at: CGPoint(x: g.plot.minX - 6, y: y), anchor: .trailing)
            tick += g.step
        }

        // Date labels: first, middle, last.
        let dates = [g.tMin, (g.tMin + g.tMax) / 2, g.tMax].map { Date(timeIntervalSince1970: $0) }
        for (i, d) in dates.enumerated() {
            let t = Text(d.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 10)).foregroundColor(.secondary)
            let anchor: UnitPoint = i == 0 ? .topLeading : (i == 2 ? .topTrailing : .top)
            ctx.draw(ctx.resolve(t), at: CGPoint(x: g.x(d), y: g.plot.maxY + 6), anchor: anchor)
        }

        // Area under the line, then the line itself.
        guard let first = points.first, let last = points.last else { return }
        var area = Path()
        area.move(to: CGPoint(x: g.x(first.date), y: g.plot.maxY))
        for p in points { area.addLine(to: CGPoint(x: g.x(p.date), y: g.y(p.free))) }
        area.addLine(to: CGPoint(x: g.x(last.date), y: g.plot.maxY))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [Color.mint.opacity(0.35), Color.mint.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: g.plot.minY), endPoint: CGPoint(x: 0, y: g.plot.maxY)))
        var line = Path()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: g.x(p.date), y: g.y(p.free))
            i == 0 ? line.move(to: pt) : line.addLine(to: pt)
        }
        ctx.stroke(line, with: .color(.mint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

        // Scan markers.
        for s in scans {
            let c = CGPoint(x: g.x(s.date), y: g.y(s.free))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.teal), lineWidth: 2.5)
        }

        // Hover guide.
        if let hover, let nearest = nearest(to: hover, g) {
            let x = g.x(nearest.date), y = g.y(nearest.free)
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: g.plot.minY))
            guide.addLine(to: CGPoint(x: x, y: g.plot.maxY))
            ctx.stroke(guide, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.mint))
        }
    }

    // MARK: Hover

    /// The stored reading closest (horizontally) to the pointer.
    private func nearest(to p: CGPoint, _ g: Geometry) -> DrivePoint? {
        guard g.plot.insetBy(dx: -10, dy: -10).contains(p) else { return nil }
        return points.min { abs(g.x($0.date) - p.x) < abs(g.x($1.date) - p.x) }
    }

    /// The reading under the pointer. It is kept inside the plot's edges and ignores clicks so it can't interrupt hovering.
    private func tooltip(for point: DrivePoint, _ g: Geometry) -> some View {
        let x = min(max(g.x(point.date), g.plot.minX + 70), g.plot.maxX - 70)
        return VStack(spacing: 1) {
            Text(ByteFormat.string(point.free) + " free").font(.caption.weight(.semibold))
            Text(point.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .position(x: x, y: g.plot.minY + 18)
        .allowsHitTesting(false)
    }
}
