import Foundation
import Darwin
import AppKit
import Combine
import IOKit
import IOKit.ps
import os

final class SystemMonitor: ObservableObject, @unchecked Sendable {
    @MainActor static let shared = SystemMonitor()

    @Published var snapshot: SystemSnapshot = .empty
    @Published var temperatureAvailable: Bool = false
    @Published private(set) var history: [MetricHistorySample] = []
    @Published private(set) var processes: [ProcessUsage] = []
    @Published private(set) var processSamplingStatus: ProcessSamplingStatus = .loading
    @Published private(set) var processSamplingDiagnostics: ProcessSamplingDiagnostics?
    @Published private(set) var coreUsage: [CoreUsage] = []
    @Published private(set) var cpuClusters = CPUClusterReader.read()
    @Published private(set) var inaccessibleProcessCount = 0
    @Published private(set) var powerHistory: [PowerHistorySample] = []
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var hardwareTelemetryDiagnostics = "Waiting for first hardware sensor sample"

    private let queue = DispatchQueue(label: "com.macpulse.system-monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var previousCPU: CPUTickCounters?
    private var previousCoreCPU: [CPUTickCounters]?
    private var cpuReadingCache = CPUReadingCache()
    private var lastCPUSampleAt: Date?
    private var lastCPUDiagnosticAt: Date?
    private var cpuDiagnosticsRemaining = 2
    private var previousNetwork: NetworkCounterSnapshot?
    private var lastProcessSampleAt: Date?
    private let processReader = ProcessReader()
    private let processQueue = DispatchQueue(label: "com.macpulse.process-monitor", qos: .utility)
    private let processPollLock = NSLock()
    private var processPollInProgress = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacPulse", category: "Sampling")
    private var latestMemory = MemoryReading(totalBytes: 0, usedBytes: 0, availableBytes: 0, usagePercent: 0, available: false)
    private var latestDisk = DiskReading(totalBytes: 0, freeBytes: 0, usedBytes: 0, usagePercent: 0, volumeName: "Current volume", available: false)
    private var latestNetwork = NetworkReading(downloadRate: 0, uploadRate: 0, previousReading: nil, available: false)
    private var latestBattery = BatteryReading(levelPercent: nil, source: "Unavailable", isCharging: nil, voltage: nil, current: nil, adapterWatts: nil, adapterCurrentAmps: nil, adapterVoltageEstimate: nil, batteryPowerWatts: nil, temperatureCelsius: nil, cycleCount: nil, healthPercent: nil, available: false)
    private var latestTemperature = TemperatureReading(valueCelsius: nil, available: false, message: "Unavailable on this model or macOS version")
    private var latestHardwareTelemetry = HardwareTelemetryReading.unavailable("Waiting for first hardware sensor sample")
    private var lastMemorySampleAt: Date?
    private var lastDiskSampleAt: Date?
    private var lastNetworkSampleAt: Date?
    private var lastBatterySampleAt: Date?
    private var lastTemperatureSampleAt: Date?
    private var lastSamplingDiagnosticAt: Date?

    init() {
        refresh()
    }

    func start() {
        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalMilliseconds = Int(MonitorSamplingIntervals.cpuAndMemory * 1_000)
        timer?.schedule(
            deadline: .now() + .milliseconds(intervalMilliseconds),
            repeating: .milliseconds(intervalMilliseconds),
            leeway: .milliseconds(35)
        )
        timer?.setEventHandler { [weak self] in
            self?.sample()
        }
        timer?.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh() {
        queue.async { [weak self] in
            self?.sample()
        }
    }

    func retryProcessSampling() {
        DispatchQueue.main.async {
            self.processSamplingStatus = .loading
        }
        requestProcessSample()
    }

    private func sample() {
        let sampleStartedAt = Date()
        let cpuInterval = lastCPUSampleAt.map { sampleStartedAt.timeIntervalSince($0) } ?? 0
        lastCPUSampleAt = sampleStartedAt
        let shouldLogCPU = cpuDiagnosticsRemaining > 0
            || (lastCPUDiagnosticAt.map { sampleStartedAt.timeIntervalSince($0) >= 10 } ?? true)
        if shouldLogCPU {
            cpuDiagnosticsRemaining = max(cpuDiagnosticsRemaining - 1, 0)
            lastCPUDiagnosticAt = sampleStartedAt
        }
        let cpu = CPUReader.read(
            previous: previousCPU,
            previousCores: previousCoreCPU,
            logDiagnostics: shouldLogCPU
        )
        previousCPU = cpu.previousReading
        previousCoreCPU = cpu.previousCoreReadings
        let cpuData = cpuReadingCache.updating(value: cpu.value, status: cpu.status, at: sampleStartedAt)
        let shouldSampleMemory = lastMemorySampleAt.map {
            sampleStartedAt.timeIntervalSince($0) >= MonitorSamplingIntervals.cpuAndMemory
        } ?? true
        let shouldSampleProcess = lastProcessSampleAt.map {
            sampleStartedAt.timeIntervalSince($0) >= MonitorSamplingIntervals.processes
        } ?? true
        let shouldSampleDisk = lastDiskSampleAt.map {
            sampleStartedAt.timeIntervalSince($0) >= MonitorSamplingIntervals.diskAndNetwork
        } ?? true
        let shouldSampleNetwork = lastNetworkSampleAt.map {
            sampleStartedAt.timeIntervalSince($0) >= MonitorSamplingIntervals.diskAndNetwork
        } ?? true
        let shouldSampleBattery = lastBatterySampleAt.map {
            sampleStartedAt.timeIntervalSince($0) >= MonitorSamplingIntervals.battery
        } ?? true
        let shouldSampleTemperature = lastTemperatureSampleAt.map {
            sampleStartedAt.timeIntervalSince($0) >= MonitorSamplingIntervals.hardwareSensors
        } ?? true
        if shouldSampleMemory {
            latestMemory = MemoryReader.read()
            lastMemorySampleAt = sampleStartedAt
        }
        if shouldSampleNetwork {
            let network = NetworkReader.read(previous: previousNetwork, at: sampleStartedAt)
            previousNetwork = network.previousReading
            latestNetwork = network
            lastNetworkSampleAt = sampleStartedAt
        }
        if shouldSampleProcess {
            requestProcessSample()
            lastProcessSampleAt = sampleStartedAt
        }
        if shouldSampleDisk {
            latestDisk = DiskReader.read()
            lastDiskSampleAt = sampleStartedAt
        }
        if shouldSampleBattery {
            latestBattery = BatteryReader.read()
            lastBatterySampleAt = sampleStartedAt
            appendPowerHistoryIfNeeded(at: sampleStartedAt)
        }
        if shouldSampleTemperature {
            latestHardwareTelemetry = HardwareTelemetryReader.read(at: sampleStartedAt)
            latestTemperature = TemperatureReader.read(from: latestHardwareTelemetry.sensors)
            lastTemperatureSampleAt = sampleStartedAt
        }

        let now = Date()
        let state = SystemSnapshot(
            cpu: cpuData,
            memory: MemoryData(
                totalBytes: latestMemory.totalBytes,
                usedBytes: latestMemory.usedBytes,
                availableBytes: latestMemory.availableBytes,
                usagePercent: latestMemory.usagePercent,
                available: latestMemory.available,
                updatedAt: lastMemorySampleAt ?? now
            ),
            disk: DiskData(
                totalBytes: latestDisk.totalBytes,
                freeBytes: latestDisk.freeBytes,
                usedBytes: latestDisk.usedBytes,
                usagePercent: latestDisk.usagePercent,
                volumeName: latestDisk.volumeName,
                available: latestDisk.available,
                updatedAt: lastDiskSampleAt ?? now
            ),
            network: NetworkData(
                downloadRateBytesPerSecond: latestNetwork.downloadRate,
                uploadRateBytesPerSecond: latestNetwork.uploadRate,
                available: latestNetwork.available,
                updatedAt: lastNetworkSampleAt ?? now
            ),
            battery: BatteryData(
                levelPercent: latestBattery.levelPercent,
                source: latestBattery.source,
                isCharging: latestBattery.isCharging,
                voltage: latestBattery.voltage,
                current: latestBattery.current,
                adapterWatts: latestBattery.adapterWatts,
                adapterCurrentAmps: latestBattery.adapterCurrentAmps,
                adapterVoltageEstimate: latestBattery.adapterVoltageEstimate,
                batteryPowerWatts: latestBattery.batteryPowerWatts,
                temperatureCelsius: latestBattery.temperatureCelsius,
                cycleCount: latestBattery.cycleCount,
                healthPercent: latestBattery.healthPercent,
                available: latestBattery.available,
                updatedAt: lastBatterySampleAt ?? now
            ),
            temperature: TemperatureData(
                valueCelsius: latestTemperature.valueCelsius,
                available: latestTemperature.available,
                message: latestTemperature.message,
                updatedAt: lastTemperatureSampleAt ?? now
            ),
            timestamp: now
        )
        let networkHasFreshSample = shouldSampleNetwork
        let sample = MetricHistorySample(
            date: now,
            cpuUsage: state.cpu.loadPercent,
            memoryUsage: shouldSampleMemory && state.memory.available ? state.memory.usagePercent : nil,
            downloadBytesPerSecond: networkHasFreshSample && latestNetwork.available ? latestNetwork.downloadRate : nil,
            uploadBytesPerSecond: networkHasFreshSample && latestNetwork.available ? latestNetwork.uploadRate : nil
        )
        let coreUsage = cpu.coreUsage
        let hardwareTelemetry = latestHardwareTelemetry
        let sampleDuration = Date().timeIntervalSince(sampleStartedAt)
        if lastSamplingDiagnosticAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
            logger.info("sample interval target=500ms actual=\(cpuInterval, privacy: .public)s duration=\(sampleDuration, privacy: .public)s; serialized sampling queue prevents overlapping polls")
            lastSamplingDiagnosticAt = now
        }

        DispatchQueue.main.async {
            self.snapshot = state
            self.temperatureAvailable = state.temperature.available
            self.fans = hardwareTelemetry.fans
            self.hardwareTelemetryDiagnostics = hardwareTelemetry.diagnostics
            var collectedSensors = hardwareTelemetry.sensors
            if let batteryTemperature = state.battery.temperatureCelsius {
                collectedSensors.append(
                    SensorReading(
                        id: "apple-smart-battery-temperature",
                        name: "Battery",
                        group: "Battery",
                        valueCelsius: batteryTemperature,
                        updatedAt: state.battery.updatedAt,
                        source: "AppleSmartBattery IORegistry"
                    )
                )
            }
            self.sensors = collectedSensors
            self.coreUsage = coreUsage
            guard sample.cpuUsage != nil
                    || sample.memoryUsage != nil
                    || sample.downloadBytesPerSecond != nil
                    || sample.uploadBytesPerSecond != nil else { return }
            self.history = MetricHistoryBuffer.appending(sample, to: self.history)
        }
    }

    private func appendPowerHistoryIfNeeded(at date: Date) {
        let adapterWatts = latestBattery.adapterWatts.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let batteryWatts = latestBattery.batteryPowerWatts.flatMap { $0.isFinite ? $0 : nil }
        guard adapterWatts != nil || batteryWatts != nil else { return }
        let sample = PowerHistorySample(
            date: date,
            adapterReportedWatts: adapterWatts,
            batteryPowerWatts: batteryWatts
        )
        DispatchQueue.main.async {
            self.powerHistory = PowerHistoryBuffer.appending(sample, to: self.powerHistory)
        }
    }

    private func requestProcessSample() {
        processPollLock.lock()
        guard !processPollInProgress else {
            processPollLock.unlock()
            logger.debug("Process sample skipped: a process collection is already in progress")
            return
        }
        processPollInProgress = true
        processPollLock.unlock()

        processQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.processPollLock.lock()
                self.processPollInProgress = false
                self.processPollLock.unlock()
            }

            do {
                let snapshot = try self.processReader.read(at: Date())
                self.logger.info("Process sample completed: \(snapshot.diagnostics.summary, privacy: .public)")
                DispatchQueue.main.async {
                    self.processes = snapshot.processes
                    self.inaccessibleProcessCount = snapshot.inaccessibleProcessCount
                    self.processSamplingDiagnostics = snapshot.diagnostics
                    self.processSamplingStatus = .loaded
                }
            } catch {
                let message = error.localizedDescription
                self.logger.error("Process sampling failed: \(message, privacy: .public)")
                let diagnostics = ProcessSamplingDiagnostics(
                    enumeratedPIDCount: 0,
                    taskInfoReadCount: 0,
                    metadataReadCount: 0,
                    modelCount: 0,
                    taskInfoFailureCount: 0,
                    metadataFailureCount: 0,
                    durationMilliseconds: 0,
                    error: message
                )
                DispatchQueue.main.async {
                    self.processSamplingDiagnostics = diagnostics
                    self.processSamplingStatus = .failed(message)
                }
            }
        }
    }
}

struct CPUReading {
    let value: Double?
    let status: String
    let available: Bool
    let previousReading: CPUTickCounters?
    let coreUsage: [CoreUsage]
    let previousCoreReadings: [CPUTickCounters]?
}

struct MemoryReading {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let availableBytes: UInt64
    let usagePercent: Double
    let available: Bool
}

struct DiskReading {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let usedBytes: UInt64
    let usagePercent: Double
    let volumeName: String
    let available: Bool
}

struct NetworkReading {
    let downloadRate: Double
    let uploadRate: Double
    let previousReading: NetworkCounterSnapshot?
    let available: Bool
}

struct BatteryReading {
    let levelPercent: Double?
    let source: String
    let isCharging: Bool?
    let voltage: Double?
    let current: Double?
    let adapterWatts: Double?
    let adapterCurrentAmps: Double?
    let adapterVoltageEstimate: Double?
    let batteryPowerWatts: Double?
    let temperatureCelsius: Double?
    let cycleCount: Int?
    let healthPercent: Double?
    let available: Bool
}

struct TemperatureReading {
    let valueCelsius: Double?
    let available: Bool
    let message: String
}

struct ProcessSnapshot {
    let processes: [ProcessUsage]
    let inaccessibleProcessCount: Int
    let diagnostics: ProcessSamplingDiagnostics
}

private enum ProcessSamplingError: LocalizedError {
    case enumerationFailed(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .enumerationFailed(operation, code):
            let reason: String
            if code == 0 {
                reason = "macOS returned no process data."
            } else if code == EPERM || code == EACCES {
                reason = "macOS denied access: \(String(cString: strerror(code))). Check that MacPulse is not sandboxed."
            } else {
                reason = String(cString: strerror(code))
            }
            return "Could not \(operation): \(reason)"
        }
    }
}

private struct ProcessCounterBaseline {
    let startTime: UInt64
    let cpuTimeNanoseconds: UInt64
    let sampledAt: Date
}

final class ProcessReader {
    private var baselines: [Int32: ProcessCounterBaseline] = [:]

    func read(at timestamp: Date) throws -> ProcessSnapshot {
        let startedAt = Date()
        let requiredBytes = proc_listallpids(nil, 0)
        guard requiredBytes >= 0 else {
            throw ProcessSamplingError.enumerationFailed(
                operation: "query process list size",
                code: errno
            )
        }

        let capacity = max(Int(requiredBytes) / MemoryLayout<pid_t>.stride + 64, 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let returnedBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedBytes >= 0 else {
            throw ProcessSamplingError.enumerationFailed(
                operation: "read process list",
                code: errno
            )
        }

        let pidCount = min(Int(returnedBytes) / MemoryLayout<pid_t>.stride, pids.count)
        let currentPIDs = pids.prefix(pidCount).filter { $0 > 0 }
        var activeBaselines: [Int32: ProcessCounterBaseline] = [:]
        var readableProcesses: [ProcessUsage] = []
        var inaccessibleCount = 0
        var taskInfoReadCount = 0
        var metadataReadCount = 0
        var taskInfoFailureCount = 0
        var metadataFailureCount = 0

        for pid in currentPIDs {
            let taskInfo = readTaskInfo(pid: pid)
            if taskInfo == nil {
                taskInfoFailureCount += 1
                inaccessibleCount += 1
            } else {
                taskInfoReadCount += 1
            }

            let processName = readName(pid: pid)
            let bsdInfo = readBSDInfo(pid: pid)
            if bsdInfo == nil {
                metadataFailureCount += 1
            } else {
                metadataReadCount += 1
            }
            let name = bsdInfo.flatMap { cString($0.pbi_name, count: MemoryLayout.size(ofValue: $0.pbi_name)) }
                ?? processName
            let startTime = bsdInfo.map {
                $0.pbi_start_tvsec &* 1_000_000 &+ $0.pbi_start_tvusec
            } ?? 0
            let cpuTime = taskInfo.map { $0.pti_total_user &+ $0.pti_total_system }
            let memoryBytes = taskInfo.map { UInt64($0.pti_resident_size) }
            let executablePath = readExecutablePath(pid: pid)
            let previous = baselines[pid]
            let sameProcess = previous?.startTime == startTime
            let elapsedNanoseconds = previous.map {
                UInt64(max(timestamp.timeIntervalSince($0.sampledAt), 0) * 1_000_000_000)
            } ?? 0
            let cpuPercent: Double?
            if sameProcess, let cpuTime {
                cpuPercent = ProcessCPUCalculator.usagePercent(
                    previousCPUTimeNanoseconds: previous?.cpuTimeNanoseconds,
                    currentCPUTimeNanoseconds: cpuTime,
                    elapsedNanoseconds: elapsedNanoseconds
                )
            } else {
                cpuPercent = nil
            }

            if let cpuTime, (startTime > 0 || previous?.startTime == 0) {
                activeBaselines[pid] = ProcessCounterBaseline(
                    startTime: startTime,
                    cpuTimeNanoseconds: cpuTime,
                    sampledAt: timestamp
                )
            }
            readableProcesses.append(
                ProcessUsage(
                    pid: Int32(pid),
                    name: name.isEmpty ? "PID \(pid)" : name,
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    startTime: startTime,
                    parentPID: bsdInfo.map { Int32($0.pbi_ppid) },
                    threadCount: taskInfo.map { Int($0.pti_threadnum) },
                    userID: bsdInfo.map { UInt32($0.pbi_uid) },
                    state: bsdInfo.map { processStateName($0.pbi_status) },
                    executablePath: executablePath
                )
            )
        }

        baselines = activeBaselines
        let sorted = readableProcesses.sorted {
            switch ($0.cpuPercent, $1.cpuPercent) {
            case let (left?, right?):
                return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let diagnostics = ProcessSamplingDiagnostics(
            enumeratedPIDCount: currentPIDs.count,
            taskInfoReadCount: taskInfoReadCount,
            metadataReadCount: metadataReadCount,
            modelCount: sorted.count,
            taskInfoFailureCount: taskInfoFailureCount,
            metadataFailureCount: metadataFailureCount,
            durationMilliseconds: durationMilliseconds,
            error: nil
        )
        return ProcessSnapshot(
            processes: sorted,
            inaccessibleProcessCount: inaccessibleCount,
            diagnostics: diagnostics
        )
    }

    private func readTaskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let result = proc_pidinfo(
            pid,
            PROC_PIDTASKINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        guard result == MemoryLayout<proc_taskinfo>.size else {
            return nil
        }
        return info
    }

    private func readBSDInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard result == MemoryLayout<proc_bsdinfo>.size else {
            return nil
        }
        return info
    }

    private func readName(pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 2_048)
        let length = nameBuffer.withUnsafeMutableBufferPointer { buffer in
            proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return "" }
        return String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func readExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let bytesRead = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard bytesRead > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func processStateName(_ state: UInt32) -> String {
        switch state {
        case UInt32(SIDL): return "Starting"
        case UInt32(SRUN): return "Running"
        case UInt32(SSLEEP): return "Sleeping"
        case UInt32(SSTOP): return "Stopped"
        case UInt32(SZOMB): return "Zombie"
        default: return "State \(state)"
        }
    }

    private func cString<T>(_ tuple: T, count: Int) -> String? {
        withUnsafeBytes(of: tuple) { bytes in
            let terminated = bytes.prefix(count).prefix { $0 != 0 }
            guard !terminated.isEmpty else { return nil }
            return String(decoding: terminated, as: UTF8.self)
        }
    }
}

enum CPUClusterReader {
    static func read() -> [CPUClusterInfo] {
        [
            ("Performance", logicalCPUCount(for: "hw.perflevel0.logicalcpu")),
            ("Efficiency", logicalCPUCount(for: "hw.perflevel1.logicalcpu"))
        ].compactMap { name, count in
            count.map { CPUClusterInfo(name: name, logicalCPUCount: $0) }
        }
    }

    private static func logicalCPUCount(for name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = name.withCString { sysctlbyname($0, &value, &size, nil, 0) }
        guard result == 0, size == MemoryLayout<Int32>.size, value > 0 else { return nil }
        return Int(value)
    }
}

enum CPUReader {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MacPulse",
        category: "CPU"
    )

    static func read(
        previous: CPUTickCounters?,
        previousCores: [CPUTickCounters]?,
        logDiagnostics: Bool
    ) -> CPUReading {
        let cores = CoreCPUReader.read(previous: previousCores)
        var cpuInfo = host_cpu_load_info()
        let expectedCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var count = expectedCount

        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                return host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPointer, &count)
            }
        }

        guard result == KERN_SUCCESS, count == expectedCount else {
            logger.error("host_statistics(HOST_CPU_LOAD_INFO) result=\(result, privacy: .public), returnedCount=\(count, privacy: .public), expectedCount=\(expectedCount, privacy: .public)")
            return CPUReading(
                value: nil,
                status: "CPU unavailable",
                available: false,
                previousReading: previous,
                coreUsage: cores.usage,
                previousCoreReadings: cores.current
            )
        }

        guard let current = CPUTickCounters(machTicks: [
            cpuInfo.cpu_ticks.0,
            cpuInfo.cpu_ticks.1,
            cpuInfo.cpu_ticks.2,
            cpuInfo.cpu_ticks.3
        ]) else {
            logger.error("host_statistics returned an invalid CPU tick array")
            return CPUReading(
                value: nil,
                status: "CPU unavailable",
                available: false,
                previousReading: previous,
                coreUsage: cores.usage,
                previousCoreReadings: cores.current
            )
        }
        let calculation = CPUCalculator.calculate(previous: previous, current: current)
        let value = calculation?.percentage
        if let calculation {
            if logDiagnostics {
                logger.info("host_statistics result=\(result, privacy: .public), ticks user/system/nice/idle=\(current.user, privacy: .public)/\(current.system, privacy: .public)/\(current.nice, privacy: .public)/\(current.idle, privacy: .public), deltas user/system/nice/idle=\(calculation.userDelta, privacy: .public)/\(calculation.systemDelta, privacy: .public)/\(calculation.niceDelta, privacy: .public)/\(calculation.idleDelta, privacy: .public), totalDelta=\(calculation.totalDelta, privacy: .public), idleDelta=\(calculation.idleDelta, privacy: .public), usage=\(calculation.percentage, privacy: .public)%")
            }
        } else {
            let state = previous == nil ? "first sample" : "zero delta, counter reset, or invalid counter delta"
            let deltas = previous.map {
                "\(diagnosticDelta(previous: $0.user, current: current.user))/\(diagnosticDelta(previous: $0.system, current: current.system))/\(diagnosticDelta(previous: $0.nice, current: current.nice))/\(diagnosticDelta(previous: $0.idle, current: current.idle))"
            } ?? "n/a/n/a/n/a/n/a"
            if logDiagnostics {
                logger.info("host_statistics result=\(result, privacy: .public), ticks user/system/nice/idle=\(current.user, privacy: .public)/\(current.system, privacy: .public)/\(current.nice, privacy: .public)/\(current.idle, privacy: .public), deltas user/system/nice/idle=\(deltas, privacy: .public), usage=unavailable, state=\(state, privacy: .public)")
            }
        }
        let status = previous == nil ? "Waiting for second sample" : (value == nil ? "Waiting for next CPU sample" : "Live")
        return CPUReading(
            value: value,
            status: status,
            available: true,
            previousReading: current,
            coreUsage: cores.usage,
            previousCoreReadings: cores.current
        )
    }

    private static func diagnosticDelta(previous: UInt64, current: UInt64) -> String {
        guard current <= UInt64(UInt32.max), previous <= UInt64(UInt32.max) else {
            return "invalid"
        }
        if current >= previous {
            return String(current - previous)
        }
        return "reset(\(previous)->\(current))"
    }
}

private enum CoreCPUReader {
    private static let ticksPerProcessor =
        MemoryLayout<processor_cpu_load_info_data_t>.size / MemoryLayout<natural_t>.stride

    static func read(previous: [CPUTickCounters]?) -> (usage: [CoreUsage], current: [CPUTickCounters]?) {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else {
            return ([], nil)
        }
        defer {
            let byteCount = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: processorInfo), byteCount)
        }

        guard ticksPerProcessor > 0,
              processorInfoCount % mach_msg_type_number_t(ticksPerProcessor) == 0 else {
            return ([], nil)
        }

        let count = Int(processorInfoCount) / ticksPerProcessor
        guard count == Int(processorCount), count > 0 else {
            return ([], nil)
        }

        var current: [CPUTickCounters] = []
        current.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * ticksPerProcessor
            guard let counters = CPUTickCounters(machTicks: (0..<ticksPerProcessor).map {
                UInt32(bitPattern: processorInfo[offset + $0])
            }) else {
                return ([], nil)
            }
            current.append(counters)
        }

        let usage = current.enumerated().map { index, counters in
            CoreUsage(
                index: index,
                cpuPercent: previous.flatMap { oldCounters in
                    guard oldCounters.count == current.count else { return nil }
                    return CPUCalculator.usagePercent(previous: oldCounters[index], current: counters)
                }
            )
        }
        return (usage, current)
    }
}

enum MemoryReader {
    static func read() -> MemoryReading {
        let totalBytes = UInt64(ProcessInfo.processInfo.physicalMemory)
        var vmInfo = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        if status != KERN_SUCCESS {
            return MemoryReading(totalBytes: 0, usedBytes: 0, availableBytes: 0, usagePercent: 0, available: false)
        }

        guard let usage = MemoryCalculator.calculate(
            totalBytes: totalBytes,
            pageSize: UInt64(getpagesize()),
            activePages: UInt64(vmInfo.active_count),
            inactivePages: UInt64(vmInfo.inactive_count),
            wiredPages: UInt64(vmInfo.wire_count),
            freePages: UInt64(vmInfo.free_count),
            compressedPages: UInt64(vmInfo.compressor_page_count),
            purgeablePages: UInt64(vmInfo.purgeable_count),
            speculativePages: UInt64(vmInfo.speculative_count)
        ) else {
            return MemoryReading(totalBytes: totalBytes, usedBytes: 0, availableBytes: 0, usagePercent: 0, available: false)
        }

        return MemoryReading(
            totalBytes: totalBytes,
            usedBytes: usage.usedBytes,
            availableBytes: usage.availableBytes,
            usagePercent: usage.usagePercent,
            available: totalBytes > 0
        )
    }
}

enum DiskReader {
    static func read() -> DiskReading {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity else {
            return DiskReading(totalBytes: 0, freeBytes: 0, usedBytes: 0, usagePercent: 0, volumeName: "Current volume", available: false)
        }

        let totalBytes = UInt64(total)
        let freeBytes = UInt64(free)
        let usedBytes = max(totalBytes - freeBytes, 0)
        let usagePercent = totalBytes == 0 ? 0 : (Double(usedBytes) / Double(totalBytes)) * 100.0

        return DiskReading(
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            usedBytes: usedBytes,
            usagePercent: min(max(usagePercent, 0), 100),
            volumeName: url.lastPathComponent.isEmpty ? "Current volume" : url.lastPathComponent,
            available: totalBytes > 0
        )
    }
}

enum NetworkReader {
    static func read(previous: NetworkCounterSnapshot?, at timestamp: Date) -> NetworkReading {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let list = addrs else {
            return NetworkReading(downloadRate: 0, uploadRate: 0, previousReading: nil, available: false)
        }
        defer { freeifaddrs(list) }

        var candidates: [String: (incoming: UInt64, outgoing: UInt64)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let current = cursor {
            let name = String(cString: current.pointee.ifa_name)
            let interface = current.pointee
            // Use unique link-layer records for physical Ethernet/Wi-Fi interfaces, not virtual bridges or tunnels.
            let isPhysicalEthernetOrWiFi = name.hasPrefix("en")
            let isRunning = interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
            let isLinkLayerRecord = interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK)

            if isPhysicalEthernetOrWiFi, isRunning, isLinkLayerRecord,
               let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                candidates[name] = (
                    incoming: UInt64(data.pointee.ifi_ibytes),
                    outgoing: UInt64(data.pointee.ifi_obytes)
                )
            }
            cursor = interface.ifa_next
        }

        let interfaceNames = candidates.keys.sorted()
        guard !interfaceNames.isEmpty else {
            return NetworkReading(downloadRate: 0, uploadRate: 0, previousReading: nil, available: false)
        }

        var incomingBytes: UInt64 = 0
        var outgoingBytes: UInt64 = 0
        for name in interfaceNames {
            guard let counters = candidates[name] else { continue }
            let (incomingTotal, incomingOverflow) = incomingBytes.addingReportingOverflow(counters.incoming)
            let (outgoingTotal, outgoingOverflow) = outgoingBytes.addingReportingOverflow(counters.outgoing)
            guard !incomingOverflow, !outgoingOverflow else {
                return NetworkReading(downloadRate: 0, uploadRate: 0, previousReading: nil, available: false)
            }
            incomingBytes = incomingTotal
            outgoingBytes = outgoingTotal
        }

        let current = NetworkCounterSnapshot(
            interface: interfaceNames.joined(separator: ","),
            incomingBytes: incomingBytes,
            outgoingBytes: outgoingBytes,
            sampledAt: timestamp
        )
        guard let previous, let rates = NetworkRateCalculator.rates(previous: previous, current: current) else {
            return NetworkReading(downloadRate: 0, uploadRate: 0, previousReading: current, available: false)
        }

        return NetworkReading(
            downloadRate: rates.incomingBytesPerSecond,
            uploadRate: rates.outgoingBytesPerSecond,
            previousReading: current,
            available: true
        )
    }
}

enum BatteryReader {
    static func read() -> BatteryReading {
        guard let powerSourcesInfo = IOPSCopyPowerSourcesInfo() else {
            return unavailableReading
        }
        let powerSources = powerSourcesInfo.takeRetainedValue()

        let sourceType = IOPSGetProvidingPowerSourceType(powerSources)?
            .takeUnretainedValue() as String? ?? "Unavailable"
        let sources = IOPSCopyPowerSourcesList(powerSources)?
            .takeRetainedValue() as? [CFTypeRef] ?? []
        var batteryLevel: Double?
        var isCharging: Bool?

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(powerSources, source)?
                    .takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = (info[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (info[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  maximum > 0 else {
                continue
            }

            let level = current / maximum * 100
            if level.isFinite, (0...100).contains(level) {
                batteryLevel = level
            }
            isCharging = info[kIOPSIsChargingKey] as? Bool
            break
        }

        let adapterInfo = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any]
        let adapterWatts = (adapterInfo?[kIOPSPowerAdapterWattsKey] as? NSNumber)?.doubleValue
        let validAdapterWatts = adapterWatts.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let adapterCurrent = (adapterInfo?[kIOPSPowerAdapterCurrentKey] as? NSNumber)?.doubleValue
        let validAdapterCurrent = adapterCurrent.flatMap { $0.isFinite && $0 > 0 ? $0 / 1_000 : nil }
        let adapterVoltageEstimate: Double?
        if let validAdapterWatts, let validAdapterCurrent {
            let estimate = validAdapterWatts / validAdapterCurrent
            adapterVoltageEstimate = estimate.isFinite && estimate > 0 ? estimate : nil
        } else {
            adapterVoltageEstimate = nil
        }

        let batteryProperties = readBatteryProperties()
        let batteryVoltage = batteryProperties["Voltage"].map { $0 / 1_000 }
        let batteryCurrentMilliamps = batteryProperties["Amperage"]
        let batteryPowerWatts: Double?
        if let batteryVoltage, let batteryCurrentMilliamps {
            batteryPowerWatts = BatteryPowerCalculator.signedWatts(
                voltage: batteryVoltage,
                currentMilliamps: batteryCurrentMilliamps
            )
        } else {
            batteryPowerWatts = nil
        }
        let batteryHealth = BatteryPowerCalculator.healthPercent(
            maximumCapacity: batteryProperties["AppleRawMaxCapacity"],
            designCapacity: batteryProperties["DesignCapacity"]
        )
        let temperature = batteryProperties["Temperature"].map { $0 / 100 }
            .flatMap { $0.isFinite && (-40...100).contains($0) ? $0 : nil }
        let cycleCount: Int? = batteryProperties["CycleCount"].flatMap {
            guard $0.isFinite, $0 >= 0, $0 < Double(Int.max) else { return nil }
            return Int($0)
        }

        return BatteryReading(
            levelPercent: batteryLevel,
            source: sourceType,
            isCharging: isCharging,
            voltage: batteryVoltage,
            current: batteryCurrentMilliamps.map { $0 / 1_000 },
            adapterWatts: validAdapterWatts,
            adapterCurrentAmps: validAdapterCurrent,
            adapterVoltageEstimate: adapterVoltageEstimate,
            batteryPowerWatts: batteryPowerWatts,
            temperatureCelsius: temperature,
            cycleCount: cycleCount,
            healthPercent: batteryHealth,
            available: batteryLevel != nil || sourceType != "Unavailable"
        )
    }

    private static var unavailableReading: BatteryReading {
        BatteryReading(
            levelPercent: nil,
            source: "Unavailable",
            isCharging: nil,
            voltage: nil,
            current: nil,
            adapterWatts: nil,
            adapterCurrentAmps: nil,
            adapterVoltageEstimate: nil,
            batteryPowerWatts: nil,
            temperatureCelsius: nil,
            cycleCount: nil,
            healthPercent: nil,
            available: false
        )
    }

    private static func readBatteryProperties() -> [String: Double] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return dictionary.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}

enum TemperatureReader {
    static func read(from sensors: [SensorReading]) -> TemperatureReading {
        let cpuReadings = sensors.filter { $0.group == "CPU" }
        guard !cpuReadings.isEmpty else {
            return TemperatureReading(
                valueCelsius: nil,
                available: false,
                message: "No mapped AppleSMC CPU core temperature keys are readable"
            )
        }

        return TemperatureReading(
            valueCelsius: cpuReadings.map(\.valueCelsius).reduce(0, +) / Double(cpuReadings.count),
            available: true,
            message: "Live average from \(cpuReadings.count) AppleSMC CPU core sensors"
        )
    }
}

struct HardwareTelemetryReading {
    let sensors: [SensorReading]
    let fans: [FanReading]
    let diagnostics: String

    static func unavailable(_ reason: String) -> HardwareTelemetryReading {
        HardwareTelemetryReading(sensors: [], fans: [], diagnostics: reason)
    }
}

enum HardwareTelemetryReader {
    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PowerLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }

    private struct KeyInfo {
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt8 = 0
    }

    private struct Parameters {
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes = (
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        )
    }

    private struct SensorKey {
        let key: String
        let name: String
        let group: String
    }

    private static let sensorKeys = [
        SensorKey(key: "Te05", name: "CPU efficiency core 1", group: "CPU"),
        SensorKey(key: "Te0S", name: "CPU efficiency core 2", group: "CPU"),
        SensorKey(key: "Te09", name: "CPU efficiency core 3", group: "CPU"),
        SensorKey(key: "Te0H", name: "CPU efficiency core 4", group: "CPU"),
        SensorKey(key: "Tp01", name: "CPU performance core 1", group: "CPU"),
        SensorKey(key: "Tp05", name: "CPU performance core 2", group: "CPU"),
        SensorKey(key: "Tp09", name: "CPU performance core 3", group: "CPU"),
        SensorKey(key: "Tp0D", name: "CPU performance core 4", group: "CPU"),
        SensorKey(key: "Tp0V", name: "CPU performance core 5", group: "CPU"),
        SensorKey(key: "Tp0Y", name: "CPU performance core 6", group: "CPU"),
        SensorKey(key: "Tp0b", name: "CPU performance core 7", group: "CPU"),
        SensorKey(key: "Tp0e", name: "CPU performance core 8", group: "CPU"),
        SensorKey(key: "Tg0K", name: "GPU sensor 1", group: "GPU"),
        SensorKey(key: "Tg0L", name: "GPU sensor 2", group: "GPU"),
        SensorKey(key: "Tg0d", name: "GPU sensor 3", group: "GPU"),
        SensorKey(key: "Tg0e", name: "GPU sensor 4", group: "GPU"),
        SensorKey(key: "Tg0j", name: "GPU sensor 5", group: "GPU"),
        SensorKey(key: "Tg0k", name: "GPU sensor 6", group: "GPU")
    ]

    static func read(at date: Date) -> HardwareTelemetryReading {
        guard MemoryLayout<Parameters>.stride == 80 else {
            return .unavailable("Unexpected AppleSMC structure layout; hardware readings were not queried")
        }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMCKeysEndpoint")
        )
        guard service != 0 else {
            return .unavailable("AppleSMCKeysEndpoint is not available")
        }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openResult == KERN_SUCCESS else {
            return .unavailable("Could not open AppleSMCKeysEndpoint (IOReturn \(openResult))")
        }
        defer { IOServiceClose(connection) }

        var sensors: [SensorReading] = []
        var unavailableKeys: [String] = []
        for sensorKey in sensorKeys {
            guard let bytes = readKey(sensorKey.key, connection: connection),
                  let temperature = SMCValueDecoder.temperatureCelsius(bytes) else {
                unavailableKeys.append(sensorKey.key)
                continue
            }
            sensors.append(
                SensorReading(
                    id: "smc-\(sensorKey.key)",
                    name: sensorKey.name,
                    group: sensorKey.group,
                    valueCelsius: temperature,
                    updatedAt: date,
                    source: "AppleSMCKeysEndpoint · \(sensorKey.key)"
                )
            )
        }

        var diagnostics = "AppleSMCKeysEndpoint: \(sensors.count)/\(sensorKeys.count) mapped CPU/GPU sensors readable"
        if !unavailableKeys.isEmpty {
            diagnostics += "; unavailable/invalid keys: \(unavailableKeys.joined(separator: ", "))"
        }
        let fans = readFans(connection: connection, at: date, diagnostic: &diagnostics)
        return HardwareTelemetryReading(sensors: sensors, fans: fans, diagnostics: diagnostics)
    }

    private static func readFans(
        connection: io_connect_t,
        at date: Date,
        diagnostic: inout String
    ) -> [FanReading] {
        guard let fanCountBytes = readKey("FNum", connection: connection),
              let fanCount = fanCountBytes.first else {
            diagnostic += "; fan count unavailable"
            return []
        }
        guard fanCount <= 16 else {
            diagnostic += "; rejected implausible fan count \(fanCount)"
            return []
        }

        var fans: [FanReading] = []
        for index in 0..<Int(fanCount) {
            let prefix = "F\(index)"
            let current = readKey(prefix + "Ac", connection: connection).flatMap(SMCValueDecoder.fanRPM)
            let minimum = readKey(prefix + "Mn", connection: connection).flatMap(SMCValueDecoder.fanRPM)
            let maximum = readKey(prefix + "Mx", connection: connection).flatMap(SMCValueDecoder.fanRPM)
            let mode = readKey(prefix + "Md", connection: connection)?.first
            fans.append(
                FanReading(
                    index: index,
                    currentRPM: current,
                    targetRPM: readKey(prefix + "Tg", connection: connection).flatMap(SMCValueDecoder.fanRPM),
                    minimumRPM: minimum,
                    maximumRPM: maximum,
                    controllerMode: mode,
                    updatedAt: date
                )
            )
        }
        diagnostic += "; \(fans.count) fan(s) reported"
        return fans
    }

    private static func readKey(_ name: String, connection: io_connect_t) -> [UInt8]? {
        var infoRequest = Parameters()
        infoRequest.key = fourCharacterCode(name)
        infoRequest.command = 9
        guard let info = call(infoRequest, connection: connection),
              info.result == 0,
              info.keyInfo.size > 0,
              info.keyInfo.size <= 32 else {
            return nil
        }

        var valueRequest = Parameters()
        valueRequest.key = infoRequest.key
        valueRequest.keyInfo.size = info.keyInfo.size
        valueRequest.command = 5
        guard let value = call(valueRequest, connection: connection), value.result == 0 else {
            return nil
        }
        return withUnsafeBytes(of: value.bytes) {
            Array($0.prefix(Int(info.keyInfo.size)))
        }
    }

    private static func call(_ input: Parameters, connection: io_connect_t) -> Parameters? {
        var input = input
        var output = Parameters()
        var outputSize = MemoryLayout<Parameters>.stride
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<Parameters>.stride,
            &output,
            &outputSize
        )
        return result == KERN_SUCCESS ? output : nil
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
