import Foundation

struct CPUTickCounters: Equatable {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64

    init?(machTicks: [UInt32]) {
        guard machTicks.count == 4 else { return nil }
        user = UInt64(machTicks[0])
        system = UInt64(machTicks[1])
        idle = UInt64(machTicks[2])
        nice = UInt64(machTicks[3])
    }

    init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }
}

struct CPUUsageCalculation: Equatable {
    let userDelta: UInt64
    let systemDelta: UInt64
    let niceDelta: UInt64
    let idleDelta: UInt64
    let totalDelta: UInt64
    let percentage: Double
}

enum NumericValueAnimation {
    static func interpolatedValue(from start: Double, to end: Double, progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        let easedProgress = clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
        return start + (end - start) * easedProgress
    }

    static func displayedInteger(_ value: Double) -> Int {
        Int(value.rounded())
    }
}

struct CPUReadingCache {
    static let maximumAge: TimeInterval = 5

    private(set) var lastValue: Double?
    private(set) var lastSuccessfulSampleAt: Date?

    mutating func updating(value: Double?, status: String, at date: Date) -> CPUData {
        if let value, value.isFinite, (0...100).contains(value) {
            lastValue = value
            lastSuccessfulSampleAt = date
        }

        let isCurrentSample = value.map { $0.isFinite && (0...100).contains($0) } ?? false

        if let lastValue,
           let lastSuccessfulSampleAt,
           (0...Self.maximumAge).contains(date.timeIntervalSince(lastSuccessfulSampleAt)) {
            return CPUData(
                loadPercent: lastValue,
                status: isCurrentSample ? status : "Using last valid CPU reading",
                available: true,
                updatedAt: lastSuccessfulSampleAt
            )
        }

        return CPUData(loadPercent: nil, status: status, available: false, updatedAt: date)
    }
}

struct NetworkCounterSnapshot: Equatable {
    let interface: String
    let incomingBytes: UInt64
    let outgoingBytes: UInt64
    let sampledAt: Date
}

struct NetworkRates: Equatable {
    let incomingBytesPerSecond: Double
    let outgoingBytesPerSecond: Double
}

struct MemoryUsage: Equatable {
    let usedBytes: UInt64
    let availableBytes: UInt64
    let usagePercent: Double
}

enum ProcessSortColumn: String, CaseIterable, Equatable {
    case name
    case cpu
    case memory
    case pid
}

enum ProcessSortDirection: Equatable {
    case ascending
    case descending

    var reversed: ProcessSortDirection {
        self == .ascending ? .descending : .ascending
    }
}

struct ProcessSortState: Equatable {
    var column: ProcessSortColumn = .cpu
    var direction: ProcessSortDirection = .descending

    mutating func select(_ newColumn: ProcessSortColumn) {
        if column == newColumn {
            direction = direction.reversed
        } else {
            column = newColumn
            direction = newColumn == .name ? .ascending : .descending
        }
    }
}

enum ProcessListFilter: Equatable {
    case all
    case myApplications
}

enum ProcessListCalculator {
    static func filteredAndSorted(
        _ processes: [ProcessUsage],
        searchText: String,
        filter: ProcessListFilter,
        applicationPIDs: Set<Int32>,
        sort: ProcessSortState
    ) -> [ProcessUsage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = processes.filter { process in
            let matchesName = query.isEmpty || process.name.localizedCaseInsensitiveContains(query)
            let matchesFilter = filter == .all || applicationPIDs.contains(process.pid)
            return matchesName && matchesFilter
        }

        return filtered.sorted { left, right in
            let comparison: ComparisonResult
            switch sort.column {
            case .name:
                comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            case .cpu:
                comparison = compareOptional(left.cpuPercent, right.cpuPercent)
            case .memory:
                comparison = compareOptional(left.memoryBytes, right.memoryBytes)
            case .pid:
                comparison = left.pid == right.pid
                    ? .orderedSame
                    : (left.pid < right.pid ? .orderedAscending : .orderedDescending)
            }

            if comparison == .orderedSame {
                let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)
                return nameComparison == .orderedSame
                    ? left.pid < right.pid
                    : nameComparison == .orderedAscending
            }
            return sort.direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private static func compareOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedAscending
        case (_?, nil):
            return .orderedDescending
        }
    }
}

struct OverallLoadIndex: Equatable {
    let percentage: Double
    let cpuPercent: Double?
    let memoryPercent: Double?
    let isPartial: Bool
}

enum OverallLoadCalculator {
    static func calculate(cpuPercent: Double?, memoryPercent: Double?) -> OverallLoadIndex? {
        let cpu = validPercentage(cpuPercent)
        let memory = validPercentage(memoryPercent)
        guard cpu != nil || memory != nil else { return nil }

        let cpuWeight = 0.5
        let memoryWeight = 0.5
        let availableWeight = (cpu == nil ? 0 : cpuWeight) + (memory == nil ? 0 : memoryWeight)
        let weightedLoad = (cpu ?? 0) * cpuWeight + (memory ?? 0) * memoryWeight
        let percentage = weightedLoad / availableWeight
        guard percentage.isFinite else { return nil }

        return OverallLoadIndex(
            percentage: min(max(percentage, 0), 100),
            cpuPercent: cpu,
            memoryPercent: memory,
            isPartial: cpu == nil || memory == nil
        )
    }

    private static func validPercentage(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

enum BatteryPowerCalculator {
    static func signedWatts(voltage: Double, currentMilliamps: Double) -> Double? {
        guard voltage.isFinite, voltage > 0, currentMilliamps.isFinite else { return nil }
        let watts = voltage * currentMilliamps / 1_000
        guard watts.isFinite else { return nil }
        return watts
    }

    static func healthPercent(maximumCapacity: Double?, designCapacity: Double?) -> Double? {
        guard let maximumCapacity, let designCapacity,
              maximumCapacity.isFinite, designCapacity.isFinite,
              maximumCapacity > 0, designCapacity > 0 else {
            return nil
        }
        let percent = maximumCapacity / designCapacity * 100
        guard percent.isFinite else { return nil }
        return min(max(percent, 0), 100)
    }
}

enum CPUCalculator {
    private static let tickCounterMaximum = UInt64(UInt32.max)
    private static let rolloverWindow = UInt64(4_096)

    static func usagePercent(previous: CPUTickCounters?, current: CPUTickCounters) -> Double? {
        calculate(previous: previous, current: current)?.percentage
    }

    static func calculate(previous: CPUTickCounters?, current: CPUTickCounters) -> CPUUsageCalculation? {
        guard let previous,
              let userDelta = counterDelta(previous: previous.user, current: current.user),
              let systemDelta = counterDelta(previous: previous.system, current: current.system),
              let niceDelta = counterDelta(previous: previous.nice, current: current.nice),
              let idleDelta = counterDelta(previous: previous.idle, current: current.idle) else {
            return nil
        }

        let (activeDelta, activeOverflow) = userDelta.addingReportingOverflow(systemDelta)
        let (activeTotal, niceOverflow) = activeDelta.addingReportingOverflow(niceDelta)
        let (totalDelta, totalOverflow) = activeTotal.addingReportingOverflow(idleDelta)
        guard !activeOverflow, !niceOverflow, !totalOverflow, totalDelta > 0 else {
            return nil
        }

        let percentage = Double(totalDelta - idleDelta) / Double(totalDelta) * 100
        guard percentage.isFinite else { return nil }
        return CPUUsageCalculation(
            userDelta: userDelta,
            systemDelta: systemDelta,
            niceDelta: niceDelta,
            idleDelta: idleDelta,
            totalDelta: totalDelta,
            percentage: min(max(percentage, 0), 100)
        )
    }

    private static func counterDelta(previous: UInt64, current: UInt64) -> UInt64? {
        guard current <= tickCounterMaximum, previous <= tickCounterMaximum else { return nil }
        if current >= previous {
            return current - previous
        }

        guard previous >= tickCounterMaximum - rolloverWindow,
              current <= rolloverWindow else {
            return nil
        }
        return tickCounterMaximum - previous + current + 1
    }
}

enum ProcessCPUCalculator {
    static func usagePercent(previousCPUTimeNanoseconds: UInt64?, currentCPUTimeNanoseconds: UInt64, elapsedNanoseconds: UInt64) -> Double? {
        guard let previousCPUTimeNanoseconds,
              currentCPUTimeNanoseconds >= previousCPUTimeNanoseconds,
              elapsedNanoseconds > 0 else {
            return nil
        }

        let delta = currentCPUTimeNanoseconds - previousCPUTimeNanoseconds
        let percentage = Double(delta) / Double(elapsedNanoseconds) * 100
        guard percentage.isFinite else { return nil }
        return percentage
    }
}

enum NetworkRateCalculator {
    static func rates(previous: NetworkCounterSnapshot?, current: NetworkCounterSnapshot) -> NetworkRates? {
        guard let previous else { return nil }
        guard previous.interface == current.interface,
              current.incomingBytes >= previous.incomingBytes,
              current.outgoingBytes >= previous.outgoingBytes else {
            return nil
        }

        let elapsed = current.sampledAt.timeIntervalSince(previous.sampledAt)
        guard elapsed.isFinite, elapsed > 0 else { return nil }

        let incomingRate = Double(current.incomingBytes - previous.incomingBytes) / elapsed
        let outgoingRate = Double(current.outgoingBytes - previous.outgoingBytes) / elapsed
        guard incomingRate.isFinite, outgoingRate.isFinite else { return nil }

        return NetworkRates(
            incomingBytesPerSecond: incomingRate,
            outgoingBytesPerSecond: outgoingRate
        )
    }
}

enum MemoryCalculator {
    static func calculate(
        totalBytes: UInt64,
        pageSize: UInt64,
        activePages: UInt64,
        inactivePages: UInt64,
        wiredPages: UInt64,
        freePages: UInt64,
        compressedPages: UInt64,
        purgeablePages: UInt64,
        speculativePages: UInt64
    ) -> MemoryUsage? {
        guard totalBytes > 0, pageSize > 0, speculativePages <= freePages else { return nil }

        func bytes(for pages: UInt64) -> UInt64? {
            let (value, overflow) = pages.multipliedReportingOverflow(by: pageSize)
            return overflow ? nil : value
        }

        guard let activeBytes = bytes(for: activePages),
              let inactiveBytes = bytes(for: inactivePages),
              let wiredBytes = bytes(for: wiredPages),
              let freeBytes = bytes(for: freePages),
              let compressedBytes = bytes(for: compressedPages),
              let purgeableBytes = bytes(for: purgeablePages),
              activeBytes <= totalBytes,
              inactiveBytes <= totalBytes,
              wiredBytes <= totalBytes,
              freeBytes <= totalBytes,
              compressedBytes <= totalBytes,
              purgeableBytes <= totalBytes else {
            return nil
        }

        let (residentUsage, residentOverflow) = activeBytes.addingReportingOverflow(wiredBytes)
        let (residentAndCompressed, compressedOverflow) = residentUsage.addingReportingOverflow(compressedBytes)
        guard !residentOverflow, !compressedOverflow, residentAndCompressed <= totalBytes else {
            return nil
        }

        // Speculative pages are already included in free_count; purgeable pages can overlap inactive pages.
        let reclaimableBytes = freeBytes.addingReportingOverflow(max(inactiveBytes, purgeableBytes))
        guard !reclaimableBytes.overflow else { return nil }
        let availableBytes = min(reclaimableBytes.partialValue, totalBytes)
        let nonReclaimableBytes = totalBytes - availableBytes
        let usedBytes = max(residentAndCompressed, nonReclaimableBytes)
        let usagePercent = Double(usedBytes) / Double(totalBytes) * 100
        guard usagePercent.isFinite else { return nil }

        return MemoryUsage(
            usedBytes: usedBytes,
            availableBytes: totalBytes - usedBytes,
            usagePercent: min(max(usagePercent, 0), 100)
        )
    }

    static func usagePercent(totalBytes: UInt64, usedBytes: UInt64) -> Double? {
        guard totalBytes > 0, usedBytes <= totalBytes else { return nil }
        let percent = Double(usedBytes) / Double(totalBytes) * 100
        return percent.isFinite ? percent : nil
    }
}

enum DiskFormatter {
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return String(format: "%.0f %@", value, units[index])
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

enum ByteFormatter {
    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return String(format: "%.0f %@", value, units[index])
        }
        return String(format: "%.1f %@", value, units[index])
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "—" }
        let totalSeconds = Int(interval)
        let days = totalSeconds / 86_400
        let hours = totalSeconds % 86_400 / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
