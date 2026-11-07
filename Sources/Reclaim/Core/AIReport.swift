// The written report. The design is facts in, text out: `ReportFacts` reduces a scan to short factual lines (names
// and sizes, never file contents), and `AIReport` turns them into three Markdown sections, either with Apple's
// on-device model or, when that isn't available, with a deterministic built-in writer working from the same facts.
// Nothing leaves the Mac either way.

import Foundation
import FoundationModels

/// Everything the report may talk about, as short factual lines. The model never sees file contents,
/// only names and sizes, and it is told to use nothing but these facts.
struct ReportFacts {
    /// One fact per line, in plain English, e.g. "Category 'Caches': 12 GB." The built-in writer finds facts by their prefixes.
    var lines: [String] = []

    /// Reduces the app's current state to facts.
    ///
    /// Besides raw figures it adds two lines that steer the wording: the free-space situation (how assertive to be) and
    /// a usage profile (so, for example, a developer is not told to remove their tools). `trend` and `freedByReclaim`
    /// add a comparison with the previous scan when there is one.
    static func build(
        volume: VolumeInfo, report: SpaceReport?, insights: [Insight], apps: [InstalledApp],
        duplicateBytes: Int64, similarBytes: Int64, clearoutCount: Int, home: String,
        trend: ScanComparison? = nil, freedByReclaim: Int64 = 0
    ) -> ReportFacts {
        var f = ReportFacts()
        let total = report?.container.ceiling ?? volume.total
        let free = report?.container.free ?? volume.available
        let freeFraction = safeFraction(Double(free), of: Double(total))
        f.lines.append("Drive: \(ByteFormat.string(total)) in total, \(ByteFormat.string(free)) free (\(Int((1 - freeFraction) * 100))% used).")

        // How urgent is this, and how is the Mac used? The report is tailored to both.
        let urgency: String
        switch freeFraction {
        case ..<0.08: urgency = "critical: under 8% free; macOS may struggle to update or save. Be assertive."
        case ..<0.15: urgency = "low: under 15% free. Recommend the bigger wins even if they need a review."
        case ..<0.30: urgency = "fine: between 15% and 30% free. Suggest safe clean-ups; no need to be aggressive."
        default: urgency = "comfortable: over 30% free. Only mention clean-ups that are clearly worthwhile; reassure the owner."
        }
        f.lines.append("Free-space situation is \(urgency)")

        var signals: [String] = []
        func cat(_ c: SpaceCategory) -> Int64 { report?.categories.first { $0.category == c }?.bytes ?? 0 }
        if cat(.developer) + cat(.tools) > 3 << 30 { signals.append("writes software (developer tools and caches take \(ByteFormat.string(cat(.developer) + cat(.tools))); keep tools they use, only clear rebuildable caches)") }
        if cat(.photos) > 5 << 30 { signals.append("keeps a large photo library (\(ByteFormat.string(cat(.photos))))") }
        if cat(.yourFiles) > 20 << 30 { signals.append("stores a lot of their own files (\(ByteFormat.string(cat(.yourFiles))))") }
        if cat(.ai) > 0 { signals.append("runs AI models locally (\(ByteFormat.string(cat(.ai))))") }
        if cat(.backups) > 0 { signals.append("keeps iPhone/iPad backups on this Mac (\(ByteFormat.string(cat(.backups))))") }
        let recent = apps.filter { ($0.lastUsed.map { Date().timeIntervalSince($0) } ?? .infinity) < 7 * 86400 }.count
        if !apps.isEmpty { signals.append("has \(apps.count) apps installed and used \(recent) of them in the last week") }
        f.lines.append("Usage profile: this person " + (signals.isEmpty ? "uses the Mac lightly." : signals.joined(separator: "; ") + "."))
        if let r = report {
            if let sys = r.container.systemVolume { f.lines.append("macOS itself: \(ByteFormat.string(sys.inUse)), cannot be reduced.") }
            for c in r.categories.prefix(8) { f.lines.append("Category '\(c.category.rawValue)': \(ByteFormat.string(c.bytes)).") }
            if r.purgeableInGap > 0 { f.lines.append("Purgeable (macOS frees it by itself): \(ByteFormat.string(r.purgeableInGap)).") }
            if r.unexplainedRemainder > 1 << 30 {
                f.lines.append("Hidden from apps (system-only folders such as Spotlight's index and document version history): \(ByteFormat.string(r.unexplainedRemainder)).")
            }
            f.lines.append(r.snapshots.isEmpty ? "No Time Machine snapshots." : "Time Machine snapshots on the drive: \(r.snapshots.count).")
        }
        let safeWins = insights.filter { $0.potentialBytes > 0 }.sorted { $0.potentialBytes > $1.potentialBytes }
        for i in safeWins.prefix(7) {
            f.lines.append("Clean up card '\(i.title)' (\(i.risk.label)): \(ByteFormat.string(i.potentialBytes)) Reclaim can move to the Trash.")
        }
        for i in insights where i.potentialBytes == 0 && i.totalBytes >= 1 << 30 {
            let how = i.command != nil ? "has a command" : (i.advice != nil ? "has instructions" : "is for information")
            f.lines.append("Clean up card '\(i.title)' (\(i.risk.label)): \(i.partial ? "up to " : "")\(ByteFormat.string(i.totalBytes)); \(how).")
        }
        if let t = trend {
            let direction = t.usedChange >= 0 ? "grew" : "shrank"
            var line = "Compared with the previous scan \(Int(t.days.rounded())) day\(Int(t.days.rounded()) == 1 ? "" : "s") ago, used space \(direction) by \(ByteFormat.string(abs(t.usedChange)))."
            if let g = t.biggestGrowth { line += " The category that grew most was '\(g.name)' (+\(ByteFormat.string(g.change)))." }
            if freedByReclaim > 0 { line += " Reclaim itself freed \(ByteFormat.string(freedByReclaim)) in that time." }
            f.lines.append(line)
        }
        if duplicateBytes > 0 { f.lines.append("Duplicates screen: \(ByteFormat.string(duplicateBytes)) of exact copies found.") }
        if similarBytes > 0 { f.lines.append("Similar photos screen: \(ByteFormat.string(similarBytes)) of near-identical photos found.") }
        if clearoutCount > 0 { f.lines.append("Photo clear-outs screen: \(clearoutCount) screenshots, text photos or burst extras found.") }
        if !SystemInfo.hasFullDiskAccess() {
            f.lines.append("Reclaim does not have Full Disk Access, so part of the 'hidden' figure is simply folders it wasn't allowed to read; granting access would make the picture more accurate.")
        }
        let unused = apps.filter { ($0.lastUsed.map { Date().timeIntervalSince($0) } ?? .infinity) > 90 * 86400 && $0.size >= 200 << 20 }
            .sorted { $0.size > $1.size }.prefix(4)
        for a in unused { f.lines.append("App '\(a.name)' is \(ByteFormat.string(a.size)) and \(a.lastUsed == nil ? "has never been opened" : "hasn't been opened for over three months"). Uninstall apps screen can remove it.") }
        return f
    }

    /// The facts as a bullet list, which is what the model is given.
    var text: String { lines.map { "- " + $0 }.joined(separator: "\n") }
}

/// Who wrote a report, so the Overview can say so honestly.
enum ReportSource: Sendable {
    case appleIntelligence
    case builtIn(String)   // why the on-device model wasn't used
}

/// Writes the report from `ReportFacts`.
///
/// The model is told to use only the facts it is given and to invent no numbers, names or paths. That keeps the
/// report to what the scan actually found, which matters because the reader may act on it.
enum AIReport {
    /// The system prompt: tone, length, the three required headings, and rules that stop it contradicting the facts
    /// (for instance never advising a developer to remove tools, never listing caches as something to leave alone).
    static let instructions = """
        You are the assistant inside Reclaim, a Mac disk clean-up app. Write a short report for the Mac's owner, \
        who is not technical. Use only the facts you are given. Never invent numbers, names or paths, and never \
        suggest Terminal commands.
        Tailor the advice to two facts in particular: the free-space situation (be assertive when space is critical, \
        relaxed and reassuring when there is plenty) and the usage profile (never tell someone who writes software to \
        remove their developer tools or SDKs; never tell a photographer to shrink their library; prefer things they \
        clearly don't use, such as apps not opened for months).
        Caches are always safe to clear (apps rebuild them), so never describe caches as essential. Treat the \
        'hidden' figure as macOS's own bookkeeping, and mention it in one sentence if it is over 10 GB. \
        Ignore anything under 200 MB unless nothing bigger exists. Describe how full the drive is accurately: \
        under 70% used is not "most of the space".
        If a fact compares this scan with the previous one, mention the trend in one sentence in the first section.
        Format exactly these three headings in Markdown:
        ## Where your space went
        Two or three sentences, the first stating plainly whether space is tight or comfortable.
        ## Do these first
        A numbered list of at most five steps, biggest safe win first. Each step names the Reclaim screen or card \
        to use and the amount it would free.
        ## Leave these alone
        One or two sentences about what not to touch and why (macOS itself, hidden bookkeeping, tools and \
        libraries the person clearly uses). Never list caches here.
        Plain British English, warm but direct, under 220 words.
        """

    /// Writes the report with Apple's on-device model when Apple Intelligence is available, otherwise with
    /// Reclaim's own wording. Nothing leaves the Mac either way.
    static func write(facts: ReportFacts) async -> (text: String, source: ReportSource) {
        // FoundationModels needs macOS 26; older systems go straight to the built-in writer below.
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: "Facts about this Mac:\n\(facts.text)\n\nWrite the report.")
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    // The built-in writer takes over if the answer doesn't have the expected Markdown headings.
                    if text.contains("## ") { return (text, .appleIntelligence) }
                    return (builtIn(facts), .builtIn("The on-device model gave an unusable answer, so this is Reclaim's own wording."))
                } catch {
                    return (builtIn(facts), .builtIn("The on-device model couldn't write it (\(error.localizedDescription)), so this is Reclaim's own wording."))
                }
            case .unavailable(let reason):
                let why: String
                switch reason {
                case .appleIntelligenceNotEnabled: why = "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri for a tailored version."
                case .modelNotReady: why = "Apple Intelligence is still downloading its model. Try again later for a tailored version."
                case .deviceNotEligible: why = "This Mac can't run Apple Intelligence."
                @unknown default: why = "Apple Intelligence isn't available right now."
                }
                return (builtIn(facts), .builtIn(why))
            }
        }
        return (builtIn(facts), .builtIn("Apple's on-device model needs macOS 26 or later."))
    }

    /// The built-in writer: a deterministic report in the same three sections, built from the same facts, for when the
    /// on-device model is unavailable or gives an unusable answer.
    ///
    /// It picks facts out by their leading text (for example "Clean up card '"), so changing the wording of a line in
    /// `ReportFacts.build` means changing it here too.
    static func builtIn(_ facts: ReportFacts) -> String {
        func line(_ prefix: String) -> [String] { facts.lines.filter { $0.hasPrefix(prefix) } }
        let urgent = line("Free-space situation is critical").first != nil || line("Free-space situation is low").first != nil
        let comfortable = line("Free-space situation is comfortable").first != nil
        let developer = facts.lines.contains { $0.contains("writes software") }
        var out: [String] = []
        out.append("## Where your space went")
        var where_: [String] = []
        if let drive = line("Drive:").first { where_.append(drive) }
        if comfortable { where_.append("You have plenty of room, so nothing here is urgent.") }
        if urgent { where_.append("Space is tight, so it's worth acting on the first few steps below soon.") }
        let cats = line("Category '").prefix(3).map { $0.replacingOccurrences(of: "Category '", with: "").replacingOccurrences(of: "':", with: " takes") .dropLast() }
        if !cats.isEmpty { where_.append("The biggest areas are " + cats.map(String.init).joined(separator: ", ") + ".") }
        if let hidden = line("Hidden from apps").first { where_.append(hidden) }
        out.append(where_.joined(separator: " "))
        out.append("")
        out.append("## Do these first")
        var steps: [String] = []
        for l in line("Clean up card '") where l.contains("Reclaim can move") && !l.contains("Be careful") {
            // Someone who writes software should keep their SDKs and tools; only rebuildable caches are fair game.
            if developer, l.contains("Android") || l.contains("Xcode archives") || l.contains("Simulators") { continue }
            if comfortable, !l.contains("Safe to remove") { continue }
            steps.append(l.replacingOccurrences(of: "Clean up card ", with: "On Clean up, open ") .replacingOccurrences(of: " Reclaim can move to the Trash.", with: " can go to the Trash."))
            if steps.count == 3 { break }
        }
        if let d = line("Duplicates screen").first { steps.append("On Duplicates, remove the extra copies: " + d.replacingOccurrences(of: "Duplicates screen: ", with: "")) }
        if let s = line("Similar photos screen").first, steps.count < 5 { steps.append("On Similar photos, keep the best of each set: " + s.replacingOccurrences(of: "Similar photos screen: ", with: "")) }
        for a in line("App '") where steps.count < 5 { steps.append("On Uninstall apps: " + a) }
        if steps.isEmpty { steps.append("Nothing large is safe to remove automatically. Use What's big to look through your own files.") }
        out.append(contentsOf: steps.enumerated().map { "\($0.offset + 1). \($0.element)" })
        out.append("")
        out.append("## Leave these alone")
        var leave = ["macOS itself and the startup volumes are managed by Apple and can't be reduced."]
        if developer { leave.append("Your developer tools and SDKs are in use; only their caches are worth clearing.") }
        if line("Hidden from apps").first != nil { leave.append("The hidden system-only folders are Spotlight's index and document history; macOS looks after those.") }
        out.append(leave.joined(separator: " "))
        return out.joined(separator: "\n")
    }
}
