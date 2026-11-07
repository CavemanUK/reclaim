import Testing

@testable import Reclaim

@Suite struct SafetyPolicyTests {
    let policy = SafetyPolicy(home: "/Users/tester")

    @Test func blocksSystemAndOutsideHome() {
        #expect(!policy.verdict(forPath: "/System/Library").isAllowed)
        #expect(!policy.verdict(forPath: "/Applications/Safari.app").isAllowed)
        #expect(!policy.verdict(forPath: "/usr/local/bin/foo").isAllowed)
    }

    @Test func blocksTopLevelHomeFolders() {
        #expect(!policy.verdict(forPath: "/Users/tester").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Documents").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library").isAllowed)
    }

    @Test func blocksProtectedInsideHome() {
        #expect(!policy.verdict(forPath: "/Users/tester/Pictures/Photos Library.photoslibrary/originals/a.jpg").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/.ssh/id_ed25519").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/code/proj/.git/objects").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Preferences/x.plist").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support/Slack").isAllowed)
    }

    @Test func allowsNormalCleanupTargets() {
        #expect(policy.verdict(forPath: "/Users/tester/Downloads/old.dmg").isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Caches/com.example.app").isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Developer/Xcode/DerivedData/Proj-abc").isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/dev/app/node_modules").isAllowed)
    }

    @Test func protectsBackupsAndManagedLibraries() {
        #expect(!policy.verdict(forPath: "/Volumes/TM/Backups.backupdb/Mac/2026-01-01/x").isAllowed)
        #expect(!policy.verdict(forPath: "/Volumes/TM/Mac.sparsebundle/bands/1").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Music/Music/Music Library.musiclibrary/x").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Movies/Project.imovielibrary/a").isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/.Trash/old.zip").isAllowed)
    }

    @Test func externalVolumes() {
        #expect(!policy.verdict(forPath: "/Volumes/External").isAllowed)
        // A missing top-level path is assumed to be a folder, so it is protected.
        #expect(!policy.verdict(forPath: "/Volumes/External/Developer").isAllowed)
        #expect(policy.verdict(forPath: "/Volumes/External/Developer/old-build.zip").isAllowed)
    }
}

@Suite struct InsightTests {
    private func insight(risk: Risk, category: InsightCategory) -> Insight {
        Insight(
            id: "x", title: "t", summary: "s", icon: "i", category: category, risk: risk,
            items: [InsightItem(path: "/Users/t/Downloads/a", name: "a", size: 100, note: nil, trashable: true)],
            totalBytes: 100, command: nil, advice: nil)
    }

    @Test func biggestFilesAreNotPromisedAsSavings() {
        #expect(insight(risk: .safe, category: .caches).potentialBytes == 100)
        #expect(insight(risk: .review, category: .downloads).potentialBytes == 100)
        #expect(insight(risk: .review, category: .media).potentialBytes == 0)
        #expect(insight(risk: .careful, category: .backups).potentialBytes == 0)
    }
}

@Suite struct ClassifierTests {
    let home = "/Users/tester"

    @Test func categories() {
        #expect(SpaceClassifier.category(forPath: "/Applications/Foo.app", home: home) == .apps)
        #expect(SpaceClassifier.category(forPath: home + "/Library/Caches/x", home: home) == .caches)
        #expect(SpaceClassifier.category(forPath: home + "/Library/Application Support/Slack", home: home) == .appData)
        #expect(SpaceClassifier.category(forPath: home + "/Documents/a/node_modules", home: home) == .developer)
        #expect(SpaceClassifier.category(forPath: "/private/var/folders/zz", home: home) == .caches)
        #expect(SpaceClassifier.category(forPath: "/Users/other/Documents", home: home) == .otherUsers)
        #expect(SpaceClassifier.category(forPath: home + "/.ollama/models", home: home) == .ai)
    }

    @Test func breakdownAddsUpExactly() {
        let root = FileNode(name: "/", path: "/", isDirectory: true, size: 1000, modified: nil)
        let apps = FileNode(name: "Applications", path: "/Applications", isDirectory: true, size: 400, modified: nil)
        let users = FileNode(name: "Users", path: "/Users", isDirectory: true, size: 500, modified: nil)
        root.children = [users, apps]
        let totals = SpaceClassifier.breakdown(root: root, home: home)
        #expect(totals.reduce(0) { $0 + $1.bytes } == 1000)
    }
}
