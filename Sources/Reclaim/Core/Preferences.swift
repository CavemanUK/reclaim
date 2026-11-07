import Foundation

// The few choices Reclaim remembers between launches: which folders the duplicate and photo searches cover, the
// minimum duplicate size, the photo source and strictness. Scan results and ticked selections are deliberately NOT
// saved. Every session starts with nothing pre-approved.
//
// This is plain data with an injectable `UserDefaults`, so tests use a throwaway store instead of the real one.

/// The remembered choices, with the values used on a first launch.
struct Settings: Equatable {
    var dupFolders: [URL]
    var dupMinSize: Int64
    /// `AppModel.PhotoSourceKind.rawValue`. Kept as text so Core doesn't depend on the model.
    var photoSource: String
    var photoFolders: [URL]
    var photoStrictness: Strictness

    /// What a fresh install starts with: the usual personal folders that exist, 1 MB, folders, balanced.
    static func defaults(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Settings {
        let home = NSHomeDirectory()
        func existing(_ names: [String]) -> [URL] {
            names.map { URL(fileURLWithPath: home + "/" + $0) }.filter { fileExists($0.path) }
        }
        return Settings(
            dupFolders: existing(["Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"]),
            dupMinSize: 1 << 20,
            photoSource: "Folders",
            photoFolders: existing(["Pictures", "Downloads", "Desktop"]),
            photoStrictness: .balanced)
    }
}

/// Reads and writes `Settings` in `UserDefaults`.
enum Preferences {
    private enum Key {
        static let dupFolders = "settings.dupFolders"
        static let dupMinSize = "settings.dupMinSize"
        static let photoSource = "settings.photoSource"
        static let photoFolders = "settings.photoFolders"
        static let photoStrictness = "settings.photoStrictness"
    }

    /// The minimum sizes the picker offers. A saved value that isn't one of them is ignored, so a hand-edited or
    /// corrupt value can never leave the picker with nothing selected.
    static let allowedMinSizes: Set<Int64> = [100 << 10, 1 << 20, 10 << 20]

    /// Loads saved choices over the defaults.
    ///
    /// A folder list that was never saved gets the default folders. A saved list keeps only folders that still exist
    /// (an unplugged drive, a deleted folder). If that leaves nothing at all from a non-empty list, the defaults are
    /// used so the screen isn't left empty. A list the user emptied on purpose stays empty.
    static func load(from defaults: UserDefaults = .standard,
                     fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Settings {
        var settings = Settings.defaults(fileExists: fileExists)

        func folders(_ key: String, fallback: [URL]) -> [URL] {
            guard let saved = defaults.stringArray(forKey: key) else { return fallback }
            let kept = saved.filter(fileExists).map { URL(fileURLWithPath: $0) }
            return (kept.isEmpty && !saved.isEmpty) ? fallback : kept
        }
        settings.dupFolders = folders(Key.dupFolders, fallback: settings.dupFolders)
        settings.photoFolders = folders(Key.photoFolders, fallback: settings.photoFolders)

        let size = defaults.object(forKey: Key.dupMinSize) as? Int64 ?? (defaults.object(forKey: Key.dupMinSize) as? Int).map(Int64.init)
        if let size, allowedMinSizes.contains(size) { settings.dupMinSize = size }
        if let source = defaults.string(forKey: Key.photoSource), ["Folders", "Photos library"].contains(source) {
            settings.photoSource = source
        }
        if let raw = defaults.string(forKey: Key.photoStrictness), let level = Strictness(rawValue: raw) {
            settings.photoStrictness = level
        }
        return settings
    }

    /// Saves every choice.
    static func save(_ settings: Settings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.dupFolders.map(\.path), forKey: Key.dupFolders)
        defaults.set(settings.dupMinSize, forKey: Key.dupMinSize)
        defaults.set(settings.photoSource, forKey: Key.photoSource)
        defaults.set(settings.photoFolders.map(\.path), forKey: Key.photoFolders)
        defaults.set(settings.photoStrictness.rawValue, forKey: Key.photoStrictness)
    }
}
