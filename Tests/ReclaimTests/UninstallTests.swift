import Foundation
import Testing

@testable import Reclaim

@Suite struct LeftoverMatchTests {
    @Test func matchesByBundleIdentifier() {
        #expect(LeftoverMatch.matches(name: "com.vendor.thing", bundleID: "com.vendor.thing", appName: "Thing"))
        #expect(LeftoverMatch.matches(name: "com.vendor.thing.helper", bundleID: "com.vendor.thing", appName: "Thing"))
        #expect(LeftoverMatch.matches(name: "group.com.vendor.thing", bundleID: "com.vendor.thing", appName: "Thing"))
        #expect(LeftoverMatch.matches(name: "ABC123.com.vendor.thing", bundleID: "com.vendor.thing", appName: "Thing"))
        #expect(!LeftoverMatch.matches(name: "com.vendor.other", bundleID: "com.vendor.thing", appName: "Thing"))
        #expect(!LeftoverMatch.matches(name: "com.vendor", bundleID: "com.vendor.thing", appName: "Thing"))
    }

    @Test func nameMatchingIsCautious() {
        #expect(LeftoverMatch.matches(name: "Blender", bundleID: "org.blender", appName: "Blender"))
        #expect(LeftoverMatch.matches(name: "GoogleChrome", bundleID: nil, appName: "Google Chrome"))
        // Generic names would catch Apple's own data, so they never match by name.
        #expect(!LeftoverMatch.matches(name: "Music", bundleID: "com.example.player", appName: "Music"))
        #expect(!LeftoverMatch.matches(name: "Mail", bundleID: nil, appName: "Mail"))
        #expect(!LeftoverMatch.matches(name: "App", bundleID: nil, appName: "App"))
        #expect(!LeftoverMatch.matches(name: "Zip", bundleID: nil, appName: "Zip"))   // too short
    }
}

@Suite struct BrewCommandTests {
    @Test func onlySafeHomebrewSubcommandsRun() {
        #expect(BrewCommand.parse("brew cleanup -s", title: "t", explanation: "e")?.arguments == ["cleanup", "-s"])
        #expect(BrewCommand.parse("brew autoremove", title: "t", explanation: "e") != nil)
        #expect(BrewCommand.parse("brew uninstall --cask blender", title: "t", explanation: "e")?.display == "brew uninstall --cask blender")
        #expect(BrewCommand.parse("brew cleanup -s   # trailing note", title: "t", explanation: "e") != nil)
        #expect(BrewCommand.parse("brew install evil", title: "t", explanation: "e") == nil)
        #expect(BrewCommand.parse("sudo rm -rf /", title: "t", explanation: "e") == nil)
        #expect(BrewCommand.parse("brew cleanup; rm -rf ~", title: "t", explanation: "e") == nil)
        #expect(BrewCommand.parse("brew uninstall --cask $(whoami)", title: "t", explanation: "e") == nil)
        #expect(BrewCommand.parse("xcrun simctl delete unavailable", title: "t", explanation: "e") == nil)
    }
}

@Suite struct SiblingProductTests {
    let others: Set<String> = ["com.google.Chrome.canary", "com.google.Chrome.beta", "com.jetbrains.intellij.ce"]

    @Test func siblingProductsAreNeverHelpers() {
        // Chrome's own helper still matches…
        #expect(LeftoverMatch.matches(name: "com.google.Chrome.helper", bundleID: "com.google.Chrome", appName: "Google Chrome", others: others))
        // …but Canary and Beta are separate apps, so their data is left alone when uninstalling Chrome.
        #expect(!LeftoverMatch.matches(name: "com.google.Chrome.canary", bundleID: "com.google.Chrome", appName: "Google Chrome", others: others))
        #expect(!LeftoverMatch.matches(name: "com.google.Chrome.canary.helper", bundleID: "com.google.Chrome", appName: "Google Chrome", others: others))
        #expect(!LeftoverMatch.matches(name: "group.com.google.Chrome.beta", bundleID: "com.google.Chrome", appName: "Google Chrome", others: others))
        #expect(!LeftoverMatch.matches(name: "com.jetbrains.intellij.ce", bundleID: "com.jetbrains.intellij", appName: "IntelliJ IDEA", others: others))
    }

    @Test func policyHonoursSiblings() {
        let policy = SafetyPolicy(home: "/Users/tester")
        let scope = UninstallScope(appPath: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome",
                                   appName: "Google Chrome", otherBundleIDs: others)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Containers/com.google.Chrome", uninstalling: scope).isAllowed)
        // Cache folders are removable under the ordinary rules anyway; the folders only an uninstall may touch
        // must refuse a sibling product's entries.
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Containers/com.google.Chrome.canary", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Preferences/com.google.Chrome.canary.plist", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support/com.google.Chrome.beta", uninstalling: scope).isAllowed)
    }

    @Test func systemProtectedAppsAreNeverOffered() {
        // Safari ships with macOS and carries SIP's restricted flag; it must not be uninstallable.
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") {
            #expect(AppInventory.isRestricted("/Applications/Safari.app"))
            let scope = UninstallScope(appPath: "/Applications/Safari.app", bundleID: "com.apple.Safari", appName: "Safari")
            #expect(!SafetyPolicy(home: "/Users/tester").verdict(forPath: "/Applications/Safari.app", uninstalling: scope).isAllowed)
        }
        #expect(!AppInventory.isRestricted(NSTemporaryDirectory()))
    }
}

@Suite struct VendorFolderTests {
    @Test func chromeInsideGoogle() {
        #expect(LeftoverMatch.matchesRelative("Google/Chrome", bundleID: "com.google.Chrome", appName: "Google Chrome"))
        #expect(LeftoverMatch.matchesRelative("Microsoft/Teams", bundleID: "com.microsoft.teams2", appName: "Microsoft Teams"))
        // Never the whole vendor folder, and never a sibling product.
        #expect(!LeftoverMatch.matchesRelative("Google", bundleID: "com.google.Chrome", appName: "Google Chrome"))
        #expect(!LeftoverMatch.matchesRelative("Google/Drive", bundleID: "com.google.Chrome", appName: "Google Chrome"))
        #expect(!LeftoverMatch.matchesRelative("Google/Chrome/Default", bundleID: "com.google.Chrome", appName: "Google Chrome"))
        #expect(!LeftoverMatch.matchesRelative("Microsoft/Office", bundleID: "com.microsoft.Excel", appName: "Microsoft Excel"))
    }

    @Test func policyAllowsVendorNestedData() {
        let policy = SafetyPolicy(home: "/Users/tester")
        let scope = UninstallScope(appPath: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome", appName: "Google Chrome")
        #expect(policy.verdict(forPath: "/Users/tester/Library/Application Support/Google/Chrome", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support/Google", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support/Google/Drive", uninstalling: scope).isAllowed)
    }
}

@Suite struct UninstallPolicyTests {
    let policy = SafetyPolicy(home: "/Users/tester")
    let scope = UninstallScope(appPath: "/Applications/Thing.app", bundleID: "com.vendor.thing", appName: "Thing")

    @Test func allowsExactlyTheAppsFiles() {
        #expect(policy.verdict(forPath: "/Applications/Thing.app", uninstalling: scope).isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Application Support/com.vendor.thing", uninstalling: scope).isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Preferences/com.vendor.thing.plist", uninstalling: scope).isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Saved Application State/com.vendor.thing.savedState", uninstalling: scope).isAllowed)
        #expect(policy.verdict(forPath: "/Users/tester/Library/Containers/com.vendor.thing", uninstalling: scope).isAllowed)
    }

    @Test func stillBlocksEverythingElse() {
        #expect(!policy.verdict(forPath: "/Applications/Other.app", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support/com.vendor.other", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Preferences", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/Library/Application Support/com.vendor.thing", uninstalling: scope).isAllowed)
        #expect(!policy.verdict(forPath: "/System/Applications/Mail.app",
                                uninstalling: UninstallScope(appPath: "/System/Applications/Mail.app", bundleID: "com.apple.mail", appName: "Mail")).isAllowed)
        // Deeper paths inside a matched folder are not individually allowed (the folder goes as a whole).
        #expect(!policy.verdict(forPath: "/Users/tester/Library/Application Support/com.vendor.thing/db.sqlite", uninstalling: scope).isAllowed)
    }

    @Test func plainVerdictStillRefusesApps() {
        #expect(!policy.verdict(forPath: "/Applications/Thing.app").isAllowed)
    }
}
