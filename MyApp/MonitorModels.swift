import Foundation

struct CPUData: Equatable {
    let loadPercent: Double?
    let status: String
    let available: Bool
    let updatedAt: Date
}

struct MemoryData: Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let availableBytes: UInt64
    let usagePercent: Double
    let available: Bool
    let updatedAt: Date
}

struct DiskData: Equatable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let usedBytes: UInt64
    let usagePercent: Double
    let volumeName: String
    let available: Bool
    let updatedAt: Date
}

struct NetworkData: Equatable {
    let downloadRateBytesPerSecond: Double
    let uploadRateBytesPerSecond: Double
    let available: Bool
    let updatedAt: Date
}

struct BatteryData: Equatable {
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
    let updatedAt: Date
}

struct PowerHistorySample: Identifiable, Equatable {
    let date: Date
    let adapterReportedWatts: Double?
    let batteryPowerWatts: Double?

    var id: Date { date }
}

enum PowerHistoryBuffer {
    static let capacity = 500

    static func appending(_ sample: PowerHistorySample, to history: [PowerHistorySample]) -> [PowerHistorySample] {
        var updated = history
        updated.append(sample)
        if updated.count > capacity {
            updated.removeFirst(updated.count - capacity)
        }
        return updated
    }
}

struct SensorReading: Identifiable, Equatable {
    let id: String
    let name: String
    let group: String
    let valueCelsius: Double
    let updatedAt: Date
    let source: String
}

struct FanReading: Identifiable, Equatable {
    let index: Int
    let currentRPM: Double?
    let targetRPM: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let controllerMode: UInt8?
    let updatedAt: Date

    var id: Int { index }

    var controllerModeDescription: String {
        guard let controllerMode else { return "Controller mode unavailable" }
        return controllerMode == 0 || controllerMode == 3
            ? "System / Auto"
            : "SMC mode \(controllerMode)"
    }
}

enum SMCValueDecoder {
    nonisolated static func float32(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 4 else { return nil }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let value = Double(Float(bitPattern: bits))
        return value.isFinite ? value : nil
    }

    nonisolated static func temperatureCelsius(_ bytes: [UInt8]) -> Double? {
        guard let value = float32(bytes), (-10...125).contains(value) else { return nil }
        return value
    }

    nonisolated static func fanRPM(_ bytes: [UInt8]) -> Double? {
        guard let value = float32(bytes), (0...20_000).contains(value) else { return nil }
        return value
    }
}

struct TemperatureData: Equatable {
    let valueCelsius: Double?
    let available: Bool
    let message: String
    let updatedAt: Date
}

struct MetricHistorySample: Identifiable, Equatable {
    let date: Date
    let cpuUsage: Double?
    let memoryUsage: Double?
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?

    var id: Date { date }

    var overallLoadPercent: Double? {
        guard let cpuUsage, let memoryUsage else { return nil }
        return OverallLoadCalculator.calculate(cpuPercent: cpuUsage, memoryPercent: memoryUsage)?.percentage
    }
}

enum MetricHistoryBuffer {
    static let capacity = 240

    static func appending(_ sample: MetricHistorySample, to history: [MetricHistorySample]) -> [MetricHistorySample] {
        var updated = history
        updated.append(sample)
        if updated.count > capacity {
            updated.removeFirst(updated.count - capacity)
        }
        return updated
    }
}

struct ProcessUsage: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let startTime: UInt64
    let parentPID: Int32?
    let threadCount: Int?
    let userID: UInt32?
    let state: String?
    let executablePath: String?

    init(
        pid: Int32,
        name: String,
        cpuPercent: Double?,
        memoryBytes: UInt64?,
        startTime: UInt64,
        parentPID: Int32? = nil,
        threadCount: Int? = nil,
        userID: UInt32? = nil,
        state: String? = nil,
        executablePath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.startTime = startTime
        self.parentPID = parentPID
        self.threadCount = threadCount
        self.userID = userID
        self.state = state
        self.executablePath = executablePath
    }

    var id: String { "\(pid):\(startTime)" }

    var uptime: TimeInterval? {
        guard startTime > 0 else { return nil }
        return max(Date().timeIntervalSince1970 - Double(startTime) / 1_000_000, 0)
    }
}

struct ProcessSamplingDiagnostics: Equatable {
    let enumeratedPIDCount: Int
    let taskInfoReadCount: Int
    let metadataReadCount: Int
    let modelCount: Int
    let taskInfoFailureCount: Int
    let metadataFailureCount: Int
    let durationMilliseconds: Int
    let error: String?

    var summary: String {
        let result = "PID \(enumeratedPIDCount) → models \(modelCount); task info \(taskInfoReadCount), metadata \(metadataReadCount); failures \(taskInfoFailureCount)/\(metadataFailureCount); \(durationMilliseconds) ms"
        return error.map { "\(result); \($0)" } ?? result
    }
}

enum ProcessSamplingStatus: Equatable {
    case loading
    case loaded
    case failed(String)
}

enum MonitorSamplingIntervals {
    static let cpuAndMemory: TimeInterval = 0.5
    static let processes: TimeInterval = 1
    static let diskAndNetwork: TimeInterval = 1
    static let battery: TimeInterval = 2
    static let hardwareSensors: TimeInterval = 2
}

struct CoreUsage: Identifiable, Equatable {
    let index: Int
    let cpuPercent: Double?

    var id: Int { index }
}

struct CPUClusterInfo: Identifiable, Equatable {
    let name: String
    let logicalCPUCount: Int

    var id: String { name }
}

struct SystemSnapshot: Equatable {
    static let empty = SystemSnapshot(
        cpu: CPUData(loadPercent: nil, status: "Waiting for first sample", available: false, updatedAt: Date()),
        memory: MemoryData(totalBytes: 0, usedBytes: 0, availableBytes: 0, usagePercent: 0, available: false, updatedAt: Date()),
        disk: DiskData(totalBytes: 0, freeBytes: 0, usedBytes: 0, usagePercent: 0, volumeName: "Current Volume", available: false, updatedAt: Date()),
        network: NetworkData(downloadRateBytesPerSecond: 0, uploadRateBytesPerSecond: 0, available: false, updatedAt: Date()),
        battery: BatteryData(levelPercent: nil, source: "Unavailable", isCharging: nil, voltage: nil, current: nil, adapterWatts: nil, adapterCurrentAmps: nil, adapterVoltageEstimate: nil, batteryPowerWatts: nil, temperatureCelsius: nil, cycleCount: nil, healthPercent: nil, available: false, updatedAt: Date()),
        temperature: TemperatureData(valueCelsius: nil, available: false, message: "Unavailable on this model or macOS version", updatedAt: Date())
    )

    var cpu: CPUData
    var memory: MemoryData
    var disk: DiskData
    var network: NetworkData
    var battery: BatteryData
    var temperature: TemperatureData
    var timestamp: Date = Date()

    var overallLoad: OverallLoadIndex? {
        OverallLoadCalculator.calculate(
            cpuPercent: cpu.loadPercent,
            memoryPercent: memory.available ? memory.usagePercent : nil
        )
    }
}

enum MenuBarMetric: String, CaseIterable, Codable {
    case icon
    case cpu
    case ram
    case battery
    case power
    case overallLoad

    func powerTitle(adapterWatts: Double?) -> String {
        guard let adapterWatts, adapterWatts.isFinite, adapterWatts > 0 else { return "—" }
        return "\(Int(adapterWatts.rounded()))W"
    }
}

enum DisplayMetric: String, CaseIterable {
    case cpu
    case ram
    case disk
    case network
    case battery
    case temperature
    case history
}
