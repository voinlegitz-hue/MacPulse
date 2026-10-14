import Foundation
import ServiceManagement
import Combine

struct FanControlReading: Codable, Identifiable, Equatable {
    let index: Int
    let currentRPM: Double?
    let targetRPM: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let mode: Int?

    var id: Int { index }

    var modeDescription: String {
        switch mode {
        case 0, 3: "System / Auto"
        case 1: "Manual"
        case .none: "Unavailable"
        default: "SMC mode \(mode!)"
        }
    }
}

enum FanControlAction: String, Codable {
    case ping
    case list
    case setManual
    case setAutomatic
    case heartbeat
}

enum FanControlValidation {
    nonisolated static func hasReadableRPMTelemetry(_ readings: [FanControlReading]) -> Bool {
        !readings.isEmpty && readings.allSatisfy { fan in
            guard let current = fan.currentRPM, let target = fan.targetRPM else { return false }
            return current.isFinite && current >= 0 && target.isFinite && target >= 0
        }
    }

    nonisolated static func isTargetWithinReportedRange(
        _ rpm: Double,
        minimum: Double?,
        maximum: Double?
    ) -> Bool {
        guard let minimum, let maximum,
              minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum > minimum,
              rpm.isFinite else {
            return false
        }
        return rpm >= minimum && rpm <= maximum
    }
}

struct FanAutoBoostSettings: Equatable {
    let triggerCelsius: Double
    let releaseCelsius: Double
}

enum FanAutoBoostPolicy {
    static func hasValidThresholds(trigger: Double, release: Double) -> Bool {
        trigger.isFinite && release.isFinite
            && (60...100).contains(trigger)
            && (45...95).contains(release)
            && release <= trigger - 5
    }

    static func hottestFreshTemperature(
        in sensors: [SensorReading],
        now: Date,
        maximumAge: TimeInterval = 6
    ) -> Double? {
        sensors.lazy
            .filter { $0.group == "CPU" || $0.group == "GPU" }
            .filter { $0.valueCelsius.isFinite && (-10...125).contains($0.valueCelsius) }
            .filter {
                let age = now.timeIntervalSince($0.updatedAt)
                return age >= 0 && age <= maximumAge
            }
            .map(\.valueCelsius)
            .max()
    }

    static func boostTarget(currentRPM: Double?, minimum: Double, maximum: Double) -> Double? {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum,
              let currentRPM, currentRPM.isFinite, currentRPM >= 0 else {
            return nil
        }
        return min(maximum, max(minimum, currentRPM + 500))
    }
}

struct FanControlRequest: Codable {
    let action: FanControlAction
    let fanIndex: Int?
    let targetRPM: Double?
}

struct FanControlResponse: Codable {
    let success: Bool
    let message: String
    let fans: [FanControlReading]
    let helperVersion: Int?
}

@objc private protocol FanHelperXPCProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@MainActor
final class FanControlService: ObservableObject {
    static let shared = FanControlService()

    @Published private(set) var readings: [FanControlReading] = []
    @Published private(set) var helperStatus = "Privileged helper is not registered."
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var manualControlActive = false
    @Published private(set) var autoBoostActive = false
    @Published private(set) var autoBoostStatus = "Auto Boost is off."

    private let service = SMAppService.daemon(plistName: "com.macpulse.app.fanhelper.plist")
    private var heartbeatTimer: DispatchSourceTimer?
    private let xpcName = "com.macpulse.app.fanhelper"
    private let helperVersion = 3
    private let helperVersionPreferenceKey = "com.macpulse.fanHelperVersion"
    private var autoBoostSettings: FanAutoBoostSettings?
    private var autoBoostRaisedFans = false

    private init() {
        updateServiceStatus()
    }

    func start() async {
        if isHelperEnabled {
            await refresh()
            await updateBundledHelperIfNeeded()
        } else if UserDefaults.standard.integer(forKey: helperVersionPreferenceKey) > 0,
                  canRegisterHelper {
            await installHelper()
        }
    }

    var canRegisterHelper: Bool {
        service.status == .notRegistered || service.status == .notFound
    }

    var isHelperEnabled: Bool {
        service.status == .enabled
    }

    var helperNeedsApproval: Bool {
        service.status == .requiresApproval
    }

    func installHelper() async {
        guard Bundle.main.bundleIdentifier == "com.macpulse.app" else {
            lastError = "Helper installation requires the signed com.macpulse.app application bundle."
            return
        }
        do {
            try service.register()
            updateServiceStatus()
            let response = try await send(.ping)
            guard response.success else { throw FanControlClientError.helper(response.message) }
            guard response.helperVersion == helperVersion else {
                throw FanControlClientError.helper("The installed helper version does not match this app.")
            }
            helperStatus = response.message
            lastError = nil
            UserDefaults.standard.set(helperVersion, forKey: helperVersionPreferenceKey)
            await refresh()
        } catch {
            lastError = "Could not install or connect to the privileged helper: \(error.localizedDescription)"
            updateServiceStatus()
        }
    }

    func refreshHelperInstallation() async {
        guard isHelperEnabled else {
            await installHelper()
            return
        }
        guard !readings.isEmpty,
              readings.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) else {
            lastError = "Restore and confirm System / Auto before updating the privileged helper."
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            try await service.unregister()
            updateServiceStatus()
            try service.register()
            updateServiceStatus()
            let ping = try await send(.ping)
            guard ping.success, ping.helperVersion == helperVersion else {
                throw FanControlClientError.helper(ping.message)
            }
            let automatic = try await send(.setAutomatic)
            guard automatic.success,
                  automatic.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }),
                  FanControlValidation.hasReadableRPMTelemetry(automatic.fans) else {
                throw FanControlClientError.helper(automatic.message)
            }
            readings = automatic.fans
            manualControlActive = false
            helperStatus = "Updated helper connected; System / Auto confirmed by SMC."
            lastError = nil
            UserDefaults.standard.set(helperVersion, forKey: helperVersionPreferenceKey)
            stopHeartbeat()
        } catch {
            lastError = "Could not safely update or verify the privileged helper: \(error.localizedDescription)"
            updateServiceStatus()
        }
    }

    func refresh() async {
        do {
            let response = try await send(.list)
            guard response.success else { throw FanControlClientError.helper(response.message) }
            readings = response.fans
            if response.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) {
                manualControlActive = false
                if autoBoostSettings == nil {
                    stopHeartbeat()
                }
            } else if response.fans.contains(where: { $0.mode == 1 }) {
                manualControlActive = true
                startHeartbeat()
            }
            helperStatus = response.message
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            updateServiceStatus()
        }
    }

    func setManual(fan: FanControlReading, rpm: Double) async {
        stopHeartbeat()
        autoBoostSettings = nil
        autoBoostActive = false
        autoBoostRaisedFans = false
        autoBoostStatus = "Auto Boost is off."
        await applyManual(fan: fan, rpm: rpm)
    }

    private func applyManual(fan: FanControlReading, rpm: Double) async {
        guard FanControlValidation.isTargetWithinReportedRange(
            rpm,
            minimum: fan.minimumRPM,
            maximum: fan.maximumRPM
        ) else {
            lastError = "Requested RPM is outside the controller-reported range."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await send(.setManual, fanIndex: fan.index, targetRPM: rpm)
            guard response.success,
                  let confirmed = response.fans.first(where: { $0.index == fan.index }),
                  confirmed.mode == 1,
                  let target = confirmed.targetRPM,
                  confirmed.currentRPM?.isFinite == true,
                  abs(target - rpm) <= 2 else {
                throw FanControlClientError.helper(response.message)
            }
            readings = response.fans
            manualControlActive = true
            helperStatus = "Manual confirmed; target \(Int(target.rounded())) RPM."
            lastError = nil
            startHeartbeat()
            await refresh()
        } catch let manualError {
            await restoreAutomatic()
            if let recoveryError = lastError {
                lastError = "Manual request was not confirmed: \(manualError.localizedDescription). Auto recovery also failed: \(recoveryError)"
            } else {
                lastError = "Manual request was not confirmed: \(manualError.localizedDescription). System / Auto was restored."
            }
        }
    }

    func enableAutoBoost(triggerCelsius: Double, releaseCelsius: Double) async {
        guard FanAutoBoostPolicy.hasValidThresholds(
            trigger: triggerCelsius,
            release: releaseCelsius
        ) else {
            lastError = "Choose a trigger from 60–100°C and a release threshold at least 5°C lower."
            return
        }
        guard isHelperEnabled else {
            lastError = "Install and enable the privileged helper before using Auto Boost."
            return
        }
        await refresh()
        guard lastError == nil else { return }
        guard !readings.isEmpty,
              readings.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) else {
            lastError = "Restore System / Auto before enabling Auto Boost."
            return
        }
        guard let temperature = FanAutoBoostPolicy.hottestFreshTemperature(
            in: SystemMonitor.shared.sensors,
            now: Date()
        ) else {
            lastError = "Auto Boost requires a fresh CPU or GPU temperature reading."
            return
        }
        guard readings.allSatisfy({
            FanControlValidation.isTargetWithinReportedRange(
                $0.minimumRPM ?? .nan,
                minimum: $0.minimumRPM,
                maximum: $0.maximumRPM
            ) && $0.currentRPM?.isFinite == true
        }) else {
            lastError = "Auto Boost requires current RPM and controller-reported limits for every fan."
            return
        }

        autoBoostSettings = FanAutoBoostSettings(
            triggerCelsius: triggerCelsius,
            releaseCelsius: releaseCelsius
        )
        autoBoostActive = true
        autoBoostRaisedFans = false
        autoBoostStatus = "Watching CPU/GPU temperatures; System / Auto remains active below threshold."
        lastError = nil
        startHeartbeat()
        await evaluateAutoBoost(temperature: temperature)
    }

    func disableAutoBoost() async {
        autoBoostSettings = nil
        autoBoostActive = false
        autoBoostRaisedFans = false
        autoBoostStatus = "Auto Boost is off."
        if manualControlActive {
            await restoreAutomatic()
        } else {
            stopHeartbeat()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func restoreAutomatic() async {
        autoBoostSettings = nil
        autoBoostActive = false
        autoBoostRaisedFans = false
        autoBoostStatus = "Auto Boost is off."
        await requestAutomatic(clearAutoBoost: true)
    }

    private func requestAutomatic(clearAutoBoost: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await send(.setAutomatic)
            guard response.success,
                  response.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }),
                  FanControlValidation.hasReadableRPMTelemetry(response.fans) else {
                throw FanControlClientError.helper(response.message)
            }
            readings = response.fans
            manualControlActive = false
            helperStatus = "System / Auto confirmed by SMC."
            lastError = nil
            autoBoostRaisedFans = false
            if clearAutoBoost {
                autoBoostSettings = nil
                autoBoostActive = false
                autoBoostStatus = "Auto Boost is off."
            } else {
                autoBoostStatus = "Temperature below release threshold; System / Auto is active."
            }
            if autoBoostSettings == nil {
                stopHeartbeat()
            } else {
                startHeartbeat()
            }
        } catch {
            lastError = "Could not confirm System / Auto: \(error.localizedDescription)"
            updateServiceStatus()
            autoBoostSettings = nil
            autoBoostActive = false
            autoBoostStatus = "Stopped after an Auto restoration error; helper watchdog will restore Auto."
            stopHeartbeat()
            manualControlActive = false
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.manualControlActive || self.autoBoostSettings != nil else { return }
                do {
                    if let settings = self.autoBoostSettings {
                        guard let temperature = FanAutoBoostPolicy.hottestFreshTemperature(
                            in: SystemMonitor.shared.sensors,
                            now: Date()
                        ) else {
                            self.lastError = "CPU/GPU temperature became stale; requesting System / Auto."
                            await self.requestAutomatic(clearAutoBoost: true)
                            return
                        }
                        await self.evaluateAutoBoost(temperature: temperature, settings: settings)
                    }
                    guard self.manualControlActive else { return }
                    let response = try await self.send(.heartbeat)
                    guard response.success else {
                        throw FanControlClientError.helper(response.message)
                    }
                } catch {
                    self.lastError = "Helper connection lost; its watchdog will restore Auto: \(error.localizedDescription)"
                    self.manualControlActive = false
                    self.autoBoostSettings = nil
                    self.autoBoostActive = false
                    self.autoBoostRaisedFans = false
                    self.autoBoostStatus = "Stopped after helper connection loss."
                    self.stopHeartbeat()
                }
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func evaluateAutoBoost(
        temperature: Double,
        settings: FanAutoBoostSettings? = nil
    ) async {
        guard let settings = settings ?? autoBoostSettings, !isBusy else { return }
        if !autoBoostRaisedFans && temperature >= settings.triggerCelsius {
            isBusy = true
            defer { isBusy = false }
            do {
                for fan in readings {
                    guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM,
                          let target = FanAutoBoostPolicy.boostTarget(
                            currentRPM: fan.currentRPM,
                            minimum: minimum,
                            maximum: maximum
                          ) else {
                        throw FanControlClientError.helper("A fan has no valid current RPM or controller range.")
                    }
                    let response = try await send(.setManual, fanIndex: fan.index, targetRPM: target)
                    guard response.success,
                          let confirmed = response.fans.first(where: { $0.index == fan.index }),
                          confirmed.mode == 1,
                          let confirmedTarget = confirmed.targetRPM,
                          confirmed.currentRPM?.isFinite == true,
                          abs(confirmedTarget - target) <= 2 else {
                        throw FanControlClientError.helper(response.message)
                    }
                    readings = response.fans
                }
                manualControlActive = true
                autoBoostRaisedFans = true
                autoBoostStatus = "Boost confirmed at \(Int(temperature.rounded()))°C; targets are SMC-confirmed."
                lastError = nil
                startHeartbeat()
            } catch {
                let controlError = error.localizedDescription
                autoBoostSettings = nil
                autoBoostActive = false
                autoBoostStatus = "Stopped after a fan-control error; requesting System / Auto."
                await requestAutomatic(clearAutoBoost: true)
                if let recoveryError = lastError {
                    lastError = "Auto Boost failed: \(controlError). System / Auto recovery also failed: \(recoveryError)"
                } else {
                    lastError = "Auto Boost failed: \(controlError). System / Auto was restored."
                }
            }
        } else if autoBoostRaisedFans && temperature <= settings.releaseCelsius {
            await requestAutomatic(clearAutoBoost: false)
        } else if !autoBoostRaisedFans {
            autoBoostStatus = "Watching at \(Int(temperature.rounded()))°C; System / Auto remains active."
        }
    }

    private func updateBundledHelperIfNeeded() async {
        guard isHelperEnabled,
              UserDefaults.standard.integer(forKey: helperVersionPreferenceKey) != helperVersion else {
            return
        }
        do {
            let response = try await send(.ping)
            guard response.success else { throw FanControlClientError.helper(response.message) }
            if response.helperVersion == helperVersion {
                UserDefaults.standard.set(helperVersion, forKey: helperVersionPreferenceKey)
                return
            }
            await refresh()
            guard !readings.isEmpty,
                  readings.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) else { return }
            await refreshHelperInstallation()
        } catch {
            lastError = "Could not check for a privileged helper update: \(error.localizedDescription)"
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func send(
        _ action: FanControlAction,
        fanIndex: Int? = nil,
        targetRPM: Double? = nil
    ) async throws -> FanControlResponse {
        guard service.status == .enabled else {
            throw FanControlClientError.helper("The privileged helper is not enabled. Install it first.")
        }
        let connection = NSXPCConnection(machServiceName: xpcName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPCProtocol.self)
        connection.invalidationHandler = {}
        connection.interruptionHandler = {}
        connection.resume()
        defer { connection.invalidate() }

        let requestData = try JSONEncoder().encode(
            FanControlRequest(action: action, fanIndex: fanIndex, targetRPM: targetRPM)
        )
        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? FanHelperXPCProtocol else {
                continuation.resume(throwing: FanControlClientError.helper("The helper does not expose the expected XPC interface."))
                return
            }
            proxy.perform(requestData) { data in
                do {
                    let response = try JSONDecoder().decode(FanControlResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func updateServiceStatus() {
        switch service.status {
        case .enabled:
            helperStatus = "Privileged helper is enabled."
        case .requiresApproval:
            helperStatus = "Helper needs approval in System Settings → General → Login Items."
        case .notRegistered:
            helperStatus = "Privileged helper is not registered."
        case .notFound:
            helperStatus = "Helper plist is missing from the application bundle."
        @unknown default:
            helperStatus = "Privileged helper status is unknown."
        }
    }
}

private enum FanControlClientError: LocalizedError {
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .helper(let message): message
        }
    }
}
