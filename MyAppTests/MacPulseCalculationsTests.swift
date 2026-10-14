import XCTest
import Combine
@testable import MacPulse

final class MacPulseCalculationsTests: XCTestCase {
    func testMonitorSamplingIntervalsMatchResponsiveTargets() {
        XCTAssertEqual(MonitorSamplingIntervals.cpuAndMemory, 0.5)
        XCTAssertEqual(MonitorSamplingIntervals.processes, 1)
        XCTAssertEqual(MonitorSamplingIntervals.diskAndNetwork, 1)
        XCTAssertEqual(MonitorSamplingIntervals.battery, 2)
        XCTAssertEqual(MonitorSamplingIntervals.hardwareSensors, 2)
    }

    func testSMCValueDecoderReadsFiniteLittleEndianTemperaturesAndFanSpeeds() {
        XCTAssertEqual(SMCValueDecoder.temperatureCelsius([0xEC, 0x51, 0x62, 0x42]) ?? 0, 56.58, accuracy: 0.01)
        XCTAssertEqual(SMCValueDecoder.fanRPM([0x31, 0x78, 0x1C, 0x45]) ?? 0, 2503.51, accuracy: 0.1)
        XCTAssertNil(SMCValueDecoder.temperatureCelsius([0x00, 0x00, 0x00]))
        XCTAssertNil(SMCValueDecoder.temperatureCelsius([0x00, 0x00, 0xC0, 0xC6]))
        XCTAssertNil(SMCValueDecoder.fanRPM([0x00, 0x00, 0xC0, 0x7F]))
        XCTAssertNil(SMCValueDecoder.fanRPM([0x00, 0x00, 0xA0, 0x46]))
    }

    func testFanControlOnlyAcceptsFiniteTargetsWithinControllerReportedRange() {
        XCTAssertTrue(FanControlValidation.isTargetWithinReportedRange(3_000, minimum: 2_317, maximum: 6_550))
        XCTAssertTrue(FanControlValidation.isTargetWithinReportedRange(2_317, minimum: 2_317, maximum: 6_550))
        XCTAssertTrue(FanControlValidation.isTargetWithinReportedRange(6_550, minimum: 2_317, maximum: 6_550))
        XCTAssertFalse(FanControlValidation.isTargetWithinReportedRange(2_316, minimum: 2_317, maximum: 6_550))
        XCTAssertFalse(FanControlValidation.isTargetWithinReportedRange(6_551, minimum: 2_317, maximum: 6_550))
        XCTAssertFalse(FanControlValidation.isTargetWithinReportedRange(.nan, minimum: 2_317, maximum: 6_550))
        XCTAssertFalse(FanControlValidation.isTargetWithinReportedRange(3_000, minimum: nil, maximum: 6_550))
        XCTAssertFalse(FanControlValidation.isTargetWithinReportedRange(3_000, minimum: 6_550, maximum: 2_317))
    }

    func testFanControlRequiresActualAndTargetRPMReadbackForSuccess() {
        let readable = FanControlReading(
            index: 0, currentRPM: 2_500, targetRPM: 2_500,
            minimumRPM: 2_317, maximumRPM: 6_550, mode: 0
        )
        let missingTarget = FanControlReading(
            index: 0, currentRPM: 2_500, targetRPM: nil,
            minimumRPM: 2_317, maximumRPM: 6_550, mode: 0
        )
        XCTAssertTrue(FanControlValidation.hasReadableRPMTelemetry([readable]))
        XCTAssertFalse(FanControlValidation.hasReadableRPMTelemetry([missingTarget]))
        XCTAssertFalse(FanControlValidation.hasReadableRPMTelemetry([]))
    }

    func testAutoBoostThresholdsRequireHysteresisAndFreshRealCPUGPUReadings() {
        XCTAssertTrue(FanAutoBoostPolicy.hasValidThresholds(trigger: 80, release: 70))
        XCTAssertFalse(FanAutoBoostPolicy.hasValidThresholds(trigger: 80, release: 76))
        XCTAssertFalse(FanAutoBoostPolicy.hasValidThresholds(trigger: 101, release: 70))

        let now = Date()
        let sensors = [
            SensorReading(
                id: "cpu", name: "CPU", group: "CPU", valueCelsius: 81,
                updatedAt: now.addingTimeInterval(-2), source: "AppleSMCKeysEndpoint"
            ),
            SensorReading(
                id: "battery", name: "Battery", group: "Battery", valueCelsius: 99,
                updatedAt: now, source: "AppleSmartBattery"
            ),
            SensorReading(
                id: "stale-gpu", name: "GPU", group: "GPU", valueCelsius: 90,
                updatedAt: now.addingTimeInterval(-10), source: "AppleSMCKeysEndpoint"
            )
        ]
        XCTAssertEqual(
            FanAutoBoostPolicy.hottestFreshTemperature(in: sensors, now: now),
            81
        )
        XCTAssertNil(
            FanAutoBoostPolicy.hottestFreshTemperature(
                in: sensors.filter { $0.group == "Battery" },
                now: now
            )
        )
    }

    func testAutoBoostTargetUsesReportedLimitsAndNeverExceedsThem() {
        XCTAssertEqual(
            FanAutoBoostPolicy.boostTarget(currentRPM: 2_500, minimum: 2_317, maximum: 6_550),
            3_000
        )
        XCTAssertEqual(
            FanAutoBoostPolicy.boostTarget(currentRPM: 6_400, minimum: 2_317, maximum: 6_550),
            6_550
        )
        XCTAssertNil(FanAutoBoostPolicy.boostTarget(currentRPM: nil, minimum: 2_317, maximum: 6_550))
        XCTAssertNil(FanAutoBoostPolicy.boostTarget(currentRPM: 2_500, minimum: 0, maximum: 6_550))
    }

    func testAppleSiliconSMCProvidesLiveCPUGPUTemperaturesAndFanRPM() throws {
        var model = [CChar](repeating: 0, count: 128)
        var modelSize = model.count
        guard sysctlbyname("hw.model", &model, &modelSize, nil, 0) == 0 else {
            throw XCTSkip("Could not identify the device for the AppleSMC integration test")
        }
        let modelName = String(
            decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard modelName.hasPrefix("Mac16,1") else {
            throw XCTSkip("Device-specific AppleSMC integration test targets Mac16,1")
        }

        let telemetry = HardwareTelemetryReader.read(at: Date())
        let cpuReadings = telemetry.sensors.filter { $0.group == "CPU" }
        let gpuReadings = telemetry.sensors.filter { $0.group == "GPU" }

        XCTAssertEqual(cpuReadings.count, 12, telemetry.diagnostics)
        XCTAssertEqual(gpuReadings.count, 6, telemetry.diagnostics)
        XCTAssertTrue(telemetry.sensors.allSatisfy { (-10...125).contains($0.valueCelsius) })
        XCTAssertEqual(telemetry.fans.count, 1, telemetry.diagnostics)

        let fan = try XCTUnwrap(telemetry.fans.first, telemetry.diagnostics)
        let currentRPM = try XCTUnwrap(fan.currentRPM, telemetry.diagnostics)
        let minimumRPM = try XCTUnwrap(fan.minimumRPM, telemetry.diagnostics)
        let maximumRPM = try XCTUnwrap(fan.maximumRPM, telemetry.diagnostics)
        let targetDescription = fan.targetRPM.map {
            "\($0.formatted(.number.precision(.fractionLength(0)))) RPM"
        } ?? "unavailable"
        let liveReading = """
        Device: \(modelName)
        CPU sensors: \(cpuReadings.count)
        GPU sensors: \(gpuReadings.count)
        Fan 0: actual \(currentRPM) RPM; target \(targetDescription); range \(minimumRPM)–\(maximumRPM) RPM; mode \(fan.controllerModeDescription)
        \(telemetry.diagnostics)
        """
        let attachment = XCTAttachment(string: liveReading)
        attachment.name = "Live AppleSMC telemetry"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Record read-only AppleSMC state") { activity in
            activity.add(attachment)
        }
        XCTAssertGreaterThan(minimumRPM, 0)
        XCTAssertGreaterThan(maximumRPM, minimumRPM)
        XCTAssertTrue((0...maximumRPM).contains(currentRPM), telemetry.diagnostics)
        if currentRPM > 0 {
            XCTAssertGreaterThanOrEqual(currentRPM, minimumRPM, telemetry.diagnostics)
        }
        XCTAssertTrue(
            fan.controllerMode == 0 || fan.controllerMode == 3,
            telemetry.diagnostics
        )
        XCTAssertEqual(fan.controllerModeDescription, "System / Auto")
        if let targetRPM = fan.targetRPM {
            XCTAssertTrue(targetRPM.isFinite && targetRPM >= 0, telemetry.diagnostics)
        }
    }

    func testAdapterPowerIsSelectableAndFormatsTheReportedAdapterWattage() {
        XCTAssertTrue(MenuBarMetric.allCases.contains(.power))
        XCTAssertEqual(MenuBarMetric.power.rawValue, "power")
        XCTAssertEqual(MenuBarMetric.power.powerTitle(adapterWatts: 65), "65W")
        XCTAssertEqual(MenuBarMetric.power.powerTitle(adapterWatts: nil), "—")
        XCTAssertEqual(MenuBarMetric.power.powerTitle(adapterWatts: .nan), "—")
        XCTAssertEqual(MenuBarMetric.power.powerTitle(adapterWatts: 0), "—")
    }

    @MainActor
    func testAdapterPowerMenuSelectionPersistsThroughMonitorPreferences() {
        let preferences = MonitorPreferences.shared
        let originalMetric = preferences.menuBarMetric
        defer { preferences.menuBarMetric = originalMetric }

        preferences.menuBarMetric = .power

        XCTAssertEqual(preferences.menuBarMetric, .power)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "com.macpulse.menuBarMetric"), "power")
        XCTAssertEqual(PowerHistoryBuffer.capacity, 500)
    }

    func testCompactMenuBarTelemetryUsesFreshReadingsAndOnlyShowsAdapterPowerOnAC() {
        let now = Date()
        var snapshot = SystemSnapshot.empty
        snapshot.temperature = TemperatureData(
            valueCelsius: 58.4,
            available: true,
            message: "Live sensor average",
            updatedAt: now
        )
        snapshot.battery = BatteryData(
            levelPercent: 73,
            source: "AC Power",
            isCharging: true,
            voltage: nil,
            current: nil,
            adapterWatts: 96,
            adapterCurrentAmps: nil,
            adapterVoltageEstimate: nil,
            batteryPowerWatts: nil,
            temperatureCelsius: nil,
            cycleCount: nil,
            healthPercent: nil,
            available: true,
            updatedAt: now
        )
        let fan = FanReading(
            index: 0,
            currentRPM: 2_500,
            targetRPM: 2_500,
            minimumRPM: 2_317,
            maximumRPM: 6_550,
            controllerMode: 0,
            updatedAt: now
        )

        XCTAssertEqual(CompactTelemetryFormat.temperature(from: snapshot, now: now), "58°")
        XCTAssertEqual(CompactTelemetryFormat.fanRPM([fan], now: now), "2500 RPM")
        XCTAssertEqual(CompactTelemetryFormat.batteryLevel(from: snapshot, now: now), "73%")
        XCTAssertEqual(CompactTelemetryFormat.adapterPower(from: snapshot, now: now), "96W")
        XCTAssertEqual(
            CompactTelemetryFormat.temperature(
                from: snapshot,
                now: now.addingTimeInterval(7)
            ),
            "—°"
        )

        snapshot.battery = BatteryData(
            levelPercent: 73,
            source: "Battery Power",
            isCharging: false,
            voltage: nil,
            current: nil,
            adapterWatts: 96,
            adapterCurrentAmps: nil,
            adapterVoltageEstimate: nil,
            batteryPowerWatts: nil,
            temperatureCelsius: nil,
            cycleCount: nil,
            healthPercent: nil,
            available: true,
            updatedAt: now
        )
        XCTAssertNil(CompactTelemetryFormat.adapterPower(from: snapshot, now: now))
    }

    func testCompactPanelTemperaturesAreFreshAndGroupedFromRealSensors() {
        let now = Date()
        let sensors = [
            SensorReading(
                id: "cpu-a", name: "CPU A", group: "CPU", valueCelsius: 60,
                updatedAt: now, source: "AppleSMCKeysEndpoint"
            ),
            SensorReading(
                id: "cpu-b", name: "CPU B", group: "CPU", valueCelsius: 70,
                updatedAt: now, source: "AppleSMCKeysEndpoint"
            ),
            SensorReading(
                id: "gpu-old", name: "GPU", group: "GPU", valueCelsius: 90,
                updatedAt: now.addingTimeInterval(-10), source: "AppleSMCKeysEndpoint"
            )
        ]
        let cpu = CompactTelemetryFormat.groupTemperature("CPU", in: sensors, now: now)
        XCTAssertEqual(cpu?.average, 65)
        XCTAssertEqual(cpu?.count, 2)
        XCTAssertNil(CompactTelemetryFormat.groupTemperature("GPU", in: sensors, now: now))
    }

    func testProcessSamplingStatusDistinguishesLoadingSuccessAndFailure() {
        XCTAssertNotEqual(ProcessSamplingStatus.loading, .loaded)
        XCTAssertEqual(ProcessSamplingStatus.failed("enumeration failed"), .failed("enumeration failed"))
        XCTAssertNotEqual(ProcessSamplingStatus.failed("enumeration failed"), .loaded)
    }

    func testProcessReaderPublishesRealCurrentProcessAndMatchingDiagnostics() throws {
        let snapshot = try ProcessReader().read(at: Date())
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)

        XCTAssertGreaterThan(snapshot.diagnostics.enumeratedPIDCount, 0, snapshot.diagnostics.summary)
        XCTAssertEqual(snapshot.diagnostics.modelCount, snapshot.processes.count, snapshot.diagnostics.summary)
        XCTAssertTrue(
            snapshot.processes.contains(where: { $0.pid == currentPID }),
            "Current test process was absent. \(snapshot.diagnostics.summary)"
        )
        XCTAssertTrue(
            snapshot.processes.allSatisfy { !$0.name.isEmpty },
            "A process model had no fallback name. \(snapshot.diagnostics.summary)"
        )
        let currentProcess = try XCTUnwrap(snapshot.processes.first(where: { $0.pid == currentPID }))
        XCTAssertGreaterThan(currentProcess.threadCount ?? 0, 0)
        XCTAssertNotNil(currentProcess.executablePath)
    }

    func testBatteryPowerAndHealthCalculationsUseReportedValuesSafely() {
        XCTAssertEqual(
            BatteryPowerCalculator.signedWatts(voltage: 12, currentMilliamps: 2_000) ?? 0,
            24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            BatteryPowerCalculator.signedWatts(voltage: 12, currentMilliamps: -2_000) ?? 0,
            -24,
            accuracy: 0.001
        )
        XCTAssertNil(BatteryPowerCalculator.signedWatts(voltage: .infinity, currentMilliamps: 1))
        XCTAssertEqual(BatteryPowerCalculator.signedWatts(voltage: 12, currentMilliamps: 0), 0)
        XCTAssertEqual(BatteryPowerCalculator.healthPercent(maximumCapacity: 4_900, designCapacity: 5_000) ?? 0, 98, accuracy: 0.001)
        XCTAssertNil(BatteryPowerCalculator.healthPercent(maximumCapacity: 0, designCapacity: 5_000))
    }

    func testPowerHistoryKeepsOnlyItsConfiguredCapacity() {
        let samples = (0..<(PowerHistoryBuffer.capacity + 4)).map {
            PowerHistorySample(
                date: Date(timeIntervalSince1970: Double($0)),
                adapterReportedWatts: Double($0),
                batteryPowerWatts: -Double($0)
            )
        }
        let history = samples.reduce(into: [PowerHistorySample]()) {
            $0 = PowerHistoryBuffer.appending($1, to: $0)
        }

        XCTAssertEqual(history.count, PowerHistoryBuffer.capacity)
        XCTAssertEqual(history.first?.adapterReportedWatts, 4)
        XCTAssertEqual(history.last?.adapterReportedWatts, Double(PowerHistoryBuffer.capacity + 3))
        XCTAssertEqual(history.last?.batteryPowerWatts, -Double(PowerHistoryBuffer.capacity + 3))
    }

    func testBatteryReaderReturnsOnlyFinitePlausibleMeasurements() {
        let reading = BatteryReader.read()

        XCTAssertTrue(reading.levelPercent.map { (0...100).contains($0) } ?? true)
        XCTAssertTrue(reading.adapterWatts.map { $0.isFinite && $0 > 0 } ?? true)
        XCTAssertTrue(reading.voltage.map { $0.isFinite && $0 > 0 } ?? true)
        XCTAssertTrue(reading.current.map { $0.isFinite } ?? true)
        XCTAssertTrue(reading.temperatureCelsius.map { (-40...100).contains($0) } ?? true)
        XCTAssertTrue(reading.healthPercent.map { (0...100).contains($0) } ?? true)
    }

    @MainActor
    func testSystemMonitorPublishesCollectedProcessesAndEndsLoading() async {
        let monitor = SystemMonitor()
        let completed = expectation(description: "Process sampling completes")
        var subscription: AnyCancellable?
        subscription = monitor.$processSamplingStatus
            .first(where: { $0 != .loading })
            .sink { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 10)

        XCTAssertEqual(monitor.processSamplingStatus, .loaded)
        XCTAssertFalse(monitor.processes.isEmpty, monitor.processSamplingDiagnostics?.summary ?? "No process diagnostics")
        XCTAssertEqual(monitor.processSamplingDiagnostics?.modelCount, monitor.processes.count)
        subscription?.cancel()
    }

    @MainActor
    func testSystemMonitorPublishesLiveSMCTelemetryToSensorsAndFans() async throws {
        var model = [CChar](repeating: 0, count: 128)
        var modelSize = model.count
        guard sysctlbyname("hw.model", &model, &modelSize, nil, 0) == 0 else {
            throw XCTSkip("Could not identify the device for the AppleSMC publication test")
        }
        let modelName = String(
            decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard modelName.hasPrefix("Mac16,1") else {
            throw XCTSkip("Device-specific AppleSMC publication test targets Mac16,1")
        }

        let monitor = SystemMonitor()
        let sampled = expectation(description: "Hardware telemetry reaches published model")
        let subscription = monitor.$hardwareTelemetryDiagnostics
            .first(where: { $0 != "Waiting for first hardware sensor sample" })
            .sink { _ in sampled.fulfill() }
        await fulfillment(of: [sampled], timeout: 10)

        XCTAssertTrue(monitor.sensors.contains(where: { $0.group == "CPU" }), monitor.hardwareTelemetryDiagnostics)
        XCTAssertTrue(monitor.sensors.contains(where: { $0.group == "GPU" }), monitor.hardwareTelemetryDiagnostics)
        XCTAssertEqual(monitor.fans.count, 1, monitor.hardwareTelemetryDiagnostics)
        XCTAssertNotNil(monitor.fans.first?.currentRPM, monitor.hardwareTelemetryDiagnostics)
        withExtendedLifetime(subscription) {}
    }

    func testNumericValueAnimationInterpolatesAndRoundsIntermediateValues() {
        XCTAssertEqual(NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 0), 40)
        XCTAssertEqual(NumericValueAnimation.displayedInteger(
            NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 0.2)
        ), 42)
        XCTAssertEqual(NumericValueAnimation.displayedInteger(
            NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 0.5)
        ), 50)
        XCTAssertEqual(NumericValueAnimation.displayedInteger(
            NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 0.8)
        ), 58)
        XCTAssertEqual(NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 1), 60)
    }

    func testNumericValueAnimationClampsProgressAndCanRetargetFromCurrentValue() {
        XCTAssertEqual(NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: -1), 40)
        XCTAssertEqual(NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 2), 60)

        let inFlightValue = NumericValueAnimation.interpolatedValue(from: 40, to: 60, progress: 0.5)
        XCTAssertEqual(NumericValueAnimation.displayedInteger(
            NumericValueAnimation.interpolatedValue(from: inFlightValue, to: 20, progress: 0)
        ), 50)
        XCTAssertEqual(NumericValueAnimation.interpolatedValue(from: inFlightValue, to: 20, progress: 1), 20)
    }

    func testCPUReadingCacheKeepsLastValueDuringTemporaryFailure() {
        var cache = CPUReadingCache()
        let firstSample = Date(timeIntervalSince1970: 1_000)
        _ = cache.updating(value: 37, status: "Live", at: firstSample)

        let retained = cache.updating(
            value: nil,
            status: "CPU unavailable",
            at: firstSample.addingTimeInterval(1)
        )

        XCTAssertEqual(retained.loadPercent, 37)
        XCTAssertTrue(retained.available)
        XCTAssertEqual(retained.status, "Using last valid CPU reading")
        XCTAssertEqual(retained.updatedAt, firstSample)
    }

    func testCPUReadingCacheRetainsValueForZeroCounterDelta() {
        var cache = CPUReadingCache()
        let firstSample = Date(timeIntervalSince1970: 1_000)
        _ = cache.updating(value: 22, status: "Live", at: firstSample)

        let unchanged = cache.updating(
            value: nil,
            status: "Waiting for next CPU sample",
            at: firstSample.addingTimeInterval(0.25)
        )

        XCTAssertEqual(unchanged.loadPercent, 22)
        XCTAssertEqual(unchanged.updatedAt, firstSample)
    }

    func testCPUReadingCacheRecoversWithNextValidSample() {
        var cache = CPUReadingCache()
        let firstSample = Date(timeIntervalSince1970: 1_000)
        _ = cache.updating(value: 22, status: "Live", at: firstSample)
        _ = cache.updating(value: nil, status: "CPU unavailable", at: firstSample.addingTimeInterval(1))

        let recoveredAt = firstSample.addingTimeInterval(2)
        let recovered = cache.updating(value: 46, status: "Live", at: recoveredAt)

        XCTAssertEqual(recovered.loadPercent, 46)
        XCTAssertEqual(recovered.status, "Live")
        XCTAssertEqual(recovered.updatedAt, recoveredAt)
    }

    func testCPUReadingCacheExpiresOldValueAfterProlongedUnavailability() {
        var cache = CPUReadingCache()
        let firstSample = Date(timeIntervalSince1970: 1_000)
        _ = cache.updating(value: 22, status: "Live", at: firstSample)

        let expired = cache.updating(
            value: nil,
            status: "CPU unavailable",
            at: firstSample.addingTimeInterval(CPUReadingCache.maximumAge + 0.1)
        )

        XCTAssertNil(expired.loadPercent)
        XCTAssertFalse(expired.available)
        XCTAssertEqual(expired.status, "CPU unavailable")
    }

    func testCpuUsageIsCalculatedFromCounterDeltas() {
        let previous = CPUTickCounters(user: 100, system: 100, nice: 50, idle: 750)
        let current = CPUTickCounters(user: 140, system: 130, nice: 55, idle: 925)

        let calculation = CPUCalculator.calculate(previous: previous, current: current)
        XCTAssertEqual(calculation?.userDelta, 40)
        XCTAssertEqual(calculation?.systemDelta, 30)
        XCTAssertEqual(calculation?.niceDelta, 5)
        XCTAssertEqual(calculation?.idleDelta, 175)
        XCTAssertEqual(calculation?.totalDelta, 250)
        XCTAssertEqual(calculation?.percentage ?? -1, 30, accuracy: 0.001)
    }

    func testMachCpuTickOrderMapsIdleBeforeNice() {
        let counters = CPUTickCounters(machTicks: [101, 202, 303, 404])

        XCTAssertEqual(counters?.user, 101)
        XCTAssertEqual(counters?.system, 202)
        XCTAssertEqual(counters?.idle, 303)
        XCTAssertEqual(counters?.nice, 404)
    }

    func testMachIdleDeltaDoesNotCountAsActiveLoad() throws {
        let previous = try XCTUnwrap(CPUTickCounters(machTicks: [100, 100, 1_000, 0]))
        let current = try XCTUnwrap(CPUTickCounters(machTicks: [110, 105, 10_990, 0]))

        XCTAssertEqual(CPUCalculator.usagePercent(previous: previous, current: current) ?? -1, 0.15, accuracy: 0.001)
    }

    func testCoreUsageCalculatesEachLogicalProcessorIndependently() {
        let previous = [
            CPUTickCounters(user: 0, system: 0, nice: 0, idle: 100),
            CPUTickCounters(user: 0, system: 0, nice: 0, idle: 100)
        ]
        let current = [
            CPUTickCounters(user: 50, system: 0, nice: 0, idle: 150),
            CPUTickCounters(user: 0, system: 0, nice: 0, idle: 200)
        ]

        let usage = zip(previous, current).map {
            CPUCalculator.usagePercent(previous: $0.0, current: $0.1)
        }

        XCTAssertEqual(usage[0] ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(usage[1], 0)
    }

    func testMachCpuTickOrderRejectsUnexpectedCount() {
        XCTAssertNil(CPUTickCounters(machTicks: [1, 2, 3]))
        XCTAssertNil(CPUTickCounters(machTicks: [1, 2, 3, 4, 5]))
    }

    func testCpuHighLoadUsesTotalDeltaMinusIdleDelta() {
        let previous = CPUTickCounters(user: 10, system: 20, nice: 5, idle: 100)
        let current = CPUTickCounters(user: 70, system: 45, nice: 10, idle: 110)

        XCTAssertEqual(CPUCalculator.usagePercent(previous: previous, current: current)!, 90, accuracy: 0.001)
    }

    func testFirstCpuSampleHasNoUsageValue() {
        let current = CPUTickCounters(user: 100, system: 200, nice: 50, idle: 650)
        XCTAssertNil(CPUCalculator.usagePercent(previous: nil, current: current))
    }

    func testCpuZeroDeltaHasNoUsageValue() {
        let counters = CPUTickCounters(user: 100, system: 200, nice: 50, idle: 650)
        XCTAssertNil(CPUCalculator.usagePercent(previous: counters, current: counters))
    }

    func testCpuCounterResetHasNoUsageValue() {
        let previous = CPUTickCounters(user: 100, system: 200, nice: 50, idle: 650)
        let reset = CPUTickCounters(user: 10, system: 20, nice: 5, idle: 65)
        XCTAssertNil(CPUCalculator.usagePercent(previous: previous, current: reset))
    }

    func testCpuRejectsCountersOutsideMachTickWidth() {
        let invalid = CPUTickCounters(user: UInt64(UInt32.max) + 1, system: 0, nice: 0, idle: 0)
        XCTAssertNil(CPUCalculator.usagePercent(previous: invalid, current: invalid))
    }

    func testCpuCounterRolloverUsesWrappingDelta() {
        let previous = CPUTickCounters(user: UInt64(UInt32.max) - 5, system: 0, nice: 0, idle: 100)
        let current = CPUTickCounters(user: 4, system: 0, nice: 0, idle: 105)
        XCTAssertEqual(CPUCalculator.usagePercent(previous: previous, current: current)!, 10.0 / 15.0 * 100, accuracy: 0.001)
    }

    func testCpuUsageIsBoundedAtOneHundredPercent() {
        let previous = CPUTickCounters(user: 0, system: 0, nice: 0, idle: 100)
        let current = CPUTickCounters(user: 100, system: 100, nice: 100, idle: 100)
        XCTAssertEqual(CPUCalculator.usagePercent(previous: previous, current: current), 100)
    }

    func testProcessCpuUsageUsesProcessCpuTimeDelta() {
        let percent = ProcessCPUCalculator.usagePercent(
            previousCPUTimeNanoseconds: 2_000_000_000,
            currentCPUTimeNanoseconds: 2_500_000_000,
            elapsedNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(percent ?? -1, 50, accuracy: 0.001)
    }

    func testProcessCpuUsageCanExceedOneCoreForMultithreadedProcess() {
        let percent = ProcessCPUCalculator.usagePercent(
            previousCPUTimeNanoseconds: 0,
            currentCPUTimeNanoseconds: 2_000_000_000,
            elapsedNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(percent, 200)
    }

    func testProcessCpuUsageRejectsFirstSampleZeroElapsedAndCounterReset() {
        XCTAssertNil(ProcessCPUCalculator.usagePercent(
            previousCPUTimeNanoseconds: nil,
            currentCPUTimeNanoseconds: 1_000,
            elapsedNanoseconds: 1_000
        ))
        XCTAssertNil(ProcessCPUCalculator.usagePercent(
            previousCPUTimeNanoseconds: 10,
            currentCPUTimeNanoseconds: 20,
            elapsedNanoseconds: 0
        ))
        XCTAssertNil(ProcessCPUCalculator.usagePercent(
            previousCPUTimeNanoseconds: 20,
            currentCPUTimeNanoseconds: 10,
            elapsedNanoseconds: 1_000
        ))
    }

    func testProcessSortDirectionTogglesAndChangingColumnUsesItsDefaultDirection() {
        var sort = ProcessSortState()
        XCTAssertEqual(sort.column, .cpu)
        XCTAssertEqual(sort.direction, .descending)

        sort.select(.cpu)
        XCTAssertEqual(sort.direction, .ascending)

        sort.select(.memory)
        XCTAssertEqual(sort.column, .memory)
        XCTAssertEqual(sort.direction, .descending)

        sort.select(.name)
        XCTAssertEqual(sort.column, .name)
        XCTAssertEqual(sort.direction, .ascending)
    }

    func testProcessSortOrderIsPreservedAcrossUpdatedSamples() {
        var sort = ProcessSortState()
        sort.select(.memory)
        let firstSample = [
            process(pid: 1, name: "Alpha", cpu: 1, memory: 100),
            process(pid: 2, name: "Beta", cpu: 2, memory: 300)
        ]
        let updatedSample = [
            process(pid: 1, name: "Alpha", cpu: 3, memory: 250),
            process(pid: 2, name: "Beta", cpu: 1, memory: 350)
        ]

        let firstResult = ProcessListCalculator.filteredAndSorted(
            firstSample, searchText: "", filter: .all, applicationPIDs: [], sort: sort
        )
        let updatedResult = ProcessListCalculator.filteredAndSorted(
            updatedSample, searchText: "", filter: .all, applicationPIDs: [], sort: sort
        )

        XCTAssertEqual(firstResult.map(\.pid), [2, 1])
        XCTAssertEqual(updatedResult.map(\.pid), [2, 1])
        XCTAssertEqual(sort.column, .memory)
        XCTAssertEqual(sort.direction, .descending)
    }

    func testProcessSortsByNameInBothDirections() {
        let processes = [
            process(pid: 1, name: "Zulu", cpu: 1, memory: 100),
            process(pid: 2, name: "alpha", cpu: 2, memory: 200)
        ]
        let ascending = ProcessSortState(column: .name, direction: .ascending)
        let descending = ProcessSortState(column: .name, direction: .descending)

        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes, searchText: "", filter: .all, applicationPIDs: [], sort: ascending
        ).map(\.name), ["alpha", "Zulu"])
        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes, searchText: "", filter: .all, applicationPIDs: [], sort: descending
        ).map(\.name), ["Zulu", "alpha"])
    }

    func testProcessSortsCpuAndMemoryInBothDirections() {
        let processes = [
            process(pid: 1, name: "Low", cpu: 5, memory: 100),
            process(pid: 2, name: "High", cpu: 85, memory: 900),
            process(pid: 3, name: "Medium", cpu: 40, memory: 500)
        ]
        let descendingCPU = ProcessSortState(column: .cpu, direction: .descending)
        let ascendingCPU = ProcessSortState(column: .cpu, direction: .ascending)
        let ascendingMemory = ProcessSortState(column: .memory, direction: .ascending)
        let descendingMemory = ProcessSortState(column: .memory, direction: .descending)

        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes, searchText: "", filter: .all, applicationPIDs: [], sort: descendingCPU
        ).map(\.pid), [2, 3, 1])
        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes, searchText: "", filter: .all, applicationPIDs: [], sort: ascendingCPU
        ).map(\.pid), [1, 3, 2])
        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes, searchText: "", filter: .all, applicationPIDs: [], sort: ascendingMemory
        ).map(\.pid), [1, 3, 2])
        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes, searchText: "", filter: .all, applicationPIDs: [], sort: descendingMemory
        ).map(\.pid), [2, 3, 1])
    }

    func testProcessSortsPidInBothDirections() {
        let processes = [
            process(pid: 30, name: "Later", cpu: 1, memory: 100),
            process(pid: 10, name: "Earlier", cpu: 2, memory: 200),
            process(pid: 20, name: "Middle", cpu: 3, memory: 300)
        ]

        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes,
            searchText: "",
            filter: .all,
            applicationPIDs: [],
            sort: ProcessSortState(column: .pid, direction: .ascending)
        ).map(\.pid), [10, 20, 30])
        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            processes,
            searchText: "",
            filter: .all,
            applicationPIDs: [],
            sort: ProcessSortState(column: .pid, direction: .descending)
        ).map(\.pid), [30, 20, 10])
    }

    func testProcessSearchAndMyApplicationsFilter() {
        let processes = [
            process(pid: 10, name: "Safari", cpu: 2, memory: 300),
            process(pid: 20, name: "Safari Networking", cpu: 4, memory: 200),
            process(pid: 30, name: "WindowServer", cpu: 8, memory: 400)
        ]
        let sort = ProcessSortState(column: .name, direction: .ascending)

        let allMatchingSearch = ProcessListCalculator.filteredAndSorted(
            processes, searchText: "safari", filter: .all, applicationPIDs: [], sort: sort
        )
        let matchingApplications = ProcessListCalculator.filteredAndSorted(
            processes,
            searchText: "",
            filter: .myApplications,
            applicationPIDs: [10, 20],
            sort: sort
        )

        XCTAssertEqual(allMatchingSearch.map(\.pid), [10, 20])
        XCTAssertEqual(matchingApplications.map(\.pid), [10, 20])
    }

    func testOverallLoadUsesWeightedAvailableCpuAndMemory() {
        let result = OverallLoadCalculator.calculate(cpuPercent: 40, memoryPercent: 80)
        XCTAssertEqual(result?.percentage ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(result?.cpuPercent, 40)
        XCTAssertEqual(result?.memoryPercent, 80)
        XCTAssertEqual(result?.isPartial, false)
    }

    func testOverallLoadRenormalizesAvailableComponentsAndMarksPartialData() {
        let cpuOnly = OverallLoadCalculator.calculate(cpuPercent: 40, memoryPercent: nil)
        let memoryOnly = OverallLoadCalculator.calculate(cpuPercent: nil, memoryPercent: 72)

        XCTAssertEqual(cpuOnly?.percentage, 40)
        XCTAssertEqual(cpuOnly?.isPartial, true)
        XCTAssertEqual(memoryOnly?.percentage, 72)
        XCTAssertEqual(memoryOnly?.isPartial, true)
        XCTAssertNil(OverallLoadCalculator.calculate(cpuPercent: nil, memoryPercent: nil))
    }

    func testOverallLoadRejectsNonFiniteAndOutOfRangeInputs() {
        XCTAssertNil(OverallLoadCalculator.calculate(cpuPercent: .infinity, memoryPercent: .nan))
        XCTAssertNil(OverallLoadCalculator.calculate(cpuPercent: 120, memoryPercent: -1))
    }

    func testOverallLoadMatchesDocumentedExamples() {
        XCTAssertEqual(OverallLoadCalculator.calculate(cpuPercent: 20, memoryPercent: 40)?.percentage, 30)
        XCTAssertEqual(OverallLoadCalculator.calculate(cpuPercent: 80, memoryPercent: 60)?.percentage, 70)
        XCTAssertEqual(OverallLoadCalculator.calculate(cpuPercent: 100, memoryPercent: 100)?.percentage, 100)
        XCTAssertEqual(OverallLoadCalculator.calculate(cpuPercent: 0, memoryPercent: 0)?.percentage, 0)
    }

    func testProcessIdentityChangesWhenPidIsReused() {
        let original = ProcessUsage(pid: 17, name: "Original", cpuPercent: 1, memoryBytes: 10, startTime: 100)
        let replacement = ProcessUsage(pid: 17, name: "Replacement", cpuPercent: 1, memoryBytes: 10, startTime: 200)

        XCTAssertNotEqual(original.id, replacement.id)
    }

    func testVanishedProcessesAreNotRetainedInUpdatedList() {
        let original = [
            process(pid: 1, name: "Present", cpu: 3, memory: 100),
            process(pid: 2, name: "Exited", cpu: 5, memory: 200)
        ]
        let nextSample = [process(pid: 1, name: "Present", cpu: 2, memory: 100)]

        XCTAssertEqual(ProcessListCalculator.filteredAndSorted(
            nextSample,
            searchText: "",
            filter: .all,
            applicationPIDs: [],
            sort: ProcessSortState()
        ).map(\.pid), [1])
        XCTAssertEqual(original.count, 2)
    }

    func testHistoryBufferKeepsOnlyTheMostRecentMinuteAt250msCadence() {
        var history: [MetricHistorySample] = []
        for index in 0...MetricHistoryBuffer.capacity {
            history = MetricHistoryBuffer.appending(
                MetricHistorySample(
                    date: Date(timeIntervalSince1970: Double(index) / 4),
                    cpuUsage: Double(index % 100),
                    memoryUsage: nil,
                    downloadBytesPerSecond: nil,
                    uploadBytesPerSecond: nil
                ),
                to: history
            )
        }

        XCTAssertEqual(history.count, MetricHistoryBuffer.capacity)
        XCTAssertEqual(history.first?.date.timeIntervalSince1970, 0.25)
        XCTAssertEqual(history.last?.date.timeIntervalSince1970, 60)
    }

    func testNetworkRatesUseElapsedTimeAndKeepDirectionsSeparate() {
        let previous = networkSample(interface: "en0", incoming: 1_000, outgoing: 2_000, time: 100)
        let current = networkSample(interface: "en0", incoming: 3_048, outgoing: 3_024, time: 102)

        let rates = NetworkRateCalculator.rates(previous: previous, current: current)
        XCTAssertEqual(rates?.incomingBytesPerSecond ?? -1, 1_024, accuracy: 0.001)
        XCTAssertEqual(rates?.outgoingBytesPerSecond ?? -1, 512, accuracy: 0.001)
    }

    func testFirstNetworkSampleHasNoRate() {
        let current = networkSample(interface: "en0", incoming: 5_000, outgoing: 8_000, time: 100)
        XCTAssertNil(NetworkRateCalculator.rates(previous: nil, current: current))
    }

    func testNetworkZeroIntervalHasNoRate() {
        let previous = networkSample(interface: "en0", incoming: 100, outgoing: 200, time: 100)
        let current = networkSample(interface: "en0", incoming: 200, outgoing: 300, time: 100)
        XCTAssertNil(NetworkRateCalculator.rates(previous: previous, current: current))
    }

    func testNetworkNegativeIntervalHasNoRate() {
        let previous = networkSample(interface: "en0", incoming: 100, outgoing: 200, time: 101)
        let current = networkSample(interface: "en0", incoming: 200, outgoing: 300, time: 100)
        XCTAssertNil(NetworkRateCalculator.rates(previous: previous, current: current))
    }

    func testNetworkCounterResetHasNoRate() {
        let previous = networkSample(interface: "en0", incoming: 2_000, outgoing: 3_000, time: 100)
        let current = networkSample(interface: "en0", incoming: 100, outgoing: 200, time: 101)
        XCTAssertNil(NetworkRateCalculator.rates(previous: previous, current: current))
    }

    func testNetworkInterfaceChangeHasNoRate() {
        let previous = networkSample(interface: "en0", incoming: 1_000, outgoing: 2_000, time: 100)
        let current = networkSample(interface: "en1", incoming: 2_000, outgoing: 3_000, time: 101)
        XCTAssertNil(NetworkRateCalculator.rates(previous: previous, current: current))
    }

    func testMemoryUsageExcludesReclaimablePagesWithoutDoubleCountingPurgeable() {
        let usage = memoryUsage(
            activePages: 40,
            inactivePages: 20,
            wiredPages: 10,
            freePages: 20,
            compressedPages: 5,
            purgeablePages: 5,
            speculativePages: 5
        )

        XCTAssertEqual(usage?.usedBytes, 60 * 4_096)
        XCTAssertEqual(usage?.availableBytes, 40 * 4_096)
        XCTAssertEqual(usage?.usagePercent ?? -1, 60, accuracy: 0.001)
    }

    func testMemoryRejectsImpossiblePageCounts() {
        XCTAssertNil(memoryUsage(activePages: 80, inactivePages: 0, wiredPages: 15, freePages: 0, compressedPages: 10, purgeablePages: 0, speculativePages: 0))
        XCTAssertNil(memoryUsage(activePages: 10, inactivePages: 10, wiredPages: 10, freePages: 5, compressedPages: 5, purgeablePages: 0, speculativePages: 6))
    }

    func testMemoryRejectsInvalidUsageInput() {
        XCTAssertNil(MemoryCalculator.usagePercent(totalBytes: 0, usedBytes: 0))
        XCTAssertNil(MemoryCalculator.usagePercent(totalBytes: 100, usedBytes: 101))
    }

    func testByteFormattingRejectsImpossibleRates() {
        XCTAssertEqual(ByteFormatter.formatSpeed(.nan), "—")
        XCTAssertEqual(ByteFormatter.formatSpeed(-1), "—")
        XCTAssertEqual(ByteFormatter.formatSpeed(1_536), "1.5 KB/s")
        XCTAssertEqual(ByteFormatter.formatDuration(3_661), "1h 1m 1s")
        XCTAssertEqual(ByteFormatter.formatDuration(.infinity), "—")
    }

    func testDiskFormatter() {
        XCTAssertTrue(DiskFormatter.formatBytes(1_024).contains("1.0"))
    }

    private func process(pid: Int32, name: String, cpu: Double, memory: UInt64) -> ProcessUsage {
        ProcessUsage(pid: pid, name: name, cpuPercent: cpu, memoryBytes: memory, startTime: 1)
    }

    private func networkSample(interface: String, incoming: UInt64, outgoing: UInt64, time: TimeInterval) -> NetworkCounterSnapshot {
        NetworkCounterSnapshot(
            interface: interface,
            incomingBytes: incoming,
            outgoingBytes: outgoing,
            sampledAt: Date(timeIntervalSince1970: time)
        )
    }

    private func memoryUsage(
        activePages: UInt64,
        inactivePages: UInt64,
        wiredPages: UInt64,
        freePages: UInt64,
        compressedPages: UInt64,
        purgeablePages: UInt64,
        speculativePages: UInt64
    ) -> MemoryUsage? {
        MemoryCalculator.calculate(
            totalBytes: 100 * 4_096,
            pageSize: 4_096,
            activePages: activePages,
            inactivePages: inactivePages,
            wiredPages: wiredPages,
            freePages: freePages,
            compressedPages: compressedPages,
            purgeablePages: purgeablePages,
            speculativePages: speculativePages
        )
    }
}
