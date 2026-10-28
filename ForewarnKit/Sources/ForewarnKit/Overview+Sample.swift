import Foundation

public extension Overview {
    enum SampleState: String, Sendable, CaseIterable {
        /// On battery; reaches 10% before the usual plug-in time.
        case risky
        /// On battery; lasts past the usual plug-in time.
        case fine
        /// Plugged in and charging; no forecast while on power.
        case charging
        /// Plugged in, held at the user's 80% charge limit.
        case plugged
        /// On battery with no history yet: macOS's estimate only.
        case learning
        /// Plugged in to a 30 W charger that gives less than the Mac uses: draining 8%/h (F6).
        case shortfall
    }

    /// Plausible data for previews, screenshots and UI tests (`-FWSample risky|fine|charging`). Never shown otherwise.
    static func sample(now: Date = .now, state: SampleState = .risky) -> Overview {
        let risky = state == .risky
        let hour = 3600.0
        let start = now.addingTimeInterval(-5 * hour)
        // Unplugged five hours ago at 100%, draining about 7%/h.
        let history = stride(from: 0.0, through: 5 * hour, by: 15 * 60).map { t in
            Sample(date: start + t, value: 100 - 7 * t / hour + 1.5 * sin(t / 1800))
        }
        if state == .learning || state == .plugged {
            var overview = sample(now: now, state: .fine)
            overview.battery = state == .learning
                ? Battery(percent: 64, isCharging: false, isOnAC: false, systemEstimateMinutes: 205)
                : Battery(percent: 80, isCharging: false, isOnAC: true, chargeLimit: 80)
            overview.health = sampleHealth(now: now, state: state).health
            return overview
        }
        if state == .shortfall {
            var overview = sample(now: now, state: .fine)
            let plugged = now.addingTimeInterval(-2 * hour)
            let draining = stride(from: 0.0, through: 2 * hour, by: 10 * 60).map {
                Sample(date: plugged + $0, value: 74 - 8 * $0 / hour)
            }
            overview.battery = Battery(
                percent: draining.last!.value, isCharging: false, isOnAC: true, history: draining,
                shortfall: ChargerShortfall(adapterWatts: 30, percentPerHour: 8)
            )
            return overview
        }
        if state == .charging {
            let plugged = now.addingTimeInterval(-hour)
            let charging = stride(from: 15 * 60.0, through: hour, by: 15 * 60).map {
                Sample(date: plugged + $0, value: history.last!.value + 30 * $0 / hour)
            }
            var overview = sample(now: plugged, state: .fine)
            overview.battery = Battery(
                percent: charging.last!.value, isCharging: true, isOnAC: true,
                history: sample(now: plugged, state: .fine).battery!.history + charging, systemEstimateMinutes: 70
            )
            return overview
        }
        let level = history.last!.value
        let drain = risky ? 9.0 : 5.5 // %/h ahead
        let steps = 12 * 12 // 12 h at 5 min
        let rows = QuantileForecast.levels.map { q in
            (0 ..< steps).map { i in
                let h = Double(i) / 12
                let spread = (q - 0.5) * 2.4 * h * 2.2 // widens with the horizon
                return min(max(level - drain * h + spread * 2, 0), 100)
            }
        }
        return Overview(
            battery: Battery(
                percent: level, isCharging: false, isOnAC: false, history: history,
                forecast: Forecast(start: now, step: 300, quantiles: QuantileForecast(values: rows)),
                usualPlugIn: now.addingTimeInterval(risky ? 6.5 * hour : 4 * hour),
                systemEstimateMinutes: risky ? 400 : 640
            ),
            disk: Disk(
                freeBytes: 184_000_000_000,
                totalBytes: 994_000_000_000,
                fullDate: now.addingTimeInterval(140 * 86400)
            ),
            meteredData: MeteredData(
                usedBytes: 12_400_000_000, limitBytes: 20_000_000_000,
                resetDate: now.addingTimeInterval(9 * 86400)
            ),
            sleepDrain: SleepDrain(lastSleepDropPercent: 2, usualDropPercent: 2),
            health: sampleHealth(now: now, state: state).health,
            ownEnergyTodayPercent: 0.004
        )
    }

    /// The disk page: 30 days losing about 1.3 GB a day, three scanned folders (learning: no scans yet).
    static func sampleDisk(now: Date = .now, state: SampleState = .risky) -> DiskDetail {
        let disk = sample(now: now, state: .fine).disk!
        let history = (0 ... 30).map { (d: Int) -> Sample in
            let daysAgo = Double(30 - d)
            let free = Double(disk.freeBytes) + daysAgo * 1.3e9 + 2e9 * sin(Double(d) / 3)
            return Sample(date: now - daysAgo * 86400, value: free)
        }
        let home = URL.homeDirectory.path
        return DiskDetail(
            disk: disk, history: history,
            folders: state == .learning ? [] : [
                .init(
                    path: home + "/Library/Developer/Xcode/DerivedData",
                    bytes: 38_400_000_000,
                    growth: 4_200_000_000
                ),
                .init(path: home + "/Downloads", bytes: 21_700_000_000, growth: 900_000_000),
                .init(path: home + "/Library/Caches", bytes: 12_100_000_000, growth: nil),
            ]
        )
    }

    /// The Battery Health page for each sample state: four months of measurements (risky, charging, plugged with
    /// its 80% limit), cycles only (fine), or too little use for an outlook (learning).
    static func sampleHealth(now: Date = .now, state: SampleState = .risky) -> HealthDetail {
        let day = 86400.0
        let measuredDays = state == .fine ? 0 : state == .learning ? 2 : 120
        let history = (0 ... measuredDays).map { d in
            let t = Double(d - measuredDays) * day
            return Sample(date: now + t, value: 98 - 0.009 * t / day + 0.15 * sin(Double(d) / 9))
        }
        let outlook = state == .learning ? nil : HealthOutlook(
            basis: state == .fine ? .cycles : .measured(days: measuredDays), start: now, maximumCapacity: 98,
            lossPerDay: 0.009, lossRange: 0.006 ... 0.013, cyclesPerDay: 0.45
        )
        return HealthDetail(
            health: BatteryHealth(
                maximumCapacity: 98, cycleCount: 62, designCycleCount: 1000,
                reaches80At: outlook?.reaches80At, inOneYear: outlook?.inOneYear
            ),
            outlook: outlook,
            history: state == .fine ? [] : history,
            chargeLimit: state == .plugged ? 80 : nil
        )
    }
}
