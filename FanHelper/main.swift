import Foundation
import IOKit
import Security

private let helperLabel = "com.macpulse.app.fanhelper"
private let fanHelperVersion = 3
private let allowedClientRequirement =
    "anchor apple generic and certificate leaf[subject.OU] = \"Q763WW8PGT\" and identifier \"com.macpulse.app\""

@objc private protocol FanHelperProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

private enum FanHelperAction: String, Codable {
    case ping
    case list
    case setManual
    case setAutomatic
    case heartbeat
}

private struct FanHelperRequest: Codable {
    let action: FanHelperAction
    let fanIndex: Int?
    let targetRPM: Double?
}

private struct FanHelperReading: Codable {
    let index: Int
    let currentRPM: Double?
    let targetRPM: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let mode: Int?
}

private struct FanHelperResponse: Codable {
    let success: Bool
    let message: String
    let fans: [FanHelperReading]
    let helperVersion: Int

    init(success: Bool, message: String, fans: [FanHelperReading]) {
        self.success = success
        self.message = message
        self.fans = fans
        self.helperVersion = fanHelperVersion
    }
}

private enum FanHelperError: LocalizedError {
    case unavailable(String)
    case invalid(String)
    case rejected(String)
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalid(let message),
             .rejected(let message), .verification(let message):
            message
        }
    }
}

private final class FanHelperDaemon: NSObject, NSXPCListenerDelegate, FanHelperProtocol {
    private let listener = NSXPCListener(machServiceName: helperLabel)
    private let queue = DispatchQueue(label: "\(helperLabel).smc")
    private var watchdog: DispatchSourceTimer?
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var manualControlArmed = false

    func run() -> Never {
        listener.delegate = self
        listener.resume()
        queue.sync {
            manualControlArmed = true
            do {
                try restoreAutomatic()
                startWatchdog()
            } catch {
                NSLog("MacPulse fan helper startup recovery failed: %@", error.localizedDescription)
                startWatchdog()
            }
        }
        RunLoop.current.run()
        fatalError("Fan helper run loop exited")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(allowedClientRequirement)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func perform(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        guard requestData.count <= 4_096,
              let request = try? JSONDecoder().decode(FanHelperRequest.self, from: requestData) else {
            reply(encode(FanHelperResponse(success: false, message: "Invalid or oversized helper request.", fans: [])))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let response = try self.handle(request)
                reply(self.encode(response))
            } catch {
                NSLog("MacPulse fan helper request failed: %@", error.localizedDescription)
                reply(self.encode(FanHelperResponse(success: false, message: error.localizedDescription, fans: [])))
            }
        }
    }

    private func handle(_ request: FanHelperRequest) throws -> FanHelperResponse {
        switch request.action {
        case .ping:
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            return FanHelperResponse(success: true, message: "Privileged fan helper is connected.", fans: try controller().readFans())
        case .list:
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            return FanHelperResponse(success: true, message: "Fan state read from AppleSMC.", fans: try controller().readFans())
        case .heartbeat:
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            return FanHelperResponse(success: true, message: "Watchdog heartbeat received.", fans: [])
        case .setManual:
            guard let index = request.fanIndex,
                  let rpm = request.targetRPM,
                  rpm.isFinite else {
                throw FanHelperError.invalid("A fan index and finite target RPM are required.")
            }
            let control = try controller()
            let fan = try control.readFan(index: index)
            guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM,
                  minimum > 0, maximum > minimum,
                  rpm >= minimum, rpm <= maximum else {
                throw FanHelperError.invalid("Requested RPM is outside the current SMC range for fan \(index).")
            }
            manualControlArmed = true
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            _ = try control.setManual(index: index, rpm: rpm)
            let confirmedFans = try control.readFans()
            guard let confirmed = confirmedFans.first(where: { $0.index == index }),
                  confirmed.mode == 1,
                  let confirmedTarget = confirmed.targetRPM,
                  let confirmedActual = confirmed.currentRPM,
                  confirmedActual.isFinite, confirmedActual >= 0,
                  abs(confirmedTarget - rpm) <= 2 else {
                throw FanHelperError.verification("SMC did not confirm the requested Manual state and target.")
            }
            return FanHelperResponse(
                success: true,
                message: "Fan \(index + 1): Manual mode and target \(Int(confirmedTarget.rounded())) RPM confirmed; actual speed is \(confirmed.currentRPM.map { "\(Int($0.rounded())) RPM" } ?? "unavailable").",
                fans: confirmedFans
            )
        case .setAutomatic:
            try restoreAutomatic()
            return FanHelperResponse(success: true, message: "SMC verified System / Auto mode.", fans: try controller().readFans())
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.manualControlArmed,
                  ProcessInfo.processInfo.systemUptime - self.lastHeartbeat >= 8 else { return }
            do {
                try self.restoreAutomatic()
                NSLog("MacPulse fan helper watchdog restored System / Auto after client timeout.")
            } catch {
                NSLog("MacPulse fan helper watchdog could not restore Auto: %@", error.localizedDescription)
                self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func restoreAutomatic() throws {
        let control = try controller()
        let fans = try control.readFans()
        guard !fans.isEmpty else {
            throw FanHelperError.unavailable("SMC reported no fans; System / Auto restoration cannot be verified.")
        }
        for fan in fans {
            try control.setAutomatic(index: fan.index)
        }
        if control.keyExists("Ftst") {
            let deadline = Date().addingTimeInterval(3)
            var confirmed = false
            while Date() < deadline {
                if (try? control.readUInt8("Ftst")) == 0 {
                    confirmed = true
                    break
                }
                try control.writeUInt8(0, to: "Ftst")
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard confirmed else {
                throw FanHelperError.verification("SMC did not confirm Ftst=0 after Auto restoration.")
            }
        }
        let verifiedFans = try control.readFans()
        guard verifiedFans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) else {
            throw FanHelperError.verification("SMC did not confirm System / Auto mode for every fan.")
        }
        guard !verifiedFans.isEmpty,
              verifiedFans.allSatisfy({
                  guard let actual = $0.currentRPM, let target = $0.targetRPM else { return false }
                  return actual.isFinite && actual >= 0 && target.isFinite && target >= 0
              }) else {
            throw FanHelperError.verification("SMC did not provide actual and target RPM readback after Auto restoration.")
        }
        manualControlArmed = false
    }

    private func controller() throws -> SMCFanController {
        try SMCFanController()
    }

    private func encode(_ response: FanHelperResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}

private final class SMCFanController {
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

    private var connection: io_connect_t = 0

    init() throws {
        guard MemoryLayout<Parameters>.stride == 80 else {
            throw FanHelperError.unavailable("Unexpected AppleSMC structure layout; refusing fan-control operations.")
        }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMCKeysEndpoint")
        )
        guard service != 0 else {
            throw FanHelperError.unavailable("AppleSMCKeysEndpoint is unavailable.")
        }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw FanHelperError.unavailable("Could not open AppleSMCKeysEndpoint (IOReturn \(result)).")
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readFans() throws -> [FanHelperReading] {
        let count = Int(try readUInt8("FNum"))
        guard (0...16).contains(count) else {
            throw FanHelperError.verification("SMC returned an invalid fan count.")
        }
        return try (0..<count).map(readFan)
    }

    func readFan(index: Int) throws -> FanHelperReading {
        let count = Int(try readUInt8("FNum"))
        guard index >= 0, index < count else {
            throw FanHelperError.invalid("Fan index \(index) is not present.")
        }
        let prefix = "F\(index)"
        return FanHelperReading(
            index: index,
            currentRPM: try? readFloat(prefix + "Ac"),
            targetRPM: try? readFloat(prefix + "Tg"),
            minimumRPM: try? readFloat(prefix + "Mn"),
            maximumRPM: try? readFloat(prefix + "Mx"),
            mode: try? Int(readUInt8(prefix + "Md"))
        )
    }

    func setManual(index: Int, rpm: Double) throws -> FanHelperReading {
        let modeKey = try readableModeKey(index: index)
        do {
            do {
                try writeUInt8(1, to: modeKey)
            } catch {
                guard keyExists("Ftst") else { throw error }
                try writeUInt8(1, to: "Ftst")
                let deadline = Date().addingTimeInterval(10)
                var lastError: Error?
                while Date() < deadline {
                    do {
                        try writeUInt8(1, to: modeKey)
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
                if let lastError { throw lastError }
            }

            try writeFloat(rpm, to: "F\(index)Tg")
            let deadline = Date().addingTimeInterval(2)
            var confirmed: FanHelperReading?
            while Date() < deadline {
                let reading = try readFan(index: index)
                if reading.mode == 1,
                   let target = reading.targetRPM,
                   abs(target - rpm) <= 2 {
                    confirmed = reading
                    break
                }
                Thread.sleep(forTimeInterval: 0.08)
            }
            guard let confirmed else {
                throw FanHelperError.verification("SMC did not confirm Manual mode and target RPM.")
            }
            return confirmed
        } catch let manualError {
            do {
                try setAutomatic(index: index)
                if keyExists("Ftst") {
                    try writeUInt8(0, to: "Ftst")
                    guard try readUInt8("Ftst") == 0 else {
                        throw FanHelperError.verification("Ftst remained enabled after failed Manual request.")
                    }
                }
            } catch {
                throw FanHelperError.verification(
                    "Manual request failed (\(manualError.localizedDescription)); recovery to Auto also failed (\(error.localizedDescription))."
                )
            }
            throw manualError
        }
    }

    func setAutomatic(index: Int) throws {
        let modeKey = try readableModeKey(index: index)
        if let currentMode = try? readUInt8(modeKey),
           currentMode == 0 || currentMode == 3 {
            return
        }
        do {
            try writeUInt8(0, to: modeKey)
        } catch {
            if let mode = try? readUInt8(modeKey), mode == 0 || mode == 3 {
                return
            }
            throw error
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let mode = try? readUInt8(modeKey)
            if mode == 0 || mode == 3 { return }
            Thread.sleep(forTimeInterval: 0.08)
        }
        throw FanHelperError.verification("SMC did not confirm System / Auto mode for fan \(index).")
    }

    func keyExists(_ name: String) -> Bool {
        (try? keyInfo(name)) != nil
    }

    func readUInt8(_ name: String) throws -> UInt8 {
        let (info, bytes) = try read(name)
        guard info.size == 1, typeString(info.type) == "ui8 " else {
            throw FanHelperError.verification("SMC key \(name) has an unexpected type or size.")
        }
        return bytes[0]
    }

    func writeUInt8(_ value: UInt8, to name: String) throws {
        try write([value], to: name, expectedType: "ui8 ")
    }

    private func readFloat(_ name: String) throws -> Double {
        let (info, bytes) = try read(name)
        guard info.size == 4, typeString(info.type) == "flt " else {
            throw FanHelperError.verification("SMC key \(name) has an unexpected type or size.")
        }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let value = Double(Float(bitPattern: bits))
        guard value.isFinite else {
            throw FanHelperError.verification("SMC returned a non-finite value for \(name).")
        }
        return value
    }

    private func writeFloat(_ value: Double, to name: String) throws {
        let float = Float(value)
        let bits = float.bitPattern
        try write(
            [
                UInt8(truncatingIfNeeded: bits),
                UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16),
                UInt8(truncatingIfNeeded: bits >> 24)
            ],
            to: name,
            expectedType: "flt "
        )
    }

    private func read(_ name: String) throws -> (KeyInfo, [UInt8]) {
        let info = try keyInfo(name)
        var request = Parameters()
        request.key = fourCharacterCode(name)
        request.keyInfo = info
        request.command = 5
        let response = try call(request)
        guard response.result == 0 else {
            throw FanHelperError.rejected("SMC rejected read of key \(name) (result \(response.result)).")
        }
        let bytes = withUnsafeBytes(of: response.bytes) {
            Array($0.prefix(Int(info.size)))
        }
        return (info, bytes)
    }

    private func keyInfo(_ name: String) throws -> KeyInfo {
        var request = Parameters()
        request.key = fourCharacterCode(name)
        request.command = 9
        let response = try call(request)
        guard response.result == 0, response.keyInfo.size > 0, response.keyInfo.size <= 32 else {
            throw FanHelperError.unavailable("SMC key \(name) is unavailable.")
        }
        return response.keyInfo
    }

    private func write(_ bytes: [UInt8], to name: String, expectedType: String) throws {
        let info = try keyInfo(name)
        guard Int(info.size) == bytes.count, typeString(info.type) == expectedType else {
            throw FanHelperError.verification("SMC key \(name) does not have the expected format.")
        }
        var request = Parameters()
        request.key = fourCharacterCode(name)
        request.keyInfo = info
        request.command = 6
        withUnsafeMutableBytes(of: &request.bytes) { destination in
            for (index, byte) in bytes.enumerated() {
                destination[index] = byte
            }
        }
        let response = try call(request)
        guard response.result == 0 else {
            throw FanHelperError.rejected("SMC rejected write to key \(name) (result \(response.result)).")
        }
    }

    private func readableModeKey(index: Int) throws -> String {
        for key in ["F\(index)Md", "F\(index)md"] where keyExists(key) {
            if (try? readUInt8(key)) != nil { return key }
        }
        throw FanHelperError.unavailable("No readable mode key exists for fan \(index).")
    }

    private func call(_ input: Parameters) throws -> Parameters {
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
        guard result == KERN_SUCCESS else {
            throw FanHelperError.rejected("AppleSMC IOKit call failed (IOReturn \(result)).")
        }
        return output
    }

    private func fourCharacterCode(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func typeString(_ value: UInt32) -> String {
        withUnsafeBytes(of: value.bigEndian) {
            String(bytes: $0, encoding: .ascii) ?? ""
        }
    }
}

FanHelperDaemon().run()
