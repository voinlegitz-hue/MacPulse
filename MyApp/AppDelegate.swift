import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor.shared
    private var statusItems: [NSStatusItem] = []
    private var popover: NSPopover!
    private var monitorUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        setupMetricStatusItems()
        setupPopover()
        monitorUpdates = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMetricStatusItems()
            }
        }
        updateMetricStatusItems()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        NSApp.windows.first(where: { $0.title == "MacPulse" })?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func setupMetricStatusItems() {
        guard statusItems.isEmpty else { return }

        let items: [(String, String, String)] = [
            ("thermometer.medium", "—°", "CPU temperature"),
            ("fan", "— RPM", "Actual fan speed"),
            ("battery.75percent", "—%", "Battery charge"),
            ("bolt.fill", "—W", "Battery power; not adapter power")
        ]
        statusItems = items.map { symbol, value, tooltip in
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
                button.imagePosition = .imageLeading
                button.target = self
                button.action = #selector(showCompactPanel(_:))
                button.toolTip = tooltip
                setTitle(value, on: button)
            }
            return item
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: CompactMenuBarPanel(monitor: monitor)
        )
        popover.contentSize = NSSize(width: 350, height: 390)
    }

    private func updateMetricStatusItems() {
        guard statusItems.count == 4 else { return }
        let now = Date()
        let values = [
            CompactTelemetryFormat.temperature(from: monitor.snapshot, now: now),
            CompactTelemetryFormat.fanRPM(monitor.fans, now: now).replacingOccurrences(of: " RPM", with: ""),
            CompactTelemetryFormat.batteryLevel(from: monitor.snapshot, now: now),
            batteryPower(now: now)
        ]
        for (item, value) in zip(statusItems, values) {
            if let button = item.button {
                setTitle(value, on: button)
            }
        }
    }

    private func batteryPower(now: Date) -> String {
        let battery = monitor.snapshot.battery
        let age = now.timeIntervalSince(battery.updatedAt)
        guard battery.available, age >= 0, age <= 6,
              let watts = battery.batteryPowerWatts,
              watts.isFinite else {
            return "—W"
        }
        return "\(Int(abs(watts).rounded()))W"
    }

    private func setTitle(_ title: String, on button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    @objc private func showCompactPanel(_ sender: NSStatusBarButton) {
        guard statusItems.contains(where: { $0.button === sender }) else { return }
        if popover.isShown {
            popover.performClose(nil)
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}
