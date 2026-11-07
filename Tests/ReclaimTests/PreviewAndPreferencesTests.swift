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

@Suite struct PreviewTests {
    /// A log whose safety policy treats a temporary folder as the home folder, so allowed paths can be tested.
    private func makeLog(home: String) -> ActionLog {
        ActionLog(fileURL: URL(fileURLWithPath: home + "/history.json"), policy: SafetyPolicy(home: home))
    }

    @Test func previewMovesNothingAndRecordsNothing() throws {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = home + "/Downloads/keep-me.txt"
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data([1, 2, 3]))
        let log = makeLog(home: home)

        let lines = log.previewTrash([(file, 3)])

        #expect(lines.count == 1)
        if case .refused = lines[0].outcome { Issue.record("an ordinary file in Downloads should be previewable") }
        #expect(FileManager.default.fileExists(atPath: file), "preview must leave the file where it is")
        #expect(log.entries.isEmpty, "preview must not write anything to the undo history")
        #expect(!FileManager.default.fileExists(atPath: home + "/history.json"), "preview must not save a history file")
    }

    @Test func previewRefusesTheSameThingsTheRealRunRefuses() {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let log = makeLog(home: home)
        // Nothing here can be moved: one is outside the home folder, one doesn't exist. So running the real
        // `trash` is safe, and its refusals must match the preview word for word.
        let items: [(path: String, size: Int64)] = [("/etc/hosts", 10), (home + "/Downloads/missing.txt", 5)]

        let preview = log.previewTrash(items)
        let real = log.trash(items, reason: "test").failed

        #expect(real.count == 2)
        for (line, failure) in zip(preview, real) {
            #expect(line.outcome == .refused(failure.message))
        }
    }

    @Test func previewOfAMissingFileSaysSo() {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lines = makeLog(home: home).previewTrash([(home + "/Downloads/nope.txt", 1)])
        #expect(lines.first?.outcome == .refused("File no longer exists."))
    }

    @Test func evictPreviewRefusesAFileThatIsNotInICloud() {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = home + "/plain.txt"
        FileManager.default.createFile(atPath: file, contents: Data([1]))
        let lines = makeLog(home: home).previewEvict([(file, 1)])
        #expect(lines.first?.outcome == .refused("Not in iCloud."))
        #expect(FileManager.default.fileExists(atPath: file))
    }

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

    @Test func resetForgetsEverythingSavedAndNothingElse() {
        let (defaults, cleanup) = scratchDefaults(); defer { cleanup() }
        defaults.set(["/Users/x/Mine"], forKey: "customFolders")   // saved elsewhere in the app; must survive
        var settings = Settings.defaults(fileExists: present)
        settings.photoStrictness = .strict
        Preferences.save(settings, to: defaults)
        Preferences.reset(in: defaults)
        #expect(Preferences.load(from: defaults, fileExists: present) == Settings.defaults(fileExists: present))
        #expect(defaults.stringArray(forKey: "customFolders") == ["/Users/x/Mine"])
    }
}
