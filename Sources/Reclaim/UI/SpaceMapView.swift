import SwiftUI

// The "What's big" screen: an interactive treemap of the scanned `FileNode` tree, with a list alternative.
// Clicking a block inspects it and double-clicking opens a folder. From the footer the user can reveal an item,
// keep it in iCloud only, or request that it be trashed (the safety policy decides whether that is allowed).

/// One block on the map: a child node, or the combined "Smaller items" remainder (which has no node).
struct Tile: Identifiable {
    let id: String
    let node: FileNode?
    let label: String
    let size: Int64
}

// MARK: - Treemap layout
/// Squarified treemap layout (Bruls et al.). `sizes` must be sorted descending and positive.
func squarify(sizes: [Double], in rect: CGRect) -> [CGRect] {
    let total = sizes.reduce(0, +)
    guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
    let scale = Double(rect.width * rect.height) / total
    let areas = sizes.map { $0 * scale }
    var result = [CGRect](repeating: .zero, count: sizes.count)
    var r = rect
    var i = 0

    // Worst aspect ratio among the rectangles of a row with this total area, laid along a side of length `side`.
    func worst(_ sum: Double, _ minA: Double, _ maxA: Double, _ side: Double) -> Double {
        max(side * side * maxA / (sum * sum), sum * sum / (side * side * minA))
    }

    while i < areas.count {
        let side = Double(min(r.width, r.height))
        var end = i + 1
        var sum = areas[i]
        var current = worst(sum, areas[i], areas[i], side)
        // Keep adding items to the current row while that does not make the worst aspect ratio any worse.
        while end < areas.count {
            let newSum = sum + areas[end]
            let candidate = worst(newSum, areas[end], areas[i], side)
            if candidate > current { break }
            sum = newSum
            current = candidate
            end += 1
        }
        if r.width >= r.height {
            let w = CGFloat(sum) / r.height
            var y = r.minY
            for k in i..<end {
                let h = CGFloat(areas[k]) / w
                result[k] = CGRect(x: r.minX, y: y, width: w, height: h)
                y += h
            }
            r = CGRect(x: r.minX + w, y: r.minY, width: max(0, r.width - w), height: r.height)
        } else {
            let h = CGFloat(sum) / r.width
            var x = r.minX
            for k in i..<end {
                let w = CGFloat(areas[k]) / h
                result[k] = CGRect(x: x, y: r.minY, width: w, height: h)
                x += w
            }
            r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: max(0, r.height - h))
        }
        i = end
    }
    return result
}

// MARK: - Colours
/// Colour for a node on the map: folders take the colour of the category they belong to (matching the
/// Overview bar), files take a colour by kind. A small per-name variation keeps neighbours distinguishable.
enum MapColor {
    /// Chooses the block colour for `node`.
    static func color(for node: FileNode, home: String) -> Color {
        // A cheap name hash (FNV-1a style) so a name always gets the same small brightness change between runs.
        var h: UInt64 = 1469598103934665603
        for b in node.name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let wobble = Double(h % 100) / 100 * 0.16 - 0.08
        let base: Color
        if node.isDirectory {
            base = SpaceClassifier.category(forPath: node.path, home: home).color
        } else {
            switch node.ext {
            case "mov", "mp4", "m4v", "mkv", "avi", "webm": base = .purple
            case "jpg", "jpeg", "png", "heic", "raw", "dng", "tiff", "gif", "webp": base = .green
            case "zip", "dmg", "pkg", "iso", "gz", "xip", "7z", "tar", "rar": base = .orange
            case "mp3", "m4a", "aac", "wav", "flac", "aiff": base = .teal
            case "pdf", "doc", "docx", "pages", "key", "numbers", "xlsx", "pptx": base = .blue
            default: base = Color(white: 0.55)
            }
        }
        return base.adjusted(brightness: wobble)
    }
}

/// Helpers for tinting map blocks.
extension Color {
    /// Returns this colour with its HSB brightness shifted by `delta`, clamped so it stays visible on the dark background.
    func adjusted(brightness delta: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s), brightness: min(1, max(0.15, Double(b) + delta)), opacity: Double(a))
    }
}

// MARK: - Screen
struct SpaceMapView: View {
    @Environment(AppModel.self) private var model
    /// The folders the user has drilled into, outermost first. Empty means the scan root is shown.
    @State private var stack: [FileNode] = []
    @State private var selected: FileNode?
    /// `Tile.id` of the block under the pointer, used to highlight it and describe it in the footer.
    @State private var hoveredID: String?
    @State private var asList = false

    /// The folder currently shown.
    private var current: FileNode? { stack.last ?? model.root }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "What's big", subtitle: "Every folder as a block, sized by what it takes. Click to inspect, double-click to open.",
                         icon: "square.grid.3x3.fill", colors: [.purple, .indigo])
                .padding(.bottom, 8)
            if let node = current {
                breadcrumb(node)
                if asList { listView(node) } else { treemap(node) }
                footer(node)
            } else {
                ContentUnavailableView(
                    "No scan yet", systemImage: "square.grid.3x3",
                    description: Text("Run a scan from My Mac to see an interactive map of everything on your drive."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Page.inset).padding(.top, Page.top).padding(.bottom, Page.inset)
        .pageColumn()
        .navigationTitle("What's big")
        .onChange(of: model.root?.id) { _, _ in stack = []; selected = nil }
    }

    // MARK: Parts

    private func breadcrumb(_ node: FileNode) -> some View {
        HStack(spacing: 6) {
            Button { stack = []; selected = nil } label: { Image(systemName: "house.fill") }.buttonStyle(.borderless)
                .help("Back to the top")
            ForEach(Array(stack.enumerated()), id: \.offset) { index, item in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                Button(item.name) { stack = Array(stack.prefix(index + 1)); selected = nil }.buttonStyle(.borderless)
            }
            if !stack.isEmpty {
                Button { stack.removeLast(); selected = nil } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).help("Up one level").keyboardShortcut(.upArrow, modifiers: .command)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(node.name).font(.headline)
                Text("\(ByteFormat.string(node.size)) · \(node.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $asList) {
                Image(systemName: "square.grid.2x2").tag(false)
                Image(systemName: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 90).labelsHidden()
        }
    }

    /// The blocks for a folder: its 60 largest children, plus one "Smaller items" block for the rest when that is
    /// more than 0.5% of the folder. Drawing every child would be slow and unreadable.
    private func tiles(_ node: FileNode) -> [Tile] {
        var list = node.children.prefix(60).map { Tile(id: $0.path, node: $0, label: $0.name, size: $0.size) }
        let shown = list.reduce(Int64(0)) { $0 + $1.size }
        let rest = node.size - shown
        if rest > node.size / 200 {
            list.append(Tile(id: "rest", node: nil, label: "Smaller items", size: rest))
        }
        return list.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    /// Draws the map on a single `Canvas`, which is much cheaper than a SwiftUI view per block. Hover and tap
    /// handling sits on a transparent layer on top and finds the block by hit-testing the computed rectangles.
    private func treemap(_ node: FileNode) -> some View {
        let items = tiles(node)
        let home = model.home
        return GeometryReader { geo in
            let rects = squarify(sizes: items.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 2))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (tile, rect) in zip(items, rects) {
                        let r = rect.insetBy(dx: 1.5, dy: 1.5)
                        guard r.width > 2, r.height > 2 else { continue }
                        let isSel = tile.node != nil && tile.node?.id == selected?.id
                        let isHover = hoveredID == tile.id
                        let base = tile.node.map { MapColor.color(for: $0, home: home) } ?? Color(white: 0.4)
                        let shape = Path(roundedRect: r, cornerRadius: 6)

                        // Tile body: a soft vertical gradient so tiles read as blocks, not flat paint.
                        ctx.fill(shape, with: .linearGradient(
                            Gradient(colors: [base.adjusted(brightness: isHover ? 0.12 : 0.06), base.adjusted(brightness: isHover ? -0.02 : -0.08)]),
                            startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))

                        // Inside a folder: its biggest children as inset blocks, so structure shows at a glance.
                        if let n = tile.node, n.isDirectory, r.width > 70, r.height > 50 {
                            let inner = r.insetBy(dx: 6, dy: 6).divided(atDistance: 20, from: .minYEdge).remainder
                            let kids = n.children.prefix(12).filter { Double($0.size) >= Double(n.size) * 0.02 }
                            if !kids.isEmpty, inner.width > 20, inner.height > 14 {
                                let kidRects = squarify(sizes: kids.map { Double($0.size) }, in: inner)
                                for (kid, kr) in zip(kids, kidRects) {
                                    let kk = kr.insetBy(dx: 1, dy: 1)
                                    guard kk.width > 3, kk.height > 3 else { continue }
                                    let kc = MapColor.color(for: kid, home: home)
                                    ctx.fill(Path(roundedRect: kk, cornerRadius: 3), with: .color(kc.opacity(0.55)))
                                    ctx.stroke(Path(roundedRect: kk, cornerRadius: 3), with: .color(.black.opacity(0.18)), lineWidth: 0.5)
                                    if kk.width > 56, kk.height > 16 {
                                        let t = Text(kid.name).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.9))
                                        ctx.draw(ctx.resolve(t), in: kk.insetBy(dx: 4, dy: 2))
                                    }
                                }
                            }
                        }

                        // Label pill.
                        if r.width > 54, r.height > 24 {
                            let title = Text(tile.label).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            let resolved = ctx.resolve(title)
                            let size = resolved.measure(in: CGSize(width: r.width - 14, height: 16))
                            let pill = CGRect(x: r.minX + 5, y: r.minY + 5, width: min(size.width + 10, r.width - 10), height: 16)
                            ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(.black.opacity(0.35)))
                            ctx.draw(resolved, in: pill.insetBy(dx: 5, dy: 1))
                            if r.height > 44 {
                                let sub = Text(ByteFormat.string(tile.size)).font(.system(size: 10)).foregroundColor(.white.opacity(0.9))
                                ctx.draw(ctx.resolve(sub), in: CGRect(x: r.minX + 7, y: r.minY + 24, width: r.width - 14, height: 14))
                            }
                        }

                        if isSel {
                            ctx.stroke(shape, with: .color(.white), lineWidth: 3)
                            ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 7), with: .color(.accentColor), lineWidth: 2)
                        } else if isHover {
                            ctx.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                        } else {
                            ctx.stroke(shape, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
                        }
                    }
                }
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoveredID = hit(items, rects, p)?.id
                        case .ended: hoveredID = nil
                        }
                    }
                    .gesture(SpatialTapGesture(count: 2).onEnded { v in
                        if let n = hit(items, rects, v.location)?.node, n.isDirectory, !n.children.isEmpty {
                            withAnimation(.snappy) { stack.append(n); selected = nil }
                        }
                    })
                    .simultaneousGesture(SpatialTapGesture().onEnded { v in
                        selected = hit(items, rects, v.location)?.node
                    })
            }
        }
        .frame(minHeight: 380)
        .background(
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.06)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    /// The block containing point `p`, if any.
    private func hit(_ items: [Tile], _ rects: [CGRect], _ p: CGPoint) -> Tile? {
        for (tile, rect) in zip(items, rects) where rect.contains(p) { return tile }
        return nil
    }

    /// The same blocks as a list, for people who prefer rows to a map.
    private func listView(_ node: FileNode) -> some View {
        List(tiles(node)) { tile in
            HStack {
                Image(systemName: tile.node?.isDirectory == false ? "doc.fill" : "folder.fill")
                    .foregroundStyle(tile.node.map { MapColor.color(for: $0, home: model.home) } ?? .secondary)
                Text(tile.label).lineLimit(1)
                Spacer()
                ProgressView(value: safeFraction(Double(tile.size), of: Double(node.size))).frame(width: 120)
                    .tint(tile.node.map { MapColor.color(for: $0, home: model.home) } ?? .secondary)
                Text(ByteFormat.string(tile.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .listRowBackground(tile.node?.id == selected?.id ? Color.accentColor.opacity(0.25) : Color.clear)
            .onTapGesture(count: 2) {
                if let n = tile.node, n.isDirectory, !n.children.isEmpty { stack.append(n); selected = nil }
            }
            .onTapGesture { selected = tile.node }
        }
        .frame(minHeight: 380)
    }

    /// Legend: the categories present in the current view, in the same colours as the Overview bar.
    private func legend(_ node: FileNode) -> some View {
        let cats = Array(Set(node.children.filter(\.isDirectory).map { SpaceClassifier.category(forPath: $0.path, home: model.home) }))
            .sorted { $0.rawValue < $1.rawValue }.prefix(6)
        return FlowLayout(spacing: 10) {
            ForEach(Array(cats)) { cat in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(cat.color).frame(width: 10, height: 10)
                    Text(cat.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach([("Video", Color.purple), ("Photos", .green), ("Archives", .orange), ("Audio", .teal), ("Documents", .blue)], id: \.0) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.1).frame(width: 8, height: 8)
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Details and actions for the selected block, or a hint while nothing is selected.
    private func footer(_ node: FileNode) -> some View {
        HStack(spacing: 12) {
            if let s = selected {
                Image(nsImage: NSWorkspace.shared.icon(forFile: s.path)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text(s.name).font(.headline)
                    Text("\(ByteFormat.string(s.size))" + (s.isDirectory ? " · \(s.fileCount.formatted()) files" : "") + " · \(s.path.replacingOccurrences(of: model.home, with: "~"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text("Modified \(ageText(s.modified))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if s.isDirectory, !s.children.isEmpty {
                    Button("Open") { withAnimation(.snappy) { stack.append(s); selected = nil } }
                }
                Button("Show in Finder") { model.reveal(s.path) }
                if CloudEvict.status(of: s.path).canEvict {
                    Button("Keep in iCloud only…") {
                        model.requestEvict([(s.path, s.size)], reason: "Chosen in What's big")
                    }
                    .tint(.cyan)
                    .help("Removes the copy on this Mac; the file stays in iCloud and downloads when opened")
                }
                // The button is disabled, with the policy's reason as its tooltip, when the path is protected.
                let verdict = SafetyPolicy().verdict(forPath: s.path)
                Button("Move to Trash…") {
                    model.requestTrash([(s.path, s.size)], reason: "Chosen in What's big")
                }
                .disabled(!verdict.isAllowed)
                .help(verdict.isAllowed ? "Moves to the Trash after you confirm" : {
                    if case .denied(let why) = verdict { return why } else { return "" }
                }())
            } else {
                if let hid = hoveredID, let tile = tiles(node).first(where: { $0.id == hid }) {
                    VStack(alignment: .leading) {
                        Text(tile.label).font(.headline)
                        Text(ByteFormat.string(tile.size) + String(format: " · %.1f%% of %@", Double(tile.size) / Double(max(1, node.size)) * 100, node.name))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Bigger blocks use more space. Click to inspect, double-click a folder to open it.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                legend(node)
            }
        }
        .frame(minHeight: 44)
        .card()
    }
}
