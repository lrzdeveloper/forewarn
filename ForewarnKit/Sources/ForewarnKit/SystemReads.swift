import Darwin
import Foundation
import IOKit.pwr_mgt

// One-shot reads of the system, each a plain function so `Recorder` can take fakes in tests.

public enum DiskSpace {
    /// Free space as Finder counts it (important usage) and total size of the startup volume.
    public static func current() -> (free: Double, total: Double)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(filePath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (Double(free), Double(total))
    }

    /// Allocated size and newest access date of everything under `folder` (disk suggestions).
    public static func usage(of folder: URL) -> (bytes: Double, lastOpened: Date?)? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentAccessDateKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: folder.path),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        else {
            return nil
        }
        var bytes = 0.0
        var newest: Date?
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            bytes += Double(values.totalFileAllocatedSize ?? 0)
            if let opened = values.contentAccessDate, opened > newest ?? .distantPast {
                newest = opened
            }
        }
        return (bytes, newest)
    }
}

public enum NetworkCounters {
    /// Bytes in + out per interface since boot, from the 64-bit counters (`NET_RT_IFLIST2`, `if_data64`).
    /// `getifaddrs` would give 32-bit counters that wrap at 4 GB.
    public static func current() -> [String: UInt64] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }
        var totals: [String: UInt64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        if let interface = String(bytes: bytes, encoding: .utf8) {
                            totals[interface] = message.ifm_data.ifi_ibytes &+ message.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return totals
    }

    /// Bytes moved between two readings of one interface. Counters restart from zero when the interface comes back
    /// (hotspot reconnect, reboot): then everything counted since is new.
    static func delta(from old: UInt64, to new: UInt64) -> UInt64 {
        new >= old ? new - old : new
    }
}

public enum SelfEnergy {
    /// Joules this process has used since it started (`rusage_info_v6.ri_energy_nj`).
    public static func current() -> Double? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? Double(usage.ri_energy_nj) / 1e9 : nil
    }
}

public enum SleepBlockers {
    /// Processes holding an assertion that keeps the Mac (not just the display) awake, by name.
    public static func current() -> [String] {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let keepsAwake: Set = ["PreventSystemSleep", "PreventUserIdleSystemSleep", "NoIdleSleepAssertion"]
        let names = byProcess.values.joined()
            .filter { keepsAwake.contains($0["AssertType"] as? String ?? "") }
            .compactMap { $0["Process Name"] as? String }
        return Array(Set(names)).sorted()
    }
}

/// History macOS already keeps: `pmset -g log` holds about a week of battery level and power source.
/// Imported once on first launch so forecasts start from real history.
public enum PmsetLog {
    public static func current() -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(bytes: data, encoding: .utf8) : nil
    }

    /// Battery level and power source, one value per 5-minute bin (the last one in each), oldest first.
    /// Lines look like `2026-10-20 18:13:31 +0200 Assertions … Using AC(Charge: 80)` or `… Using BATT (Charge:68%)`.
    static func parse(_ log: String) -> [Reading] {
        let pattern = /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}) .*Using (AC|Batt|BATT) ?\(Charge: ?(\d+)%?\)/
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var bins: [Int: (percent: Reading, onAC: Reading)] = [:]
        for line in log.split(separator: "\n") {
            guard let match = try? pattern.firstMatch(in: String(line)),
                  let date = format.date(from: String(match.1)),
                  let percent = Double(match.3) else { continue }
            bins[Int(date.timeIntervalSince1970 / 300)] =
                (Reading(.batteryPercent, percent, at: date), Reading(.onAC, match.2 == "AC" ? 1 : 0, at: date))
        }
        return bins.keys.sorted().flatMap { [bins[$0]!.percent, bins[$0]!.onAC] }
    }
}
