import Foundation
import os

// Runs the small set of Homebrew commands Reclaim offers, and only after the user has approved them.
// `BrewCommand.parse` is the allow-list gate; `CommandRunner.runBrew` executes and streams the output.

/// A command Reclaim may run for the user after they approve it. Only Homebrew: it manages its own packages,
/// never needs sudo for the operations offered here, and prints what it does.
struct BrewCommand: Identifiable, Equatable, Sendable {
    let id = UUID()
    let arguments: [String]          // after "brew"
    let title: String
    let explanation: String

    /// The command as a user would type it, for showing and copying.
    var display: String { (["brew"] + arguments).joined(separator: " ") }

    /// The same command with Homebrew's own `--dry-run`, which lists what would be removed and removes nothing.
    /// Nil for `uninstall`, which has no dry run. Only `cleanup` and `autoremove` are previewable.
    var previewArguments: [String]? {
        guard let first = arguments.first, ["cleanup", "autoremove"].contains(first) else { return nil }
        return arguments.contains("--dry-run") ? arguments : arguments + ["--dry-run"]
    }

    /// Subcommands Reclaim is willing to run. Anything else only ever appears as text to copy.
    static let allowed: Set<String> = ["cleanup", "autoremove", "uninstall"]

    /// Turns a suggested command line into a runnable `BrewCommand`, or returns nil if it is not allowed.
    ///
    /// Only `brew` followed by one of `allowed` is accepted, and every word may contain only letters, digits and
    /// `-_.@+/`, so shell metacharacters can never get through. Anything after a `#` is dropped as a comment.
    static func parse(_ text: String, title: String, explanation: String) -> BrewCommand? {
        let line = text.split(separator: "#").first.map(String.init) ?? text
        let parts = line.split(separator: " ").map(String.init)
        guard parts.first == "brew", parts.count >= 2, allowed.contains(parts[1]) else { return nil }
        guard parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.@+/".contains($0) } }) else { return nil }
        return BrewCommand(arguments: Array(parts.dropFirst()), title: title, explanation: explanation)
    }
}

/// Runs approved commands as child processes.
enum CommandRunner {
    /// Locates Homebrew for Apple Silicon or Intel Macs, or nil if it is not installed.
    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `brew <arguments>`, streaming combined output. Returns the exit status, or nil if brew is missing.
    static func runBrew(_ arguments: [String], onOutput: @escaping @Sendable (String) -> Void) async -> Int32? {
        guard let brew = brewPath() else { return nil }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            // Keep brew non-interactive, colourless and quick: there is no terminal attached, and output is shown as plain text.
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_COLOR"] = "0"
            env["NONINTERACTIVE"] = "1"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            // Decode on UTF-8 boundaries: Homebrew prints emoji, and a chunk can end mid-character.
            let buffer = OSAllocatedUnfairLock(initialState: Data())
            @Sendable func drain(_ data: Data, final: Bool) {
                let text: String? = buffer.withLock { buf in
                    buf.append(data)
                    var cut = buf.count
                    if !final {
                        // Back up to the start of any incomplete trailing multi-byte sequence.
                        var i = buf.count - 1
                        while i >= 0, i >= buf.count - 4, buf[i] & 0xC0 == 0x80 { i -= 1 }
                        if i >= 0, buf[i] & 0x80 != 0 {
                            let need = buf[i] & 0xF0 == 0xF0 ? 4 : (buf[i] & 0xE0 == 0xE0 ? 3 : 2)
                            if buf.count - i < need { cut = i }
                        }
                    }
                    guard cut > 0 else { return nil }
                    let piece = String(decoding: buf.prefix(cut), as: UTF8.self)
                    buf.removeFirst(cut)
                    return piece
                }
                if let text, !text.isEmpty { onOutput(text) }
            }
            // The readability handler and the termination handler run on different queues, so `drain` guards its
            // buffer with a lock.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { drain(data, final: false) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                drain(pipe.fileHandleForReading.readDataToEndOfFile(), final: true)
                continuation.resume(returning: p.terminationStatus)
            }
            // If the process cannot start, `terminationHandler` never fires, so the continuation is resumed here instead.
            do {
                try process.run()
            } catch {
                onOutput("Couldn't start Homebrew: \(error.localizedDescription)\n")
                continuation.resume(returning: 1)
            }
        }
    }
}
