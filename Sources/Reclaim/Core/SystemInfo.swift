import Foundation

// Read-only queries about the disk that Foundation does not provide directly: APFS container sizes
// (via `diskutil`), Time Machine local snapshots (via `tmutil`), and whether Full Disk Access is granted.
// The results feed the Overview screen's explanation of where the space has gone.

/// One volume inside an APFS container, as listed by `diskutil apfs list`.
struct APFSVolume: Identifiable, Equatable, Sendable {
    var id: String { device }
    /// BSD device identifier, e.g. `disk3s1`.
    let device: String
    let name: String
    /// APFS roles such as "System", "Data", "Preboot", "VM".
    let roles: [String]
    /// Bytes the volume is using (`CapacityInUse`).
    let inUse: Int64

    /// The first role, used as a short label.
    var role: String { roles.first ?? "Volume" }
}

/// The APFS container holding the Data volume. All its volumes share the container's free space, which is
/// why the free figure belongs here and not to a single volume.
struct APFSContainerInfo: Equatable, Sendable {
    /// Total capacity available to the container's volumes (`CapacityCeiling`).
    let ceiling: Int64
    /// Unallocated space in the container (`CapacityFree`).
    let free: Int64
    let volumes: [APFSVolume]

    /// The volume holding the user's files and installed apps.
    var dataVolume: APFSVolume? { volumes.first { $0.roles.contains("Data") } }
    /// The sealed, read-only macOS volume.
    var systemVolume: APFSVolume? { volumes.first { $0.roles.contains("System") } }
}

/// A Time Machine local snapshot, which can keep deleted files' space occupied until it is removed.
struct LocalSnapshot: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    /// The date stamp `tmutil deletelocalsnapshots` expects, e.g. 2026-11-05-103303.
    let stamp: String
    let date: Date?
}

/// Read-only questions we ask macOS about the disk. Nothing here changes anything.
enum SystemInfo {
    /// Runs a tool and returns its standard output, or nil if it could not be launched. The process is
    /// terminated after `timeout` seconds so a hung tool cannot block the caller forever.
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 20) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        // Never leave stderr on an unread pipe: a chatty tool would fill it and block until the timeout.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// The APFS container that holds the user's Data volume.
    static func apfsContainer() -> APFSContainerInfo? {
        guard let data = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let containers = plist["Containers"] as? [[String: Any]]
        else { return nil }

        for container in containers {
            let volumes = (container["Volumes"] as? [[String: Any]] ?? []).map { v in
                APFSVolume(
                    device: v["DeviceIdentifier"] as? String ?? "?", name: v["Name"] as? String ?? "?",
                    roles: v["Roles"] as? [String] ?? [], inUse: (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }
            guard volumes.contains(where: { $0.roles.contains("Data") }) else { continue }
            return APFSContainerInfo(
                ceiling: (container["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0,
                free: (container["CapacityFree"] as? NSNumber)?.int64Value ?? 0, volumes: volumes)
        }
        return nil
    }

    /// Lists local snapshots from `tmutil listlocalsnapshots /`. Snapshot names end in the date stamp,
    /// which is split off so it can be passed back to `tmutil` and parsed as a `Date`.
    static func localSnapshots() -> [LocalSnapshot] {
        guard let data = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return text.split(separator: "\n").compactMap { line in
            let name = String(line)
            guard name.hasPrefix("com.apple.") else { return nil }
            let parts = name.split(separator: ".")
            let stamp = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
            return LocalSnapshot(name: name, stamp: stamp, date: formatter.date(from: stamp))
        }
    }

    /// True only if this process can actually open a file that macOS hides without Full Disk Access.
    /// The TCC database always exists, so "can't see it" means "denied", never "absent". (A previous version
    /// probed ~/Library/Safari and treated a denied `fileExists` as "not there, so fine", which reported
    /// access as granted when it wasn't.)
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(tcc, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        if errno == ENOENT {
            // Unusual system layout: fall back to a protected folder, and only count a real read as success.
            return (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Safari")) != nil
        }
        return false
    }
}
