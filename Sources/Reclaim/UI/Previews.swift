import AVKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnails for any file type macOS can preview (photos, video, PDF, documents), cached.
enum ThumbnailLoader {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        c.totalCostLimit = 300 << 20   // ~300 MB of decoded pixels, then older thumbnails are dropped
        return c
    }()

    static func load(path: String, side: CGFloat) async -> NSImage? {
        let key = "\(path)@\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side), scale: 2,
            representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = NSImage(cgImage: rep.cgImage, size: .zero)
        cache.setObject(image, forKey: key, cost: rep.cgImage.bytesPerRow * rep.cgImage.height)
        return image
    }
}

enum MediaKind {
    case image, video, audio, other

    static func of(path: String) -> MediaKind {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }
}

/// AppKit player with built-in controls. Used instead of SwiftUI's VideoPlayer, which crashes when
/// loaded from a command-line-tools build.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct ThumbView: View {
    let path: String
    let side: CGFloat
    var fit = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().padding(side * 0.2)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) { image = await ThumbnailLoader.load(path: path, side: side) }
    }
}

/// Thumbnail for a photo wherever it lives: a file on disk or a Photos library asset.
struct PhotoThumb: View {
    let photo: PhotoInfo
    let side: CGFloat
    var fit = false

    var body: some View {
        if let id = photo.assetID {
            AssetImage(assetID: id, side: side, fit: fit)
        } else {
            ThumbView(path: photo.path, side: side, fit: fit)
        }
    }
}

struct AssetImage: View {
    let assetID: String
    let side: CGFloat
    var fit = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Image(systemName: "photo").font(.system(size: side * 0.3)).foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: assetID) { image = await LibrarySource.thumbnail(assetID: assetID, side: side) }
    }
}

/// Large preview for the compare sheet. Library photos are still images; files may play.
struct PhotoPreview: View {
    let photo: PhotoInfo
    let height: CGFloat
    @Binding var playingPath: String?
    @State private var image: NSImage?

    var body: some View {
        if let id = photo.assetID {
            ZStack {
                Color.black.opacity(0.18)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: id) { image = await LibrarySource.thumbnail(assetID: id, side: height * 1.6) }
        } else {
            FilePreview(path: photo.path, height: height, playingPath: $playingPath)
        }
    }
}

/// A large preview that plays video and audio in place, one file at a time so you can compare by ear.
struct FilePreview: View {
    let path: String
    let height: CGFloat
    @Binding var playingPath: String?
    @State private var player: AVPlayer?
    @State private var image: NSImage?

    private var kind: MediaKind { MediaKind.of(path: path) }
    private var isPlaying: Bool { playingPath == path }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            if isPlaying, let player {
                PlayerView(player: player)
            } else {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().frame(width: 96)
                }
                if kind == .video || kind == .audio {
                    Button { start() } label: {
                        Image(systemName: "play.circle.fill").font(.system(size: 54))
                            .foregroundStyle(.white, .blue).shadow(radius: 6)
                    }
                    .buttonStyle(.plain)
                    .help(kind == .audio ? "Play to listen" : "Play")
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: path) { image = await ThumbnailLoader.load(path: path, side: height * 1.6) }
        .onChange(of: playingPath) { _, new in
            if new != path { player?.pause(); player = nil }
        }
        .onDisappear { player?.pause() }
    }

    private func start() {
        let p = AVPlayer(url: URL(fileURLWithPath: path))
        player = p
        playingPath = path
        p.play()
    }
}
