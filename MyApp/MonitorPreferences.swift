import Foundation
import SwiftUI
import Combine

@MainActor
final class MonitorPreferences: ObservableObject {
    static let shared = MonitorPreferences()

    private let defaults = UserDefaults.standard

    @Published var showCPU = true {
        didSet { defaults.set(showCPU, forKey: Keys.showCPU) }
    }
    @Published var showRAM = true {
        didSet { defaults.set(showRAM, forKey: Keys.showRAM) }
    }
    @Published var showDisk = true {
        didSet { defaults.set(showDisk, forKey: Keys.showDisk) }
    }
    @Published var showNetwork = true {
        didSet { defaults.set(showNetwork, forKey: Keys.showNetwork) }
    }
    @Published var showBattery = true {
        didSet { defaults.set(showBattery, forKey: Keys.showBattery) }
    }
    @Published var showTemperature = false {
        didSet { defaults.set(showTemperature, forKey: Keys.showTemperature) }
    }
    @Published var showHistory = true {
        didSet { defaults.set(showHistory, forKey: Keys.showHistory) }
    }
    @Published var menuBarMetric: MenuBarMetric = .cpu {
        didSet { defaults.set(menuBarMetric.rawValue, forKey: Keys.menuBarMetric) }
    }

    private enum Keys {
        static let showCPU = "com.macpulse.showCPU"
        static let showRAM = "com.macpulse.showRAM"
        static let showDisk = "com.macpulse.showDisk"
        static let showNetwork = "com.macpulse.showNetwork"
        static let showBattery = "com.macpulse.showBattery"
        static let showTemperature = "com.macpulse.showTemperature"
        static let showHistory = "com.macpulse.showHistory"
        static let menuBarMetric = "com.macpulse.menuBarMetric"
    }

    init() {
        showCPU = defaults.object(forKey: Keys.showCPU) as? Bool ?? true
        showRAM = defaults.object(forKey: Keys.showRAM) as? Bool ?? true
        showDisk = defaults.object(forKey: Keys.showDisk) as? Bool ?? true
        showNetwork = defaults.object(forKey: Keys.showNetwork) as? Bool ?? true
        showBattery = defaults.object(forKey: Keys.showBattery) as? Bool ?? true
        showTemperature = defaults.object(forKey: Keys.showTemperature) as? Bool ?? false
        showHistory = defaults.object(forKey: Keys.showHistory) as? Bool ?? true

        if let raw = defaults.string(forKey: Keys.menuBarMetric),
           let metric = MenuBarMetric(rawValue: raw) {
            menuBarMetric = metric
        }
    }

    func enableAll() {
        showCPU = true
        showRAM = true
        showDisk = true
        showNetwork = true
        showBattery = true
        showTemperature = false
        showHistory = true
    }

    func resetDisplaySettings() {
        showCPU = true
        showRAM = true
        showDisk = true
        showNetwork = true
        showBattery = true
        showTemperature = false
        showHistory = true
    }

    func activeCards() -> [DisplayMetric] {
        var metrics: [DisplayMetric] = []
        if showCPU { metrics.append(.cpu) }
        if showRAM { metrics.append(.ram) }
        if showDisk { metrics.append(.disk) }
        if showNetwork { metrics.append(.network) }
        if showBattery { metrics.append(.battery) }
        if showTemperature { metrics.append(.temperature) }
        if showHistory { metrics.append(.history) }
        return metrics
    }
}
