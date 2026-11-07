import SwiftUI

extension SpaceCategory {
    var color: Color {
        switch self {
        case .apps: .blue
        case .yourFiles: .green
        case .photos: .pink
        case .mailMessages: .cyan
        case .appData: .indigo
        case .caches: .orange
        case .developer: .purple
        case .ai: .mint
        case .backups: .teal
        case .tools: .brown
        case .systemSupport: Color(white: 0.45)
        case .otherUsers: .yellow
        case .trash: .red
        case .other: Color(white: 0.6)
        }
    }
}

enum Palette {
    static let macOS = Color(white: 0.35)
    static let bootVolumes = Color(white: 0.5)
    static let unexplained = Color(red: 0.95, green: 0.3, blue: 0.35)
    static let purgeable = Color.cyan.opacity(0.55)
    static let free = Color.secondary.opacity(0.18)
}

struct BarSegment: Identifiable {
    let id = UUID()
    let label: String
    let bytes: Int64
    let color: Color
}

/// Stacked horizontal bar. Widths are proportional to bytes of the whole container.
struct SpaceBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let total = max(1, segments.reduce(Int64(0)) { $0 + $1.bytes })
            HStack(spacing: 1.5) {
                ForEach(segments) { seg in
                    let w = max(seg.bytes > 0 ? 2 : 0, geo.size.width * CGFloat(seg.bytes) / CGFloat(total))
                    RoundedRectangle(cornerRadius: 3).fill(seg.color)
                        .frame(width: w)
                        .help("\(seg.label): \(ByteFormat.string(seg.bytes))")
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
    /// Results that arrive after a search slide in rather than popping.
    func arrives() -> some View { transition(.opacity.combined(with: .move(edge: .bottom))) }
}

/// One set of page margins for every screen, so titles and cards line up when switching pages.
enum Page {
    static let inset: CGFloat = 30
    static let top: CGFloat = 28
    static let maxWidth: CGFloat = 1000
    static let spacing: CGFloat = 20
}

extension View {
    /// Standard page body: a centred column of fixed maximum width that the content always fills, so titles
    /// start at the same point on every page whatever the content.
    func pageBody() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Page.inset).padding(.top, Page.top).padding(.bottom, Page.inset)
            .frame(maxWidth: Page.maxWidth)
            .frame(maxWidth: .infinity)
    }

    /// Same column for pages that don't scroll (split views, the map).
    func pageColumn() -> some View {
        self.frame(maxWidth: Page.maxWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The look every screen opens with: a gradient tile, a rounded title and a one-line promise.
struct ScreenHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.linearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: (colors.first ?? .blue).opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
            }
        }
    }
}

/// A big number with a caption, tinted. Used for result summaries everywhere.
struct StatTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [color.opacity(0.18), color.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.25)))
    }
}

/// A ring showing how full the drive is, with the free space in the middle.
struct DriveRing: View {
    let used: Int64
    let total: Int64
    var size: CGFloat = 132

    private var fraction: Double { safeFraction(Double(used), of: Double(total)) }
    private var colors: [Color] { fraction > 0.9 ? [.red, .orange] : (fraction > 0.75 ? [.orange, .yellow] : [.cyan, .purple]) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.4), radius: 6)
            VStack(spacing: 2) {
                Text(ByteFormat.string(max(0, total - used))).font(.system(size: size * 0.16, weight: .bold, design: .rounded)).monospacedDigit()
                Text("free").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(fraction * 100))% used").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.8), value: fraction)
    }
}

struct CommandBox: View {
    let command: String
    /// When set, Reclaim can run this itself (Homebrew only) after the user confirms.
    var runnable: BrewCommand? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let runnable, model.brewAvailable {
                Button { model.requestBrew(runnable) } label: { Label("Run…", systemImage: "play.fill") }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .help("Shows the command and runs it after you confirm")
            }
            Button("Copy") { model.copy(command) }
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Confirms, runs and shows the output of a Homebrew command.
struct BrewSheet: View {
    let command: BrewCommand
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mug.fill").font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title).font(.title2.bold())
                    Text(command.explanation).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(command.display)
                .font(.system(.body, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            switch model.brewState {
            case .confirming:
                Text("Reclaim will run exactly this, with Homebrew's own tools. Homebrew only changes the packages it installed, and everything it does is printed here.")
                    .font(.callout).foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running…").font(.callout) }
            case .finished(let status):
                Label(status == 0 ? "Done." : "Homebrew reported a problem (exit code \(status)). See the output.",
                      systemImage: status == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status == 0 ? .green : .orange).font(.callout)
            }

            if !model.brewOutput.isEmpty {
                ScrollView {
                    Text(model.brewOutput).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(minHeight: 160, maxHeight: 260)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                switch model.brewState {
                case .confirming:
                    Button("Cancel", role: .cancel) { model.dismissBrew() }.keyboardShortcut(.cancelAction)
                    Button("Run") { model.runBrew() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .running:
                    Button("Running…") {}.disabled(true)
                case .finished:
                    Button("Done") { model.dismissBrew() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        let color: Color = risk == .safe ? .green : (risk == .review ? .orange : .red)
        Text(risk.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct FileKind {
    static func color(for node: FileNode) -> Color {
        if node.isDirectory {
            var h: UInt64 = 1469598103934665603
            for b in node.name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return Color(hue: Double(h % 360) / 360, saturation: 0.5, brightness: 0.58)
        }
        switch node.ext {
        case "mov", "mp4", "m4v", "mkv", "avi": return Color(hue: 0.75, saturation: 0.55, brightness: 0.62)
        case "jpg", "jpeg", "png", "heic", "raw", "dng", "tiff": return Color(hue: 0.38, saturation: 0.55, brightness: 0.55)
        case "zip", "dmg", "pkg", "iso", "gz", "xip", "7z", "tar": return Color(hue: 0.08, saturation: 0.65, brightness: 0.70)
        default: return Color(hue: 0.58, saturation: 0.35, brightness: 0.55)
        }
    }
}

/// One control that says exactly what will happen to an item: Keep or Remove.
struct KeepRemoveToggle: View {
    @Binding var remove: Bool
    var removeLabel = "Remove"
    var enabled = true

    var body: some View {
        Picker("", selection: $remove) {
            Text("Keep").tag(false)
            Text(removeLabel).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .tint(remove ? .red : .green)
        .disabled(!enabled)
        .help(enabled ? "Choose what happens to this one" : "Reclaim won't remove this one")
    }
}

/// A progress fraction that is always a finite number in 0…1. `ProgressView` misbehaves on NaN or overflow.
func safeFraction(_ value: Double, of total: Double = 1) -> Double {
    guard total > 0, value.isFinite, total.isFinite else { return 0 }
    return min(1, max(0, value / total))
}

func ageText(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(.relative(presentation: .named))
}

/// Shown when iCloud-only files were left alone, so the user knows nothing was downloaded.
struct CloudNote: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count) file\(count == 1 ? " is" : "s are") stored only in iCloud, so Reclaim skipped \(count == 1 ? "it" : "them"). Looking inside would make your Mac download \(count == 1 ? "it" : "them").",
                  systemImage: "icloud")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
