import Foundation
import IOKit
import IOKit.ps

/// One reading of the internal battery: IOKit power sources for the level and state, the `AppleSmartBattery`
/// registry entry for current, voltage and capacities, and the user's charge limit.
public struct BatteryStatus: Sendable, Equatable {
    public var percent: Double
    public var isCharging: Bool
    public var isOnAC: Bool
    /// macOS's estimate: time to empty on battery, time to full while charging. `nil` while macOS is calculating.
    public var systemEstimateMinutes: Int?
    /// mA, positive while charging.
    public var amperage: Double?
    /// mV.
    public var voltage: Double?
    /// mAh.
    public var fullChargeCapacity: Double?
    public var designCapacity: Double?
    public var cycleCount: Double?
    /// The limit set in System Settings › Battery, when below 100%.
    public var chargeLimit: Int?
    /// Health as System Settings › Battery shows it ("Maximum Capacity"), percent.
    public var maximumCapacity: Double?
    /// Cycles the battery is designed for (1,000 on Apple silicon laptops).
    public var designCycleCount: Double?
    /// macOS reports a battery condition other than normal ("Service Recommended").
    public var serviceRecommended = false

    public init(
        percent: Double, isCharging: Bool, isOnAC: Bool, systemEstimateMinutes: Int? = nil,
        amperage: Double? = nil, voltage: Double? = nil, fullChargeCapacity: Double? = nil,
        designCapacity: Double? = nil, cycleCount: Double? = nil, chargeLimit: Int? = nil
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnAC = isOnAC
        self.systemEstimateMinutes = systemEstimateMinutes
        self.amperage = amperage
        self.voltage = voltage
        self.fullChargeCapacity = fullChargeCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
        self.chargeLimit = chargeLimit
    }

    /// Minutes until charging stops: at the charge limit when one is set, computed from the charging current
    /// (macOS's own estimate counts to 100%); otherwise macOS's time to full.
    /// Nil when the readings can't give a time: not finite, a negative capacity, or a result no `Int` holds.
    public var minutesUntilCharged: Int? {
        guard isCharging else { return nil }
        guard let limit = chargeLimit else { return systemEstimateMinutes }
        guard let amperage, amperage > 0, amperage.isFinite, let fullChargeCapacity, fullChargeCapacity >= 0,
              fullChargeCapacity.isFinite, percent.isFinite else { return nil }
        let minutes = (max(Double(limit) - percent, 0) / 100 * fullChargeCapacity / amperage * 60).rounded(.up)
        return Int(exactly: minutes)
    }

    /// Energy the battery holds when full, in joules (mAh × V × 3.6).
    public var capacityJoules: Double? {
        guard let fullChargeCapacity, let voltage else { return nil }
        return fullChargeCapacity * voltage / 1000 * 3.6
    }

    func readings(at date: Date) -> [Reading] {
        var all = [
            Reading(.batteryPercent, percent, at: date),
            Reading(.onAC, isOnAC ? 1 : 0, at: date),
            Reading(.charging, isCharging ? 1 : 0, at: date),
            Reading(.chargeLimit, Double(chargeLimit ?? 100), at: date),
        ]
        let optional: [(Metric, Double?)] = [
            (.amperage, amperage), (.voltage, voltage), (.fullChargeCapacity, fullChargeCapacity),
            (.designCapacity, designCapacity), (.cycleCount, cycleCount), (.maximumCapacity, maximumCapacity),
        ]
        for (metric, value) in optional {
            if let value {
                all.append(Reading(metric, value, at: date))
            }
        }
        return all
    }

    // MARK: Reading the system

    /// `nil` on a Mac without a battery.
    public static func current() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let description = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let description else { return nil }
        return BatteryStatus(powerSource: description, registry: smartBattery(), chargeLimit: ChargeLimit.current())
    }

    /// The connected power adapter's rating in watts, when macOS knows it (F6 names it).
    public static func adapterWatts() -> Int? {
        let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return details?[kIOPSPowerAdapterWattsKey] as? Int
    }

    /// Parses the dictionaries IOKit returns. Separate from `current()` so tests can feed recorded ones.
    init?(powerSource d: [String: Any], registry r: [String: Any], chargeLimit: Int?) {
        guard let current = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        // -1 while macOS is still calculating.
        let minutes = d[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        // Capacities in mAh sit in `BatteryData` on Apple silicon, at the top level on older Macs.
        let data = r["BatteryData"] as? [String: Any] ?? [:]
        func number(_ keys: String...) -> Double? {
            for key in keys {
                if let value = (data[key] ?? r[key]) as? NSNumber {
                    return value.doubleValue
                }
            }
            return nil
        }
        self.init(
            percent: Double(current) * 100 / Double(max),
            isCharging: charging,
            isOnAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            systemEstimateMinutes: minutes.flatMap { $0 > 0 ? $0 : nil },
            amperage: (r["InstantAmperage"] ?? r["Amperage"]).flatMap { ($0 as? NSNumber)?.int64Value }
                .map(Double.init),
            voltage: number("Voltage"),
            fullChargeCapacity: number("FullChargeCapacity", "AppleRawMaxCapacity"),
            designCapacity: number("DesignCapacity"),
            cycleCount: number("CycleCount"),
            chargeLimit: chargeLimit
        )
        // System Settings shows nominal over design capacity, capped at 100%; the condition key appears only when
        // the battery is not normal.
        if let nominal = number("NominalChargeCapacity"), let design = designCapacity, design > 0 {
            maximumCapacity = min(nominal / design * 100, 100)
        }
        designCycleCount = number("DesignCycleCount9C") ?? (d["DesignCycleCount"] as? NSNumber)?.doubleValue
        serviceRecommended = d[kIOPSBatteryHealthConditionKey] != nil
    }

    private static func smartBattery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return [:]
        }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }
}

/// The charge limit set in System Settings › Battery (macOS 26.4+). macOS keeps it in powerd's preferences as an
/// archived `ChargeCtrlPolicy` with reason `manualChargeLimit`. Not a public API: any surprise reads as no limit.
public enum ChargeLimit {
    static let url = URL(filePath: "/Library/Preferences/com.apple.powerd.charging.plist")

    public static func current() -> Int? {
        guard let plist = NSDictionary(contentsOf: url), let policies = plist["policies"] as? Data else { return nil }
        return parse(policies)
    }

    /// The active manual limit in an archived policy list, `nil` when there is none or it is 100%.
    static func parse(_ archive: Data) -> Int? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(Policy.self, forClassName: "ChargeCtrlPolicy")
        defer { unarchiver.finishDecoding() }
        let policies = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [Policy] ?? []
        return policies
            .filter { $0.reason == "manualChargeLimit" && !$0.terminated && (1 ..< 100).contains($0.limit) }
            .map(\.limit)
            .min()
    }

    /// Stand-in for powerd's class: decodes only the fields read here.
    @objc(ForewarnChargeCtrlPolicy)
    private final class Policy: NSObject, NSCoding {
        let reason: String?
        let limit: Int
        let terminated: Bool

        init?(coder: NSCoder) {
            reason = coder.decodeObject(forKey: "reason") as? String
            limit = coder.decodeInteger(forKey: "soclimit")
            terminated = coder.decodeBool(forKey: "terminated")
        }

        func encode(with _: NSCoder) {}
    }
}
