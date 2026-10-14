import SwiftUI

enum CompactTelemetryFormat {
    static func temperature(
        from snapshot: SystemSnapshot,
        now: Date,
        maximumAge: TimeInterval = 6
    ) -> String {
        guard snapshot.temperature.available,
              now.timeIntervalSince(snapshot.temperature.updatedAt) >= 0,
              now.timeIntervalSince(snapshot.temperature.updatedAt) <= maximumAge,
              let value = snapshot.temperature.valueCelsius,
              value.isFinite else {
            return "—°"
        }
        return "\(Int(value.rounded()))°"
    }

    static func fanRPM(_ fans: [FanReading], now: Date, maximumAge: TimeInterval = 6) -> String {
        guard let fan = fans.first,
              now.timeIntervalSince(fan.updatedAt) >= 0,
              now.timeIntervalSince(fan.updatedAt) <= maximumAge,
              let rpm = fan.currentRPM,
              rpm.isFinite, rpm >= 0 else {
            return "— RPM"
        }
        return "\(Int(rpm.rounded())) RPM"
    }

    static func batteryLevel(
        from snapshot: SystemSnapshot,
        now: Date,
        maximumAge: TimeInterval = 6
    ) -> String {
        guard snapshot.battery.available,
              now.timeIntervalSince(snapshot.battery.updatedAt) >= 0,
              now.timeIntervalSince(snapshot.battery.updatedAt) <= maximumAge,
              let level = snapshot.battery.levelPercent,
              level.isFinite, (0...100).contains(level) else {
            return "—%"
        }
        return "\(Int(level.rounded()))%"
    }

    static func adapterPower(
        from snapshot: SystemSnapshot,
        now: Date,
        maximumAge: TimeInterval = 6
    ) -> String? {
        guard snapshot.battery.source == "AC Power",
              now.timeIntervalSince(snapshot.battery.updatedAt) >= 0,
              now.timeIntervalSince(snapshot.battery.updatedAt) <= maximumAge,
              let watts = snapshot.battery.adapterWatts,
              watts.isFinite, watts > 0 else {
            return nil
        }
        return "\(Int(watts.rounded()))W"
    }

    static func groupTemperature(
        _ group: String,
        in sensors: [SensorReading],
        now: Date,
        maximumAge: TimeInterval = 6
    ) -> (average: Double, count: Int)? {
        let values = sensors.compactMap { reading -> Double? in
            let age = now.timeIntervalSince(reading.updatedAt)
            guard reading.group == group, age >= 0, age <= maximumAge,
                  reading.valueCelsius.isFinite, (-10...125).contains(reading.valueCelsius) else {
                return nil
            }
            return reading.valueCelsius
        }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), values.count)
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        let now = Date()
        HStack(spacing: 7) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.teal)
            Text(CompactTelemetryFormat.temperature(from: monitor.snapshot, now: now))
            Text("|").foregroundStyle(.tertiary)
            Image(systemName: "fan")
                .foregroundStyle(.secondary)
            Text(CompactTelemetryFormat.fanRPM(monitor.fans, now: now))
            Text("|").foregroundStyle(.tertiary)
            Image(systemName: "battery.75percent")
                .foregroundStyle(.green)
            Text(CompactTelemetryFormat.batteryLevel(from: monitor.snapshot, now: now))
            Text("|").foregroundStyle(.tertiary)
            Image(systemName: "bolt.fill")
                .foregroundStyle(.yellow)
            Text(batteryChargePower(from: monitor.snapshot, now: now))
        }
        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MacPulse: CPU temperature, actual fan speed, battery charge, and battery charging power; watts are not adapter power")
    }

    private func batteryChargePower(from snapshot: SystemSnapshot, now: Date) -> String {
        let age = now.timeIntervalSince(snapshot.battery.updatedAt)
        guard snapshot.battery.source == "AC Power",
              snapshot.battery.isCharging == true,
              age >= 0, age <= 6,
              let watts = snapshot.battery.batteryPowerWatts,
              watts.isFinite, watts != 0 else {
            return "—W"
        }
        return "\(Int(abs(watts).rounded()))W"
    }
}

struct CompactMenuBarPanel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var fanControl = FanControlService.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("com.macpulse.autoBoost.triggerCelsius") private var triggerCelsius = 80.0
    @AppStorage("com.macpulse.autoBoost.releaseCelsius") private var releaseCelsius = 70.0
    @State private var targets: [Int: Double] = [:]

    private var fanReadings: [FanControlReading] {
        fanControl.readings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            telemetry
            Divider()
            fanControls
            if let error = fanControl.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 350)
        .background(.regularMaterial)
        .task {
            await fanControl.refresh()
            syncTargets()
        }
        .onChange(of: fanControl.readings) { _, _ in syncTargets() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("MacPulseMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("MacPulse")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text("Live system status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(.green.gradient)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Monitoring active")
        }
    }

    private var telemetry: some View {
        VStack(spacing: 9) {
            ForEach(["CPU", "GPU"], id: \.self) { group in
                let value = CompactTelemetryFormat.groupTemperature(group, in: monitor.sensors, now: Date())
                HStack {
                    Label(group, systemImage: group == "CPU" ? "cpu" : "square.stack.3d.up")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(group == "CPU" ? Color.teal : Color.indigo)
                    Spacer()
                    Text(value.map { "\(Int($0.average.rounded()))°C" } ?? "—")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    if let value {
                        Text("\(value.count) sensors")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Label("Battery", systemImage: monitor.snapshot.battery.isCharging == true
                    ? "battery.100percent.bolt" : "battery.75percent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                Spacer()
                Text(CompactTelemetryFormat.batteryLevel(from: monitor.snapshot, now: Date()))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let power = CompactTelemetryFormat.adapterPower(from: monitor.snapshot, now: Date()) {
                    Text("Adapter \(power)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Adapter rating reported by macOS; not Mac power consumption")
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.68), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    @ViewBuilder
    private var fanControls: some View {
        if fanReadings.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("Fan control", systemImage: "fan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                ForEach(monitor.fans) { fan in
                    HStack {
                        Text("Fan \(fan.index + 1)")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(rpm(fan.currentRPM)) actual · \(rpm(fan.targetRPM)) target")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(fan.controllerModeDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(fanControl.helperStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if fanControl.canRegisterHelper {
                    Button("Install privileged helper…") {
                        Task { await fanControl.installHelper() }
                    }
                    .controlSize(.small)
                    .disabled(fanControl.isBusy)
                } else if fanControl.helperNeedsApproval {
                    Button("Open Login Items Settings") {
                        fanControl.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                }
                Button("Refresh fan status") {
                    Task { await fanControl.refresh() }
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Fan control", systemImage: "fan")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Spacer()
                    Text(fanControl.manualControlActive ? "Manual" : "System / Auto")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                ForEach(fanReadings) { fan in
                    fanControlRow(fan)
                }

                HStack(spacing: 8) {
                    Button("System / Auto") {
                        Task { await fanControl.restoreAutomatic() }
                    }
                    .controlSize(.small)
                    .disabled(fanControl.isBusy)
                    boostButton
                }

                Text(fanControl.autoBoostStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func fanControlRow(_ fan: FanControlReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fan \(fan.index + 1)")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(rpm(fan.currentRPM)) actual · \(rpm(fan.targetRPM)) target")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let minimum = fan.minimumRPM, let maximum = fan.maximumRPM,
               minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum {
                Slider(
                    value: targetBinding(for: fan),
                    in: minimum...maximum,
                    step: 100
                )
                .controlSize(.small)
                .disabled(fanControl.isBusy || !fanControl.isHelperEnabled)
                HStack {
                    Text("\(Int(minimum.rounded()))")
                    Spacer()
                    Button("Apply Manual") {
                        Task {
                            await fanControl.setManual(fan: fan, rpm: targetBinding(for: fan).wrappedValue)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                    .disabled(fanControl.isBusy || !fanControl.isHelperEnabled)
                    Spacer()
                    Text("\(Int(maximum.rounded())) RPM")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var boostButton: some View {
        Button(fanControl.autoBoostActive ? "Stop Auto Boost" : "Auto Boost · \(Int(triggerCelsius))°") {
            Task {
                if fanControl.autoBoostActive {
                    await fanControl.disableAutoBoost()
                } else {
                    await fanControl.enableAutoBoost(
                        triggerCelsius: triggerCelsius,
                        releaseCelsius: releaseCelsius
                    )
                }
            }
        }
        .buttonStyle(.link)
        .font(.caption.weight(.medium))
        .disabled(
            fanControl.isBusy
                || (!fanControl.autoBoostActive
                    && (!fanControl.isHelperEnabled
                        || !FanAutoBoostPolicy.hasValidThresholds(
                            trigger: triggerCelsius,
                            release: releaseCelsius
                        )))
        )
        .contextMenu {
            Stepper("Boost at \(Int(triggerCelsius))°C", value: $triggerCelsius, in: 60...100)
            Stepper("Return at \(Int(releaseCelsius))°C", value: $releaseCelsius, in: 45...95)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Full App", systemImage: "macwindow")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func targetBinding(for fan: FanControlReading) -> Binding<Double> {
        Binding(
            get: { targets[fan.index] ?? initialTarget(for: fan) },
            set: { targets[fan.index] = $0 }
        )
    }

    private func initialTarget(for fan: FanControlReading) -> Double {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else { return 0 }
        if let target = fan.targetRPM, (minimum...maximum).contains(target) { return target }
        if let current = fan.currentRPM, (minimum...maximum).contains(current) { return current }
        return minimum
    }

    private func syncTargets() {
        for fan in fanReadings where targets[fan.index] == nil {
            targets[fan.index] = initialTarget(for: fan)
        }
    }

    private func rpm(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "\(Int(value.rounded())) RPM"
    }
}
