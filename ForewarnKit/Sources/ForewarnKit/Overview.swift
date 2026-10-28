import Foundation

/// Everything the popover shows. A nil member is a feature that is unavailable (no battery, no data limit)
/// or has nothing to say yet.
public struct Overview: Sendable, Equatable {
    public var battery: Battery?
    public var disk: Disk?
    public var meteredData: MeteredData?
    public var sleepDrain: SleepDrain?
    public var health: BatteryHealth?
    /// Share of a full battery Forewarn itself used today, in percent.
    public var ownEnergyTodayPercent: Double?

    public init(
        battery: Battery? = nil,
        disk: Disk? = nil,
        meteredData: MeteredData? = nil,
        sleepDrain: SleepDrain? = nil,
        health: BatteryHealth? = nil,
        ownEnergyTodayPercent: Double? = nil
    ) {
        self.battery = battery
        self.disk = disk
        self.meteredData = meteredData
        self.sleepDrain = sleepDrain
        self.health = health
        self.ownEnergyTodayPercent = ownEnergyTodayPercent
    }

    /// F5: the battery's condition, in System Settings' terms.
    public struct BatteryHealth: Sendable, Equatable {
        /// "Maximum Capacity" in System Settings › Battery, percent.
        public var maximumCapacity: Double
        public var cycleCount: Int
        public var designCycleCount: Int?
        public var serviceRecommended: Bool
        /// When the trend reaches 80%, the usual service threshold; nil while learning or when not declining.
        public var reaches80At: Date?
        /// Expected Maximum Capacity in a year (`HealthOutlook`).
        public var inOneYear: Double?

        public init(
            maximumCapacity: Double, cycleCount: Int, designCycleCount: Int? = nil,
            serviceRecommended: Bool = false, reaches80At: Date? = nil, inOneYear: Double? = nil
        ) {
            self.maximumCapacity = maximumCapacity
            self.cycleCount = cycleCount
            self.designCycleCount = designCycleCount
            self.serviceRecommended = serviceRecommended
            self.reaches80At = reaches80At
            self.inOneYear = inOneYear
        }

        /// Worth a look: macOS recommends service, capacity is under 80%, or the trend gets there within six months.
        public var needsAttention: Bool {
            serviceRecommended || maximumCapacity < 80
                || reaches80At.map { $0.timeIntervalSinceNow < 182 * 86400 } ?? false
        }
    }

    /// Battery level below which F1 warns.
    public static let lowBatteryPercent = 10.0

    /// True when something will run out before the user usually deals with it: the menu bar icon's attention state.
    public var needsAttention: Bool {
        battery?.runsLowBeforePlugIn == true || battery?.shortfall != nil || disk?.fillsSoon == true
            || meteredData?.runsOutBeforeReset == true
    }
}

public extension Overview {
    struct Sample: Sendable, Equatable {
        public var date: Date
        public var value: Double

        public init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    struct Battery: Sendable, Equatable {
        public var percent: Double
        public var isCharging: Bool
        public var isOnAC: Bool
        /// Observed levels, oldest first.
        public var history: [Sample]
        public var forecast: Forecast?
        /// When the user usually plugs in next.
        public var usualPlugIn: Date?
        /// Minutes to empty on battery (macOS's estimate); while charging, minutes until charging stops.
        public var systemEstimateMinutes: Int?
        /// The limit set in System Settings › Battery, when below 100%.
        public var chargeLimit: Int?
        /// On power, yet draining: the charger gives less than the Mac uses (F6).
        public var shortfall: ChargerShortfall?
        /// When these readings were taken: times shown from them ("full at", "empty around") count from here, not from
        /// whenever a view happens to draw them.
        public var measuredAt: Date

        public init(
            percent: Double, isCharging: Bool, isOnAC: Bool,
            history: [Sample] = [], forecast: Forecast? = nil, usualPlugIn: Date? = nil,
            systemEstimateMinutes: Int? = nil, chargeLimit: Int? = nil, shortfall: ChargerShortfall? = nil,
            measuredAt: Date = .now
        ) {
            self.percent = percent
            self.isCharging = isCharging
            self.isOnAC = isOnAC
            self.history = history
            self.forecast = forecast
            self.usualPlugIn = usualPlugIn
            self.systemEstimateMinutes = systemEstimateMinutes
            self.chargeLimit = chargeLimit
            self.shortfall = shortfall
            self.measuredAt = measuredAt
        }

        /// When macOS's estimate runs out: empty on battery, charged while charging.
        public var systemEstimateEnds: Date? {
            systemEstimateMinutes.map { measuredAt.addingTimeInterval(Double($0) * 60) }
        }

        /// On power, not charging, at the user's charge limit: macOS stopped on purpose.
        public var isHeldAtLimit: Bool {
            guard isOnAC, !isCharging, let chargeLimit else { return false }
            return percent >= Double(chargeLimit) - 2
        }

        /// When the median forecast first drops below the low-battery level.
        public var runsLowAt: Date? {
            forecast?.firstDate(medianBelow: Overview.lowBatteryPercent)
        }

        public var runsLowBeforePlugIn: Bool {
            guard !isOnAC, let runsLowAt else { return false }
            return usualPlugIn.map { runsLowAt < $0 } ?? true
        }
    }

    /// F6: the Mac is plugged in, yet the battery drains, because the charger gives less than the Mac uses.
    /// Shown in the menu bar and the popover only, no notification.
    struct ChargerShortfall: Sendable, Equatable {
        /// The adapter's rating, when macOS reports it.
        public var adapterWatts: Int?
        /// Battery lost per hour while plugged in, percent.
        public var percentPerHour: Double

        public init(adapterWatts: Int?, percentPerHour: Double) {
            self.adapterWatts = adapterWatts
            self.percentPerHour = percentPerHour
        }

        /// A discharge under this many mA is noise, not a charger falling short.
        public static let minimumDrain = 50.0
        /// The 10-minute cadence on power, less the scheduler's tolerance either side.
        public static let minimumGap = 8 * 60.0

        /// The last two battery readings, taken on power about 10 minutes apart, both discharging, the latest within
        /// 25 minutes of `now`. Not while the level sits above the charge limit: macOS may be bringing it
        /// down on purpose. Readings are the store's, oldest first; `status` gives the level, limit and full charge.
        /// About 10 minutes is at least `minimumGap`: readings taken around a wake or a relaunch, seconds apart, are
        /// not evidence of anything sustained.
        public static func detect(
            amperage: [Reading], onAC: [Reading], status: BatteryStatus, adapterWatts: Int?, now: Date
        ) -> ChargerShortfall? {
            guard let capacity = status.fullChargeCapacity, capacity > 0,
                  status.percent <= Double(status.chargeLimit ?? 100) + 1 else { return nil }
            let lastTwo = amperage.suffix(2)
            guard lastTwo.count == 2, let first = lastTwo.first, let last = lastTwo.last,
                  (0 ... 25 * 60).contains(now.timeIntervalSince(last.date)),
                  (minimumGap ... 25 * 60).contains(last.date.timeIntervalSince(first.date)) else { return nil }
            let plugged = Set(onAC.filter { $0.value == 1 }.map(\.date))
            guard lastTwo.allSatisfy({ $0.value <= -minimumDrain && plugged.contains($0.date) }) else { return nil }
            let drain = -lastTwo.map(\.value).reduce(0, +) / 2
            return ChargerShortfall(adapterWatts: adapterWatts, percentPerHour: drain / capacity * 100)
        }
    }

    /// A battery forecast on a regular grid starting at `start`.
    struct Forecast: Sendable, Equatable {
        public var start: Date
        public var step: TimeInterval
        public var quantiles: QuantileForecast

        public init(start: Date, step: TimeInterval, quantiles: QuantileForecast) {
            self.start = start
            self.step = step
            self.quantiles = quantiles
        }

        public struct Point: Sendable, Equatable, Identifiable {
            public var date: Date
            public var low: Double
            public var median: Double
            public var high: Double
            public var id: Date { date }
        }

        /// p10, median and p90 at each step: the band and line the chart draws.
        public var points: [Point] {
            let low = quantiles.quantile(0.1) ?? [], high = quantiles.quantile(0.9) ?? []
            return quantiles.median.indices.map { i in
                Point(date: start + Double(i) * step, low: low[i], median: quantiles.median[i], high: high[i])
            }
        }

        public func firstDate(medianBelow threshold: Double) -> Date? {
            quantiles.median.firstIndex { $0 < threshold }.map { start + Double($0) * step }
        }
    }

    /// The Battery Health page. Built when it opens, not on every refresh.
    struct HealthDetail: Sendable, Equatable {
        public var health: BatteryHealth
        /// Nil until three days of battery use exist.
        public var outlook: HealthOutlook?
        /// Measured Maximum Capacity, one value a day, oldest first.
        public var history: [Sample]
        /// The limit set in System Settings › Battery, when below 100%.
        public var chargeLimit: Int?

        public init(health: BatteryHealth, outlook: HealthOutlook?, history: [Sample], chargeLimit: Int?) {
            self.health = health
            self.outlook = outlook
            self.history = history
            self.chargeLimit = chargeLimit
        }
    }

    /// The disk page: free space over the last 30 days and the folders Forewarn scans weekly. Built when it opens.
    struct DiskDetail: Sendable, Equatable {
        public var disk: Disk
        /// Free bytes, the last value of each day, oldest first.
        public var history: [Sample]
        public var folders: [Folder]

        public init(disk: Disk, history: [Sample], folders: [Folder]) {
            self.disk = disk
            self.history = history
            self.folders = folders
        }

        public struct Folder: Sendable, Equatable, Identifiable {
            public var path: String
            public var bytes: Int64
            /// Since the scan a week before; nil after the first scan.
            public var growth: Int64?
            public var id: String { path }

            public init(path: String, bytes: Int64, growth: Int64?) {
                self.path = path
                self.bytes = bytes
                self.growth = growth
            }
        }
    }

    struct Disk: Sendable, Equatable {
        public var freeBytes: Int64
        public var totalBytes: Int64
        /// Median "disk full" date, nil while learning.
        public var fullDate: Date?

        public init(freeBytes: Int64, totalBytes: Int64, fullDate: Date? = nil) {
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
            self.fullDate = fullDate
        }

        public var usedFraction: Double {
            totalBytes > 0 ? 1 - Double(freeBytes) / Double(totalBytes) : 0
        }

        /// F2: full within 21 days or less than 10% free.
        public var fillsSoon: Bool {
            let soon = fullDate.map { $0.timeIntervalSinceNow < 21 * 86400 } ?? false
            return soon || usedFraction > 0.9
        }
    }

    struct MeteredData: Sendable, Equatable {
        public var usedBytes: Int64
        public var limitBytes: Int64
        public var resetDate: Date
        /// When the median forecast reaches the limit, nil if it does not before the reset.
        public var runsOutAt: Date?

        public init(usedBytes: Int64, limitBytes: Int64, resetDate: Date, runsOutAt: Date? = nil) {
            self.usedBytes = usedBytes
            self.limitBytes = limitBytes
            self.resetDate = resetDate
            self.runsOutAt = runsOutAt
        }

        public var usedFraction: Double {
            limitBytes > 0 ? min(Double(usedBytes) / Double(limitBytes), 1) : 0
        }

        /// Also when the allowance is already used up, with or without a forecast.
        public var runsOutBeforeReset: Bool {
            (limitBytes > 0 && usedBytes >= limitBytes) || runsOutAt.map { $0 < resetDate } ?? false
        }
    }

    struct SleepDrain: Sendable, Equatable {
        public var lastSleepDropPercent: Double
        public var usualDropPercent: Double
        /// What kept the Mac awake, from power assertions.
        public var cause: String?

        public init(lastSleepDropPercent: Double, usualDropPercent: Double, cause: String? = nil) {
            self.lastSleepDropPercent = lastSleepDropPercent
            self.usualDropPercent = usualDropPercent
            self.cause = cause
        }

        /// F3: more than 3× the usual drop (the per-hour rule needs sleep length).
        public var isAbnormal: Bool {
            lastSleepDropPercent > 3 * usualDropPercent
        }
    }
}
