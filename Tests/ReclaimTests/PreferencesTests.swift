import Foundation
import Testing

@testable import Reclaim

// Tests for the preview step (it must decide exactly like the real run and change nothing) and for the remembered
// settings (round trip, stale folders, bad values, reset).

private func tempDir() -> String {
    let dir = NSTemporaryDirectory() + "reclaim-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// A `UserDefaults` that lives only for one test, so tests never touch the real settings.
private func scratchDefaults() -> (UserDefaults, () -> Void) {
    let name = "reclaim-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

@Suite struct EvictWordingTests {
    @Test func eachEvictRefusalHasItsOwnWording() {
        #expect(CloudEvict.Status(inCloud: false, uploaded: false, downloaded: false).refusal == "Not in iCloud.")
        #expect(CloudEvict.Status(inCloud: true, uploaded: false, downloaded: true).refusal == "Still uploading to iCloud.")
        #expect(CloudEvict.Status(inCloud: true, uploaded: true, downloaded: false).refusal == "Already in iCloud only.")
        #expect(CloudEvict.Status(inCloud: true, uploaded: true, downloaded: true).refusal == nil)
    }
}

@Suite struct BrewPreviewTests {
    private func command(_ text: String) -> BrewCommand? { BrewCommand.parse(text, title: "t", explanation: "e") }

    @Test func cleanupAndAutoremoveGetHomebrewsOwnDryRun() {
        #expect(command("brew cleanup")?.previewArguments == ["cleanup", "--dry-run"])
        #expect(command("brew cleanup -s")?.previewArguments == ["cleanup", "-s", "--dry-run"])
        #expect(command("brew autoremove")?.previewArguments == ["autoremove", "--dry-run"])
    }

    @Test func dryRunIsNotAddedTwice() {
        #expect(command("brew cleanup --dry-run")?.previewArguments == ["cleanup", "--dry-run"])
    }

    @Test func uninstallHasNoPreview() {
        // Homebrew has no dry run for uninstall, so the sheet must not pretend to offer one.
        #expect(command("brew uninstall --cask foo")?.previewArguments == nil)
    }
}

@Suite struct PreferencesTests {
    private let present: (String) -> Bool = { _ in true }

    @Test func firstLaunchGivesTheDefaults() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        let loaded = Preferences.load(from: defaults, fileExists: present)
        #expect(loaded == Settings.defaults(fileExists: present))
        #expect(loaded.dupMinSize == 1 << 20)
        #expect(loaded.photoStrictness == .balanced)
    }

    @Test func choicesSurviveARestart() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        var settings = Settings.defaults(fileExists: present)
        settings.dupFolders = [URL(fileURLWithPath: "/Users/x/Archive")]
        settings.dupMinSize = 10 << 20
        settings.photoSource = "Photos library"
        settings.photoFolders = [URL(fileURLWithPath: "/Users/x/Camera")]
        settings.photoStrictness = .loose
        Preferences.save(settings, to: defaults)
        #expect(Preferences.load(from: defaults, fileExists: present) == settings)
    }

    @Test func foldersThatNoLongerExistAreDropped() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        var settings = Settings.defaults(fileExists: present)
        settings.dupFolders = [URL(fileURLWithPath: "/Volumes/Gone/Photos"), URL(fileURLWithPath: "/Users/x/Here")]
        Preferences.save(settings, to: defaults)
        let loaded = Preferences.load(from: defaults, fileExists: { $0 != "/Volumes/Gone/Photos" })
        #expect(loaded.dupFolders == [URL(fileURLWithPath: "/Users/x/Here")])
    }

    @Test func ifEverySavedFolderIsGoneTheDefaultsReturn() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        var settings = Settings.defaults(fileExists: present)
        settings.photoFolders = [URL(fileURLWithPath: "/Volumes/Gone/A")]
        Preferences.save(settings, to: defaults)
        let loaded = Preferences.load(from: defaults, fileExists: { !$0.hasPrefix("/Volumes/Gone") })
        #expect(loaded.photoFolders == Settings.defaults(fileExists: { !$0.hasPrefix("/Volumes/Gone") }).photoFolders)
        #expect(!loaded.photoFolders.isEmpty)
    }

    @Test func aListTheUserEmptiedStaysEmpty() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        var settings = Settings.defaults(fileExists: present)
        settings.dupFolders = []
        Preferences.save(settings, to: defaults)
        #expect(Preferences.load(from: defaults, fileExists: present).dupFolders.isEmpty)
    }

    @Test func nonsenseValuesAreIgnored() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        defaults.set(12345, forKey: "settings.dupMinSize")
        defaults.set("Elsewhere", forKey: "settings.photoSource")
        defaults.set("Ultra", forKey: "settings.photoStrictness")
        let loaded = Preferences.load(from: defaults, fileExists: present)
        #expect(loaded.dupMinSize == 1 << 20)
        #expect(loaded.photoSource == "Folders")
        #expect(loaded.photoStrictness == .balanced)
    }
}
