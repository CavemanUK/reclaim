import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private var total: Int64 { model.container?.ceiling ?? model.volume.total }
    private var free: Int64 { model.container?.free ?? model.volume.available }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Page.spacing) {
                ScreenHeader(title: "My Mac", subtitle: "Where your space went, explained plainly, and the fastest safe ways to get it back.",
                             icon: "chart.pie.fill", colors: [.blue, .cyan])
                if model.isScanning {
                    scanningHero
                } else if let report = model.report {
                    if report.scannedWholeDisk { resultsHero(report) } else { folderHero(report) }
                } else {
                    welcomeHero
                }

                if !model.fullDiskAccess { AccessGuide() }
                if model.report != nil, !model.isScanning { ReportCard() }
                if model.report != nil, !model.isScanning { StartHereCard() }
                if !model.isScanning { breakdown }
                if let report = model.report, report.scannedWholeDisk, !model.isScanning { GapCard(report: report) }
            }
            .pageBody()
        }
        .navigationTitle("My Mac")
    }

    // MARK: Heroes

    private var welcomeHero: some View {
        VStack(spacing: 18) {
            if model.container != nil {
                DriveRing(used: total - free, total: total, size: 150)
            } else {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 54))
                    .foregroundStyle(.linearGradient(colors: [.cyan, .purple], startPoint: .top, endPoint: .bottom))
            }
            Text("Let's find your missing space").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Reclaim looks through your Mac and shows you what is using space, in plain English, and how to get it back. It only looks. You decide what happens next.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Button { model.startScan() } label: {
                Label(model.target == .disk ? "Scan my Mac" : "Scan \(model.target.title)", systemImage: "magnifyingglass").font(.title3.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            scanChoice
            StepsView(current: 1)
            SpaceBar(segments: segments, height: 30)
            if model.container != nil {
                Text("Your drive right now: \(ByteFormat.string(free)) free of \(ByteFormat.string(total)).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 24)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }

    /// Where the scan looks: this Mac, the home folder, any external drive, or a folder you choose.
    private var scanChoice: some View {
        Menu {
            targetButton(.disk)
            targetButton(.home)
            if !model.externalVolumes.isEmpty {
                Divider()
                ForEach(model.externalVolumes, id: \.self) { targetButton(.folder($0)) }
            }
            if !model.customFolders.isEmpty {
                Divider()
                ForEach(model.customFolders, id: \.self) { url in
                    targetButton(.folder(url))
                }
                Menu("Remove from list") {
                    ForEach(model.customFolders, id: \.self) { url in
                        Button(url.lastPathComponent) { model.removeCustomFolder(url) }
                    }
                }
            }
            Divider()
            Button("Choose a folder…") { model.chooseFolder() }
        } label: {
            Label("Looking at: \(model.target.title)", systemImage: model.target.icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isScanning)
    }

    private func targetButton(_ target: ScanTarget) -> some View {
        Button {
            model.target = target
        } label: {
            if model.target == target {
                Label(target.title, systemImage: "checkmark")
            } else {
                Label(target.title, systemImage: target.icon)
            }
        }
    }

    private var scanningHero: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Looking through your Mac…").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("\(model.progress.files.formatted()) files looked at so far (\(ByteFormat.string(model.progress.bytes)))")
                .font(.title3).monospacedDigit().foregroundStyle(.secondary)
            Text(model.progress.currentPath).font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Text("This usually takes under a minute. You can keep using your Mac.").font(.callout).foregroundStyle(.secondary)
            Button("Stop") { model.cancelScan() }
            StepsView(current: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34).padding(.horizontal, 24)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }

    private func resultsHero(_ report: SpaceReport) -> some View {
        let wins = model.insights.reduce(Int64(0)) { $0 + $1.potentialBytes }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 22) {
                DriveRing(used: total - free, total: total)
                VStack(alignment: .leading, spacing: 6) {
                    if wins > 0 {
                        Text("You can likely get back").font(.title3).foregroundStyle(.secondary)
                        Text(ByteFormat.string(wins))
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.linearGradient(colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing))
                        Text("Your Mac has \(ByteFormat.string(free)) free out of \(ByteFormat.string(total)) right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(ByteFormat.string(free)) free").font(.system(size: 44, weight: .bold, design: .rounded))
                        Text(model.insights.isEmpty
                            ? "out of \(ByteFormat.string(total)). Nothing obvious to clean up."
                            : "out of \(ByteFormat.string(total)). Nothing Reclaim can safely remove by itself, but there are large files worth a look in Clean up.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if !model.insights.isEmpty {
                        Button { model.selection = .suggestions } label: {
                            Label(wins > 0 ? "See what to clean up" : "See what's worth a look", systemImage: "sparkles")
                                .font(.headline).padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Button("Scan again") { model.startScan() }
                    scanChoice
                }
            }
            SpaceBar(segments: segments, height: 34)
            legend
            StepsView(current: wins > 0 ? 2 : 3)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }

    private func folderHero(_ report: SpaceReport) -> some View {
        let wins = model.insights.reduce(Int64(0)) { $0 + $1.potentialBytes }
        let name = model.scannedTarget?.title ?? "this folder"
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inside \(name)").font(.title3).foregroundStyle(.secondary)
                    Text(ByteFormat.string(report.scannedBytes))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Text("in \((model.root?.fileCount ?? 0).formatted()) files. \(wins > 0 ? "About \(ByteFormat.string(wins)) could be cleaned up." : "Nothing obvious to clean up.")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button { model.selection = .map } label: {
                        Label("Explore the map", systemImage: "square.grid.3x3.fill").font(.headline).padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Scan again") { model.startScan() }
                    scanChoice
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Bar + legend

    private var segments: [BarSegment] {
        var out: [BarSegment] = []
        let c = model.container
        let sysBytes = c?.systemVolume?.inUse ?? 0
        let others = c?.volumes.filter { !$0.roles.contains("Data") && !$0.roles.contains("System") }
            .reduce(Int64(0)) { $0 + $1.inUse } ?? 0
        out.append(BarSegment(label: "macOS", bytes: sysBytes, color: Palette.macOS))
        out.append(BarSegment(label: "Startup and recovery", bytes: others, color: Palette.bootVolumes))
        if let report = model.report {
            for cat in report.categories { out.append(BarSegment(label: cat.category.rawValue, bytes: cat.bytes, color: cat.category.color)) }
            out.append(BarSegment(label: "macOS frees by itself", bytes: report.purgeableInGap, color: Palette.purgeable))
            out.append(BarSegment(label: "Hidden", bytes: report.unexplainedRemainder, color: Palette.unexplained))
        } else {
            out.append(BarSegment(label: "Your stuff", bytes: c?.dataVolume?.inUse ?? max(0, total - free), color: .blue.opacity(0.6)))
        }
        out.append(BarSegment(label: "Free", bytes: free, color: Palette.free))
        return out
    }

    private var legend: some View {
        let big = segments.filter { $0.bytes > total / 40 }
        return FlowLayout(spacing: 14) {
            ForEach(big) { seg in
                HStack(spacing: 6) {
                    Circle().fill(seg.color).frame(width: 9, height: 9)
                    Text("\(seg.label) \(ByteFormat.string(seg.bytes))").font(.caption)
                }
            }
        }
    }

    // MARK: Breakdown

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.report?.scannedWholeDisk == false ? "What's inside" : "Where your space is").font(.title2.bold())
            VStack(spacing: 0) {
                if model.report == nil || model.report?.scannedWholeDisk == true {
                    if let c = model.container {
                        if let sys = c.systemVolume {
                            InfoRow(color: Palette.macOS, icon: "apple.logo", title: "macOS", bytes: sys.inUse, total: total,
                                    detail: "The operating system itself. It is locked by Apple and can't be made smaller.")
                            Divider()
                        }
                        ForEach(c.volumes.filter { !$0.roles.contains("Data") && !$0.roles.contains("System") && $0.inUse > 50 << 20 }) { v in
                            InfoRow(color: Palette.bootVolumes, icon: "internaldrive", title: Self.volumeTitle(v), bytes: v.inUse, total: total,
                                    detail: Self.volumeText(v))
                            Divider()
                        }
                    }
                }
                if let report = model.report {
                    if report.scannedWholeDisk || model.scannedTarget == .home {
                        ForEach(report.categories) { cat in
                            CategoryRow(total: cat, drive: report.scannedWholeDisk ? total : max(1, report.scannedBytes))
                            Divider()
                        }
                    } else if let root = model.root {
                        ForEach(root.children.prefix(15)) { child in
                            FolderChildRow(node: child, total: max(1, root.size))
                            Divider()
                        }
                    }
                    if report.scannedWholeDisk, report.purgeableInGap > 0 {
                        InfoRow(color: Palette.purgeable, icon: "arrow.3.trianglepath", title: "Space macOS frees by itself", bytes: report.purgeableInGap, total: total,
                                detail: "Counted as used, but macOS gives it back automatically when it needs room. Nothing to do.")
                    }
                } else if let data = model.container?.dataVolume {
                    InfoRow(color: .blue.opacity(0.6), icon: "person.crop.circle", title: "Your stuff", bytes: data.inUse, total: total,
                            detail: "Apps, documents, caches and developer files. Scan to see exactly what is inside.")
                }
            }
            .padding(.horizontal, 16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    static func volumeTitle(_ v: APFSVolume) -> String {
        switch v.role {
        case "Preboot": "Startup files"
        case "Recovery": "Recovery"
        case "VM": "Memory overflow (swap)"
        case "Update": "System update staging"
        default: v.name
        }
    }

    static func volumeText(_ v: APFSVolume) -> String {
        switch v.role {
        case "Preboot":
            return "Files your Mac needs to start up. macOS manages them, so you can't remove them by hand. They grow after system updates."
        case "Recovery":
            return "Lets you reinstall or repair macOS if something goes wrong. Needed, so leave it alone."
        case "VM":
            return "Overflow for when your memory is full. It grows when your Mac is busy and shrinks after a restart, so restarting can free it."
        case "Update":
            return "Space macOS uses to prepare a system update."
        default:
            return "A small system area managed by macOS."
        }
    }
}

// MARK: - The three steps

struct StepsView: View {
    let current: Int

    var body: some View {
        HStack(spacing: 10) {
            step(1, "Scan")
            line
            step(2, "Review")
            line
            step(3, "Approve")
        }
        .padding(.top, 4)
    }

    private var line: some View { Rectangle().fill(.quaternary).frame(width: 30, height: 2) }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(n < current ? Color.green : (n == current ? Color.accentColor : Color.secondary.opacity(0.25)))
                    .frame(width: 22, height: 22)
                if n < current {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.bold()).foregroundStyle(n == current ? .white : .secondary)
                }
            }
            Text(title).font(.callout).foregroundStyle(n <= current ? .primary : .secondary)
        }
    }
}

// MARK: - Guide for Full Disk Access

struct AccessGuide: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Let Reclaim see everything (recommended)", systemImage: "lock.shield").font(.headline)
            Text("macOS hides Mail, Messages, Safari and some system data from apps. Until you allow it, that space shows up as “hidden” and some clean-ups are refused. Reclaim only reads sizes. It never changes anything without your approval.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Click “Open Settings”.")
                step(2, "If Reclaim is already listed, select it and click − first. macOS forgets the permission whenever Reclaim is updated, even though the switch still looks on.")
                step(3, "Click +, press ⌘⇧G, and pick Reclaim.app (“Show Reclaim” opens its folder).")
                step(4, "Switch Reclaim on, then click “Restart Reclaim”.")
            }
            HStack {
                Button("Open Settings") { model.openFullDiskAccessSettings() }.buttonStyle(.borderedProminent)
                Button("Show Reclaim") { model.reveal(Bundle.main.bundlePath) }
                Button("Restart Reclaim") { model.relaunch() }
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.25), in: Circle())
            Text(text).font(.callout)
        }
    }
}

// MARK: - Written report

struct ReportCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2).foregroundStyle(.white).frame(width: 40, height: 40)
                    .background(.linearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your report").font(.title2.bold())
                    Text("A short, written summary of where the space went and what to do first. Written on this Mac; nothing is sent anywhere.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.aiReportWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.writeReport() } label: {
                        Label(model.aiReport == nil ? "Write my report" : "Write again", systemImage: "pencil.and.outline")
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)
                }
            }
            if let text = model.aiReport {
                Divider()
                ReportText(markdown: text)
                if let source = model.aiReportSource {
                    switch source {
                    case .appleIntelligence:
                        Label("Written by Apple Intelligence on this Mac, from the scan's numbers only.", systemImage: "apple.logo")
                            .font(.caption).foregroundStyle(.secondary)
                    case .builtIn(let why):
                        Label("Written by Reclaim from the scan's numbers. \(why)", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if model.aiReportWriting {
                Text("Writing…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
        .animation(.snappy, value: model.aiReport)
    }
}

/// Renders the report's simple Markdown: "## " headings, numbered lists, paragraphs.
struct ReportText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    EmptyView()
                } else if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.headline).padding(.top, 6)
                } else if line.hasPrefix("# ") {
                    Text(line.dropFirst(2)).font(.headline).padding(.top, 6)
                } else {
                    Text(inline(line)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Start here

struct StartHereCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let top = model.insights.filter { $0.potentialBytes > 0 }
            .sorted { $0.potentialBytes > $1.potentialBytes }.prefix(3)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start with these").font(.title2.bold())
                Text("The biggest wins first. You'll see exactly what is affected before anything moves.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(top)) { insight in
                    HStack(spacing: 12) {
                        Image(systemName: insight.icon).font(.title3).frame(width: 38, height: 38)
                            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(insight.title).font(.headline); RiskBadge(risk: insight.risk) }
                            Text("About \(ByteFormat.string(insight.potentialBytes)) you could free")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review") { model.selection = .suggestions }
                    }
                }
            }
            .card()
        }
    }
}

// MARK: - Rows (lightweight, live inside one shared card)

struct InfoRow: View {
    let color: Color
    let icon: String
    let title: String
    let bytes: Int64
    let total: Int64
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(ByteFormat.string(bytes)).font(.headline).monospacedDigit()
                }
                ProgressView(value: safeFraction(Double(bytes), of: Double(total))).tint(color)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }
}

struct CategoryRow: View {
    let total: CategoryTotal
    let drive: Int64
    @State private var expanded = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let cat = total.category
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: cat.icon).font(.title3).foregroundStyle(cat.color).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cat.rawValue).font(.headline)
                            Spacer()
                            Text(ByteFormat.string(total.bytes)).font(.headline).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        ProgressView(value: safeFraction(Double(total.bytes), of: Double(drive))).tint(cat.color)
                        Text(cat.explanation).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Label(cat.howToReduce, systemImage: "lightbulb").font(.callout)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    if !total.contributors.isEmpty {
                        Text("Biggest items").font(.subheadline.bold()).padding(.top, 2)
                        ForEach(total.contributors) { c in
                            HStack {
                                Text(c.path.replacingOccurrences(of: model.home, with: "~"))
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.string(c.size)).monospacedDigit()
                                Button { model.reveal(c.path) } label: { Image(systemName: "arrow.up.forward.square") }
                                    .buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                }
                .padding(.leading, 42)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 12)
    }
}

struct FolderChildRow: View {
    let node: FileNode
    let total: Int64
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill").font(.title3)
                .foregroundStyle(FileKind.color(for: node)).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(ByteFormat.string(node.size)).font(.headline).monospacedDigit()
                    Button { model.reveal(node.path) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
                ProgressView(value: safeFraction(Double(node.size), of: Double(total))).tint(FileKind.color(for: node))
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - The gap

struct GapCard: View {
    let report: SpaceReport
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Label("What's hidden?", systemImage: "questionmark.circle.fill")
                        .font(.title3.bold()).foregroundStyle(Palette.unexplained)
                    Spacer()
                    Text("\(ByteFormat.string(report.unexplainedRemainder))").font(.headline).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(report.unexplainedRemainder < 5 << 30
                ? "Almost everything is accounted for. Only \(ByteFormat.string(report.unexplainedRemainder)) is hidden from view."
                : "Your Mac says \(ByteFormat.string(report.dataUsed)) is in use, but Reclaim can only see \(ByteFormat.string(report.scannedBytes)) of it as files.")
                .font(.callout)

            if expanded { details }
        }
        .card()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            if report.overCount > 0 {
                Label("The scan counted \(ByteFormat.string(report.overCount)) more than the drive reports. Copies that share storage get counted twice. That is normal.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            reason("clock.arrow.circlepath",
                   report.snapshots.isEmpty ? "No Time Machine snapshots" : "Time Machine snapshots (\(report.snapshots.count))",
                   report.snapshots.isEmpty
                       ? "Good: nothing is being held back by old backups on this drive."
                       : "macOS keeps hourly snapshots so you can go back in time. They hold old versions of changed files and can be large. macOS deletes them on its own when space runs low.")
            if !report.snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("To ask macOS to thin them now, paste this into Terminal. It asks for your admin password, and Reclaim never runs it for you:")
                        .font(.callout)
                    CommandBox(command: "sudo tmutil thinlocalsnapshots / 100000000000 4")
                }
                .padding(.leading, 32)
            }

            reason("arrow.3.trianglepath", "Space macOS frees by itself: \(ByteFormat.string(report.purgeableInGap))",
                   "Caches and iCloud downloads macOS counts as used but throws away when it needs room. Nothing to do.")

            reason("eye.slash", "Folders Reclaim can't open: \(report.unreadable.count)",
                   report.unreadable.isEmpty
                       ? "None. Everything was readable."
                       : (model.fullDiskAccess
                           ? "Owned by the system: Spotlight's index, document version history, system databases. No app can read these; only an administrator in Terminal can measure them."
                           : "Allow Full Disk Access (orange card above), restart Reclaim and scan again to open most of them."))
            if !report.unreadable.isEmpty { UnreadableList(paths: report.unreadable) }
        }
    }

    private func reason(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The folders a scan could not enter, grouped by where they live, with a command the user can run to size them.
struct UnreadableList: View {
    let paths: [String]
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    private var groups: [(top: String, paths: [String])] {
        var byTop: [String: [String]] = [:]
        for p in paths {
            let parts = p.split(separator: "/").map(String.init)
            let top = parts.count >= 2 ? "/" + parts.prefix(parts[0] == "Users" ? 3 : 2).joined(separator: "/") : p
            byTop[top, default: []].append(p)
        }
        return byTop.map { ($0.key, $0.value.sorted()) }.sorted { $0.paths.count > $1.paths.count }
    }

    /// The handful of top-level places that account for most of the unreadable set; sizing them needs sudo.
    private var measureCommand: String {
        let tops = groups.prefix(6).map { "\"\($0.top)\"" }.joined(separator: " ")
        return "sudo du -shx \(tops) 2>/dev/null | sort -h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.top) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(group.top)  ·  \(group.paths.count)").font(.subheadline.bold())
                                Button { model.reveal(group.top) } label: { Image(systemName: "arrow.up.forward.square") }
                                    .buttonStyle(.borderless).help("Show in Finder")
                            }
                            ForEach(group.paths.prefix(6), id: \.self) { p in
                                Text(p.replacingOccurrences(of: model.home, with: "~"))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if group.paths.count > 6 {
                                Text("…and \(group.paths.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Show the list").font(.callout)
            }
            Text("To measure them yourself, paste this into Terminal (it asks for your admin password; it only reads sizes):")
                .font(.callout)
            CommandBox(command: measureCommand)
        }
        .padding(.leading, 32)
    }
}

// MARK: - Wrapping layout for the legend

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
